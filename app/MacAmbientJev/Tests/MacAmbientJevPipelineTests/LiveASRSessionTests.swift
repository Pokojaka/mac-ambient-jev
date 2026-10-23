import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private actor CountingASREngine: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var prepareCalls = 0
    private var transcribeCalls = 0
    private let failOnCall: Int?

    init(failOnCall: Int? = nil) {
        self.failOnCall = failOnCall
    }

    func prepare() async throws {
        prepareCalls += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCalls += 1
        if failOnCall == transcribeCalls {
            throw NSError(
                domain: "LiveASRSessionTests",
                code: transcribeCalls,
                userInfo: [
                    NSLocalizedDescriptionKey: "forced failure"
                ]
            )
        }
        return ASRResult(text: "segment-\(transcribeCalls)", detectedLanguage: nil)
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCalls, transcribeCalls)
    }
}

private actor SuspendedASREngine: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var transcribeCalls = 0
    private var release: CheckedContinuation<Void, Never>?
    private var waitingForStart: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCalls += 1
        guard transcribeCalls == 1 else {
            return ASRResult(text: "unexpected second result", detectedLanguage: nil)
        }
        waitingForStart?.resume()
        waitingForStart = nil
        await withCheckedContinuation { continuation in
            release = continuation
        }
        return ASRResult(text: "late result", detectedLanguage: nil)
    }

    func waitUntilTranscribing() async {
        if release != nil { return }
        await withCheckedContinuation { continuation in
            waitingForStart = continuation
        }
    }

    func resume() {
        release?.resume()
        release = nil
    }
    func count() -> Int { transcribeCalls }

    func unload() async {}
}

private actor GatedRegistrationWriter: SessionEventAppending {
    private let writer: SessionWriter
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(writer: SessionWriter) {
        self.writer = writer
    }

    func waitUntilAppendStarts() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiter = continuation
        }
    }

    func releaseFirstAppend() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    @discardableResult
    func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) async throws -> EventEnvelope<Payload> {
        if draft.eventType == "segment.created", !entered {
            entered = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                entryWaiter?.resume()
                entryWaiter = nil
            }
        }
        return try await writer.append(draft)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private func makeLiveASRFixture(
    failOnCall: Int? = nil,
    decisionRuns: (boundary: String, priority: String)? = nil
) async throws -> (
    root: URL,
    checkpoint: AudioCheckpoint,
    session: LiveASRSession,
    engine: CountingASREngine
) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let writer = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await writer.committedSnapshot()

    let engine = CountingASREngine(failOnCall: failOnCall)
    let session = LiveASRSession(
        sessionID: UUID(),
        sessionURL: root,
        segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test",
        processingDirectory: root,
        writer: try SessionWriter(sessionURL: root),
        asr: engine,
        sampleRate: checkpoint.sampleRate,
        clauseBoundaryRunID: decisionRuns?.boundary,
        contentPriorityRunID: decisionRuns?.priority
    )
    return (root, checkpoint, session, engine)
}

@Test
func liveASRPreparesOnceAndDoesNotDuplicateSegments() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let firstSegment = SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: "seg_000001",
        startFrame: 0,
        endFrame: 4_000
    )
    let secondSegment = SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: "seg_000002",
        startFrame: 4_000,
        endFrame: 8_000
    )

    let first = try await fixture.session.process(
        segments: [firstSegment],
        checkpoint: fixture.checkpoint
    )
    #expect(first.completedCount == 1)
    #expect(first.materializedSegments.count == 1)

    let repeated = try await fixture.session.process(
        segments: [firstSegment],
        checkpoint: fixture.checkpoint
    )
    #expect(repeated.completedCount == 1)
    #expect(repeated.materializedSegments.count == 1)

    let second = try await fixture.session.process(
        segments: [secondSegment],
        checkpoint: fixture.checkpoint
    )
    #expect(second.completedCount == 2)
    #expect(second.materializedSegments.map(\.text) == [
        "segment-1",
        "segment-2"
    ])

    let counts = await fixture.engine.counts()
    #expect(counts.prepare == 1)
    #expect(counts.transcribe == 2)
}

@Test
func liveASRProgressPreservesRowsAcrossRegistrationAndShowsOnlySavedClauseEvents() async throws {
    let fixture = try await makeLiveASRFixture(decisionRuns: ("boundary_live", "priority_live"))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    let second = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000002",
        startFrame: 4_000, endFrame: 8_000
    )
    let finished = Locked<[LiveASRSegmentStatus]>([])
    let recognized = try await fixture.session.process(
        segments: [first], checkpoint: fixture.checkpoint,
        onSegmentFinished: { status, _ in finished.withValue { $0.append(status) } }
    )
    // Saved ASR is shown at once as normal text while the clause waits for the next segment.
    #expect(recognized.materializedSegments.map(\.clauseState) == [.awaitingNextSegment])
    #expect(recognized.materializedSegments.map(\.displayText) == ["segment-1"])
    let registered = try await fixture.session.register(segments: [first, second, second])
    #expect(registered.materializedSegments == recognized.materializedSegments)
    #expect(registered.pendingCount == 1)
    let snapshot = await fixture.session.snapshot()
    #expect(snapshot.segments.map(\.segmentID) == ["seg_000001", "seg_000002"])
    #expect(snapshot.segments[1].outcome == .pending)
    guard case .recognized(let source, "segment-1") = snapshot.segments[0].outcome else {
        Issue.record("first segment is not recognized")
        return
    }
    #expect(finished.value.map(\.outcome) == [.recognized(source, "segment-1")])
    _ = try await fixture.session.process(segments: [second], checkpoint: fixture.checkpoint)
    let ready = await fixture.session.snapshot()
    guard case .recognized(let nextSource, let nextText) = ready.segments[1].outcome else {
        Issue.record("successor is not recognized")
        return
    }

    let assessment = try ClauseBoundaryAssessment(
        source: source, candidates: [], probabilities: [:],
        nextHead: NextSegmentHead(source: nextSource, text: nextText),
        continuationProbability: 0.05,
        fillerRanges: [],
        request: DecisionRequestRecord(requestID: "boundary_req", inputTokens: 3),
        sourceDecision: .assessed
    )
    let unit = try ClauseUnit(
        reference: ClauseReference(boundaryRunID: "boundary_live", clauseID: "c\(source.asrEventSeq)_0"),
        parts: [ClauseSourcePart(source: source, range: TextUTF16Range(start: 0, end: 9))],
        termination: .notContinued(source: source)
    )
    let closed = try await fixture.session.applyClauseEvents([
        .clause(seq: 100, runID: "boundary_live", kind: .clauseBoundaryAssessed(assessment)),
        .clause(seq: 101, runID: "boundary_live", kind: .clauseClosed(unit)),
    ])
    #expect(closed.progress.materializedSegments.map(\.clauseState) == [.priorityPending, .awaitingNextSegment])
    let low = try ContentPriorityDecision(priority: .lowPriority, confidence: 0.95, probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975])
    let assigned = try ContentPriorityAssignedPayload(assignments: [
        ClausePriorityAssignment(
            reference: unit.reference, priority: .lowPriority, needsRetry: false,
            decision: .classified(requestID: "req", answerKey: "u0001", response: low)
        )
    ], request: DecisionRequestRecord(requestID: "req", inputTokens: 3))
    let classified = try await fixture.session.applyClauseEvents([
        .clause(seq: 102, runID: "priority_live", kind: .contentPriorityAssigned(assigned))
    ])
    #expect(classified.progress.materializedSegments.map(\.clauseState) == [.classified, .awaitingNextSegment])
    #expect(classified.progress.materializedSegments[0].clauseSlices.map(\.priority) == [.lowPriority])
    await #expect(throws: LiveASRSessionError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "priority_final", kind: .contentPriorityAssigned(assigned))
        ])
    }
    await #expect(throws: LiveASRSessionError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "boundary_live", kind: .contentPriorityAssigned(assigned))
        ])
    }
    let unknown = try ClauseReference(boundaryRunID: "boundary_live", clauseID: "c999_0")
    let invalid = try ClausePriorityBatch.pending(
        references: [unknown], reason: .requestFailed, message: "unknown clause"
    )
    await #expect(throws: TranscriptMaterializationError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "priority_live", kind: .contentPriorityAssigned(invalid))
        ])
    }
    #expect(await fixture.session.snapshot().events == classified.events)

    let completed = try await fixture.session.process(
        segments: [second], checkpoint: fixture.checkpoint
    )
    #expect(completed.materializedSegments.map(\.text) == ["segment-1", "segment-2"])
    #expect(completed.materializedSegments.map(\.clauseState) == [.classified, .awaitingNextSegment])
    #expect(completed.pendingCount == 0)
    let finishedRun = try await fixture.session.finish()
    #expect(finishedRun.succeeded)
    #expect(finishedRun.materializedSegments == completed.materializedSegments)
}

@Test(arguments: [false, true])
func liveASRAppendFailurePreservesVisibleRowsAndCounts(completing: Bool) async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    let second = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000002",
        startFrame: 4_000, endFrame: 8_000
    )
    _ = try await fixture.session.process(segments: [first], checkpoint: fixture.checkpoint)
    if completing {
        _ = try await fixture.session.register(segments: [second])
    }
    let before = await fixture.session.snapshot()
    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let backupURL = fixture.root.appending(path: "events.backup")
    try FileManager.default.moveItem(at: eventsURL, to: backupURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        if completing {
            _ = try await fixture.session.process(segments: [second], checkpoint: fixture.checkpoint)
        } else {
            _ = try await fixture.session.register(segments: [second])
        }
    }
    #expect(await fixture.session.snapshot() == before)
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: backupURL, to: eventsURL)
    let registered = try await fixture.session.register(segments: [second])
    #expect(registered.completedCount == 1)
    #expect(registered.failedCount == 0)
    #expect(registered.pendingCount == 1)
    #expect(registered.materializedSegments == before.progress.materializedSegments)
    let completed = try await fixture.session.process(segments: [second], checkpoint: fixture.checkpoint)
    #expect(completed.materializedSegments.map(\.text) == [
        "segment-1", completing ? "segment-3" : "segment-2"
    ])
    #expect(completed.completedCount == 2)
    #expect(completed.failedCount == 0)
    #expect(completed.pendingCount == 0)
    let finished = try await fixture.session.finish()
    #expect(finished.succeeded)
    #expect(finished.materializedSegments == completed.materializedSegments)
}

@Test
func liveASRFinishIsIdempotentAndMarksSuccessfulRun() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segment = SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: "seg_000001",
        startFrame: 0,
        endFrame: 4_000
    )
    _ = try await fixture.session.process(
        segments: [segment],
        checkpoint: fixture.checkpoint
    )

    let first = try await fixture.session.finish()
    let second = try await fixture.session.finish()

    #expect(first.succeeded)
    #expect(first.completedCount == 1)
    #expect(second == first)

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: fixture.root.appending(path: "events.jsonl"))
    )
    let eventTypes = try recovered.lines.map { line in
        let event = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return try #require(event["event_type"] as? String)
    }
    #expect(eventTypes.filter { $0 == "processing.run.completed" }.count == 1)
}

@Test(.timeLimit(.minutes(10)))
func liveASRConcurrentFinishCallersAwaitTheSameCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), sessionURL: root, segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: engine,
        sampleRate: checkpoint.sampleRate,
        clauseBoundaryRunID: nil,
        contentPriorityRunID: nil
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )

    let processing = Task {
        try await session.process(segments: [segment], checkpoint: checkpoint)
    }
    await engine.waitUntilTranscribing()
    let firstFinish = Task { try await session.finish() }
    let secondFinish = Task { try await session.finish() }
    await session.waitForFinishWaiters(2)
    #expect(await session.finishWaiterCount == 2)
    await engine.resume()

    let progress = try await processing.value
    let first = try await firstFinish.value
    let second = try await secondFinish.value
    let subsequent = try await session.finish()
    #expect(progress.completedCount == 1)
    #expect(first == second)
    #expect(subsequent == first)
    #expect(first.succeeded)
    #expect(first.completedCount == 1)
    #expect(first.materializedSegments.map(\.text) == ["late result"])

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let eventTypes = try recovered.lines.map { line in
        let event = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return try #require(event["event_type"] as? String)
    }
    #expect(eventTypes.filter {
        $0 == "asr.completed" || $0 == "processing.run.completed"
    } == ["asr.completed", "processing.run.completed"])
}

@Test
func liveASRFinishRetriesAfterCompletionAppendFailure() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    _ = try await fixture.session.process(
        segments: [segment], checkpoint: fixture.checkpoint
    )

    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let backupURL = fixture.root.appending(path: "events.backup")
    try FileManager.default.moveItem(at: eventsURL, to: backupURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        try await fixture.session.finish()
    }
    let lateSegment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000002",
        startFrame: 4_000, endFrame: 8_000
    )
    let lateProgress = try await fixture.session.register(segments: [lateSegment])
    #expect(lateProgress.completedCount == 1)
    #expect(lateProgress.pendingCount == 0)
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: backupURL, to: eventsURL)

    let completion = try await fixture.session.finish()
    let repeated = try await fixture.session.finish()
    #expect(repeated == completion)
    #expect(completion.succeeded)
    #expect(completion.completedCount == 1)
    #expect(completion.materializedSegments.map(\.text) == ["segment-1"])

    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL))
    let eventTypes = try recovered.lines.map { line in
        let event = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return try #require(event["event_type"] as? String)
    }
    #expect(eventTypes.filter {
        $0 == "asr.completed" || $0 == "processing.run.completed"
    } == ["asr.completed", "processing.run.completed"])
    #expect(eventTypes.filter { $0 == "segment.created" }.count == 1)
}

@Test
func liveASRFailureKeepsRunUnsuccessful() async throws {
    let fixture = try await makeLiveASRFixture(failOnCall: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segments = [
        SegmentReference(
            segmentationRunID: "seg_live_test",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 4_000
        ),
        SegmentReference(
            segmentationRunID: "seg_live_test",
            segmentID: "seg_000002",
            startFrame: 4_000,
            endFrame: 8_000
        )
    ]

    let progress = try await fixture.session.process(
        segments: segments,
        checkpoint: fixture.checkpoint
    )
    #expect(progress.completedCount == 1)
    #expect(progress.failedCount == 1)
    #expect(progress.pendingCount == 0)
    #expect(progress.materializedSegments.map(\.text) == ["segment-1"])
    #expect(try await fixture.session.register(segments: segments) == progress)

    let completion = try await fixture.session.finish()
    #expect(!completion.succeeded)
    #expect(completion.completedCount == 1)
    #expect(completion.failedCount == 1)
    #expect(completion.pendingCount == 0)
    #expect(completion.materializedSegments == progress.materializedSegments)
}

@Test
func liveASRUnwritableFailureStopsProcessingAndLeavesSegmentPending() async throws {
    let fixture = try await makeLiveASRFixture(failOnCall: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001", startFrame: 0, endFrame: 4_000
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000002", startFrame: 4_000, endFrame: 8_000
    )
    let saved = try await fixture.session.process(segments: [first], checkpoint: fixture.checkpoint)
    _ = try await fixture.session.register(segments: [segment])
    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let backupURL = fixture.root.appending(path: "events.backup")
    try FileManager.default.moveItem(at: eventsURL, to: backupURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        try await fixture.session.process(segments: [segment], checkpoint: fixture.checkpoint)
    }
    let pending = await fixture.session.snapshot().progress
    #expect(pending.completedCount == 1)
    #expect(pending.failedCount == 0)
    #expect(pending.pendingCount == 1)
    #expect(pending.materializedSegments == saved.materializedSegments)
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: backupURL, to: eventsURL)
    let retried = try await fixture.session.process(segments: [segment], checkpoint: fixture.checkpoint)
    #expect(retried.failedCount == 0)
    #expect(retried.completedCount == 2)
    #expect(retried.pendingCount == 0)
    #expect(retried.materializedSegments.map(\.text) == ["segment-1", "segment-3"])
    #expect(await fixture.engine.counts().transcribe == 3)
}

@Test
func liveASRFinishFailsWhileRegisteredSegmentsRemainPending() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segment = SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: "seg_000001",
        startFrame: 0,
        endFrame: 4_000
    )
    _ = try await fixture.session.register(segments: [segment])

    let completion = try await fixture.session.finish()

    #expect(!completion.succeeded)
    #expect(completion.pendingCount == 1)
    #expect(completion.failedCount == 0)
}

@Test(.timeLimit(.minutes(10)))
func liveASRDoesNotAppendResultsAfterRunCompleted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), sessionURL: root, segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: engine,
        sampleRate: checkpoint.sampleRate,
        clauseBoundaryRunID: nil,
        contentPriorityRunID: nil
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    let nextSegment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000002",
        startFrame: 4_000, endFrame: 8_000
    )
    _ = try await session.register(segments: [segment, nextSegment])

    let processing = Task {
        try await session.process(
            segments: [segment, nextSegment], checkpoint: checkpoint
        )
    }
    await engine.waitUntilTranscribing()
    let finishing = Task { try await session.finish() }
    await session.waitForFinishWaiters(1)
    #expect(await session.finishWaiterCount == 1)
    await engine.resume()
    let lateProgress = try await processing.value
    let completion = try await finishing.value

    #expect(lateProgress.completedCount == 1)
    #expect(completion.completedCount == lateProgress.completedCount)
    #expect(lateProgress.pendingCount == 1)
    #expect(completion.pendingCount == 1)
    #expect(!completion.succeeded)
    #expect(await engine.count() == 1)

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let eventTypes = try recovered.lines.map { line in
        let event = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return try #require(event["event_type"] as? String)
    }
    #expect(eventTypes.filter {
        $0 == "asr.completed" || $0 == "processing.run.completed"
    } == ["asr.completed", "processing.run.completed"])
}

@Test(.timeLimit(.minutes(10)))
func cancelledLiveASRProcessingRetainsRegisteredSegmentsForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), sessionURL: root, segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: engine,
        sampleRate: checkpoint.sampleRate,
        clauseBoundaryRunID: nil,
        contentPriorityRunID: nil
    )
    let segments = (0..<3).map { index in
        SegmentReference(
            segmentationRunID: "seg_live_test", segmentID: "seg_00000\(index + 1)",
            startFrame: Int64(index) * 4_000, endFrame: Int64(index + 1) * 4_000
        )
    }
    _ = try await session.register(segments: segments)

    let processing = Task {
        try await session.process(segments: segments, checkpoint: checkpoint)
    }
    await engine.waitUntilTranscribing()
    processing.cancel()
    await engine.resume()

    do {
        _ = try await processing.value
        Issue.record("cancelled processing unexpectedly completed")
    } catch is CancellationError {
    } catch {
        Issue.record("cancelled processing threw an unexpected error: \(error)")
    }
    #expect(await engine.count() == 1)

    let eventsURL = root.appending(path: "events.jsonl")
    let cancelledEvents = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL)).lines.map { line in
        let event = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        return (type: try #require(event["event_type"] as? String), segmentID: event["segment_id"] as? String)
    }
    #expect(cancelledEvents.filter { $0.type == "segment.created" }.compactMap(\.segmentID) == segments.map(\.segmentID))
    #expect(cancelledEvents.allSatisfy { $0.type != "asr.completed" && $0.type != "asr.failed" })

    let retried = try await session.process(segments: segments, checkpoint: checkpoint)
    #expect(retried.completedCount == segments.count)
    #expect(retried.failedCount == 0)
    #expect(retried.pendingCount == 0)
    #expect(retried.materializedSegments.count == segments.count)
    #expect(await engine.count() == segments.count + 1)

    let recoveredEvents = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL)).lines.map { line in
        let event = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        return (type: try #require(event["event_type"] as? String), segmentID: event["segment_id"] as? String)
    }
    let completedSegmentIDs = recoveredEvents
        .filter { $0.type == "asr.completed" }
        .compactMap(\.segmentID)
    #expect(completedSegmentIDs == segments.map(\.segmentID))
    #expect(recoveredEvents.allSatisfy { $0.type != "asr.failed" })
}

@Test(.timeLimit(.minutes(10)))
func liveASRConcurrentRegistrationPersistsSegmentOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let durableWriter = try SessionWriter(sessionURL: root)
    let writer = GatedRegistrationWriter(writer: durableWriter)
    let engine = CountingASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), sessionURL: root, segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: writer, asr: engine, sampleRate: 16_000,
        clauseBoundaryRunID: nil,
        contentPriorityRunID: nil
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )

    let first = Task {
        try await session.register(segments: [segment])
    }
    await writer.waitUntilAppendStarts()
    let second = try await session.register(segments: [segment])
    #expect(second.pendingCount == 0)
    #expect(await session.snapshot().segments.isEmpty)

    await writer.releaseFirstAppend()
    _ = try await first.value
    let progress = await session.snapshot().progress
    #expect(progress.pendingCount == 1)
    #expect(progress.completedCount == 0)
    #expect(progress.failedCount == 0)
    #expect(progress.materializedSegments.isEmpty)

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let eventTypes = try recovered.lines.map { line in
        let event = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        return try #require(event["event_type"] as? String)
    }
    #expect(eventTypes.filter { $0 == "segment.created" }.count == 1)
}

/// Measures duplicate pending registration without inference or recognized-row updates.
/// Five-second event cadence; uses pending references, not hours of allocated audio.
@Test("Measure live registration cost at 10-minute, 1-hour and 4-hour event equivalents", .enabled(if: ProcessInfo.processInfo.environment["LIVE_ASR_REGISTRATION_MEASUREMENT"] == "1"))
func measureLiveRegistrationCost() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var previous = 0
    for count in [120, 720, 2_880] {
        let segments = (previous..<count).map { index in
            SegmentReference(
                segmentationRunID: "seg_live_test", segmentID: "row_\(index)",
                startFrame: Int64(index) * 80_000, endFrame: Int64(index + 1) * 80_000
            )
        }
        _ = try await fixture.session.register(segments: segments)
        let repeated = try #require(segments.last)
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = ContinuousClock.now
            var pending = 0
            for _ in 0..<100 {
                pending = try await fixture.session.register(segments: [repeated]).pendingCount
            }
            let duration = start.duration(to: .now).components
            samples.append((Double(duration.seconds) * 1_000_000
                + Double(duration.attoseconds) / 1_000_000_000_000) / 100)
            #expect(pending == count)
        }
        let median = samples.sorted()[3]
        print("LIVE_ASR registration equivalent_seconds=\(count * 5) pending=\(count) median_us=\(median)")
        previous = count
    }
}
