import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private actor CountingASREngine: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var prepareCalls = 0
    private var transcribeCalls = 0
    private var inputSampleCounts: [Int] = []
    private let failOnCall: Int?
    private let emptyOnCall: Int?

    init(failOnCall: Int? = nil, emptyOnCall: Int? = nil) {
        self.failOnCall = failOnCall
        self.emptyOnCall = emptyOnCall
    }

    func prepare() async throws {
        prepareCalls += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCalls += 1
        inputSampleCounts.append(input.samples.count)
        if failOnCall == transcribeCalls {
            throw NSError(
                domain: "LiveASRSessionTests",
                code: transcribeCalls,
                userInfo: [
                    NSLocalizedDescriptionKey: "forced failure"
                ]
            )
        }
        return ASRResult(text: emptyOnCall == transcribeCalls ? "" : "segment-\(transcribeCalls)", detectedLanguage: nil)
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCalls, transcribeCalls)
    }
    func inputCounts() -> [Int] { inputSampleCounts }
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

private actor DurableThenGatedRegistrationWriter: SessionEventAppending {
    private let writer: SessionWriter
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(writer: SessionWriter) {
        self.writer = writer
    }

    func waitUntilDurableAppendReturns() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiter = continuation
        }
    }

    func releaseAppendReturn() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    @discardableResult
    func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) async throws -> EventEnvelope<Payload> {
        let envelope = try await writer.append(draft)
        if draft.eventType == "segment.created", !entered {
            entered = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                entryWaiter?.resume()
                entryWaiter = nil
            }
        }
        return envelope
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

let fakeSegmentationProvenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])

func seedLivePipeline(
    writer: SessionWriter,
    sessionID: UUID,
    segmentationRunID: String,
    asrRunID: String,
    sampleRate: Double,
    asrProvenance: RunProvenance,
    decisionRuns: (boundary: String, priority: String)? = nil
) async throws {
    let generation = PipelineGeneration(
        id: UUID(),
        runs: ActiveRuns(
            segmentation: segmentationRunID, asr: asrRunID,
            clauseBoundary: decisionRuns?.boundary, contentPriority: decisionRuns?.priority
        ),
        sampleRate: sampleRate,
        segmentationProvenance: fakeSegmentationProvenance,
        asrProvenance: asrProvenance
    )
    _ = try await writer.append(generation.startEvent(sessionID: sessionID))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: sessionID,
        processingRunID: segmentationRunID,
        payload: ProcessingRunStartedPayload(stage: .segmentation, provenance: generation.segmentationProvenance)
    ))
}

private func sealLiveSegmentation(
    writer: SessionWriter,
    sessionID: UUID,
    segmentationRunID: String,
    frameCount: Int64,
    segmentCount: Int
) async throws {
    _ = try await writer.append(EventDraft(
        eventType: "segmentation.input.sealed", sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        payload: SegmentationInputSealedPayload(frameCount: frameCount)
    ))
    _ = try await writer.append(EventDraft(
        eventType: "segmentation.completed", sessionID: sessionID,
        segmentationRunID: segmentationRunID,
        payload: SegmentationCompletedPayload(consumedFrames: frameCount, segmentCount: segmentCount)
    ))
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: sessionID,
        processingRunID: segmentationRunID,
        payload: ProcessingRunCompletedPayload(stage: .segmentation, succeeded: true, completedCount: segmentCount, failedCount: 0)
    ))
}
private func makeLiveASRFixture(
    failOnCall: Int? = nil,
    emptyOnCall: Int? = nil,
    decisionRuns: (boundary: String, priority: String)? = nil
) async throws -> (
    root: URL,
    checkpoint: AudioCheckpoint,
    sessionID: UUID,
    session: LiveASRSession,
    engine: CountingASREngine
) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )

    let audioWriter = try DurableAudioWriter(
        directory: SessionLayout(sessionURL: root).processingDirectory,
        chunkDurationSeconds: 1,
        sessionURL: root
    )
    try await audioWriter.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await audioWriter.committedSnapshot()

    let engine = CountingASREngine(failOnCall: failOnCall, emptyOnCall: emptyOnCall)
    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    try await seedLivePipeline(
        writer: writer, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: checkpoint.sampleRate,
        asrProvenance: engine.provenance, decisionRuns: decisionRuns
    )
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    return (root, checkpoint, sessionID, session, engine)
}

@Test(arguments: [0, 1, 2])
func reopeningProcessesOnlySegmentsWithoutSuccessfulResults(_ interruption: Int) async throws {
    let fixture = try await makeLiveASRFixture(
        failOnCall: interruption == 2 ? 2 : nil, emptyOnCall: 1
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segmentationRunID = "seg_pipeline_test", asrRunID = "asr_pipeline_test"
    let first = SegmentReference(segmentationRunID: segmentationRunID, segmentID: "seg_000001", speechRanges: [0..<1_000, 2_000..<2_500])
    let second = SegmentReference(segmentationRunID: segmentationRunID, segmentID: "seg_000002", speechRanges: [4_000..<6_000])
    let third = SegmentReference(segmentationRunID: segmentationRunID, segmentID: "seg_000003", speechRanges: [8_000..<11_000])
    let segments = [first, second, third]
    let reader = try ProcessingTimelineReader(directory: SessionLayout(sessionURL: fixture.root).processingDirectory, checkpoint: fixture.checkpoint, sessionURL: fixture.root)
    if interruption == 0 {
        _ = try await fixture.session.register(segments: [first, second, third])
    } else {
        let initial = try await fixture.session.process(segments: [first], reader: reader)
        #expect(initial.completedCount == 1)
        _ = try await fixture.session.register(segments: [second, third])
        if interruption == 2 {
            let failed = try await fixture.session.process(reader: reader)
            #expect(failed.completedCount == 1 && failed.failedCount == 1 && failed.pendingCount == 2)
            _ = try await fixture.session.process(reader: reader)
            #expect(await fixture.engine.inputCounts() == [1_500, 2_000])
        }
    }
    let resumedEngine = CountingASREngine(emptyOnCall: interruption == 0 ? 1 : nil)
    let resumed = try await LiveASRSession.open(
        sessionID: fixture.sessionID, sessionURL: fixture.root,
        writer: try SessionWriter(sessionURL: fixture.root), asr: resumedEngine
    )
    let hydrated = await resumed.snapshot()
    let pendingIDs = interruption == 0
        ? segments.map(\.segmentID)
        : [second.segmentID, third.segmentID]
    #expect(
        hydrated.progress.completedCount == (interruption == 0 ? 0 : 1)
            && hydrated.progress.pendingCount == pendingIDs.count
    )
    #expect(
        hydrated.segments.filter { $0.outcome == .pending }.map(\.segmentID) == pendingIDs
            && hydrated.segments.map(\.startFrame) == [0, 4_000, 8_000]
    )

    let progress = try await resumed.process(reader: reader)
    #expect(progress.completedCount == 3 && progress.failedCount == 0 && progress.pendingCount == 0)
    let expectedTexts = interruption == 0
        ? ["", "segment-2", "segment-3"]
        : ["", "segment-1", "segment-2"]
    #expect(progress.materializedSegments.map(\.text) == expectedTexts)
    #expect(await resumedEngine.inputCounts() == (interruption == 0 ? [1_500, 2_000, 3_000] : [2_000, 3_000]))

    let bytes = try Data(contentsOf: fixture.root.appending(path: "events.jsonl"))
    let events = try SessionRecovery.recoverJSONL(bytes).lines.map {
        try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
    }
    let completed = events.filter { $0["event_type"] as? String == "asr.completed" && $0["processing_run_id"] as? String == asrRunID }
    #expect(completed.compactMap { $0["segment_id"] as? String } == segments.map(\.segmentID))
    #expect(completed.compactMap { ($0["payload"] as? [String: Any])?["outcome"] as? String } == ["empty", "recognized", "recognized"])
    let createdSegments = events.filter { $0["event_type"] as? String == "segment.created" && $0["segmentation_run_id"] as? String == segmentationRunID }
    #expect(createdSegments.count == 3)
    let failures = events.filter { $0["event_type"] as? String == "asr.failed" && $0["processing_run_id"] as? String == asrRunID }
    #expect(failures.compactMap { $0["segment_id"] as? String } == (interruption == 2 ? [second.segmentID] : []))
    let starts = events.filter { $0["event_type"] as? String == "processing.run.started" && $0["processing_run_id"] as? String == asrRunID }
    #expect(starts.count == 1 && (starts.first?["payload"] as? [String: Any])?["stage"] as? String == "asr")
    let repeatedEngine = CountingASREngine()
    let repeated = try await LiveASRSession.open(
        sessionID: fixture.sessionID, sessionURL: fixture.root,
        writer: try SessionWriter(sessionURL: fixture.root), asr: repeatedEngine
    )
    #expect(try await repeated.process(reader: reader).completedCount == 3)
    #expect(await repeatedEngine.inputCounts().isEmpty)
    #expect(try Data(contentsOf: fixture.root.appending(path: "events.jsonl")) == bytes)
}

@Test
func reopeningRejectsDuplicateSuccessfulResult() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segment = SegmentReference(segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001", speechRanges: [0..<4_000])
    _ = try await fixture.session.process(segments: [segment], checkpoint: fixture.checkpoint)
    let payload = ASRCompletedEventPayload(
        text: "segment-1",
        detectedLanguage: nil,
        provenance: fixture.engine.provenance
    )
    _ = try await SessionWriter(sessionURL: fixture.root).append(EventDraft(
        eventType: "asr.completed", sessionID: fixture.sessionID, processingRunID: "asr_pipeline_test",
        segmentationRunID: "seg_pipeline_test", segmentID: segment.segmentID,
        sourceStartFrame: segment.startFrame, sourceEndFrame: segment.endFrame, payload: payload))
    await #expect(throws: ProcessingLogStateError.duplicateSuccessfulResult(segmentID: segment.segmentID)) {
        try await LiveASRSession.open(
            sessionID: fixture.sessionID, sessionURL: fixture.root,
            writer: try SessionWriter(sessionURL: fixture.root), asr: CountingASREngine()
        )
    }
}

@Test
func liveASRPreparesOnceAndDoesNotDuplicateSegments() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let firstSegment = SegmentReference(
        segmentationRunID: "seg_pipeline_test",
        segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    let secondSegment = SegmentReference(
        segmentationRunID: "seg_pipeline_test",
        segmentID: "seg_000002",
        speechRanges: [4_000..<8_000]
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
    let fixture = try await makeLiveASRFixture(decisionRuns: ("boundary_pipeline", "priority_pipeline"))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    let second = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002",
        speechRanges: [4_000..<8_000]
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
        reference: ClauseReference(boundaryRunID: "boundary_pipeline", clauseID: "c\(source.asrEventSeq)_0"),
        parts: [ClauseSourcePart(source: source, range: TextUTF16Range(start: 0, end: 9))],
        termination: .notContinued(source: source)
    )
    let closed = try await fixture.session.applyClauseEvents([
        .clause(seq: 100, runID: "boundary_pipeline", kind: .clauseBoundaryAssessed(assessment)),
        .clause(seq: 101, runID: "boundary_pipeline", kind: .clauseClosed(unit)),
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
        .clause(seq: 102, runID: "priority_pipeline", kind: .contentPriorityAssigned(assigned))
    ])
    #expect(classified.progress.materializedSegments.map(\.clauseState) == [.classified, .awaitingNextSegment])
    #expect(classified.progress.materializedSegments[0].clauseSlices.map(\.priority) == [.lowPriority])
    await #expect(throws: LiveASRSessionError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "priority_other", kind: .contentPriorityAssigned(assigned))
        ])
    }
    await #expect(throws: LiveASRSessionError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "boundary_pipeline", kind: .contentPriorityAssigned(assigned))
        ])
    }
    let unknown = try ClauseReference(boundaryRunID: "boundary_pipeline", clauseID: "c999_0")
    let invalid = try ClausePriorityBatch.pending(
        references: [unknown], reason: .requestFailed, message: "unknown clause"
    )
    await #expect(throws: TranscriptMaterializationError.self) {
        try await fixture.session.applyClauseEvents([
            .clause(seq: 103, runID: "priority_pipeline", kind: .contentPriorityAssigned(invalid))
        ])
    }
    #expect(await fixture.session.snapshot().events == classified.events)

    let completed = try await fixture.session.process(
        segments: [second], checkpoint: fixture.checkpoint
    )
    #expect(completed.materializedSegments.map(\.text) == ["segment-1", "segment-2"])
    #expect(completed.materializedSegments.map(\.clauseState) == [.classified, .awaitingNextSegment])
    #expect(completed.pendingCount == 0)
    try await sealLiveSegmentation(
        writer: try SessionWriter(sessionURL: fixture.root), sessionID: fixture.sessionID,
        segmentationRunID: "seg_pipeline_test", frameCount: fixture.checkpoint.committedFrames,
        segmentCount: 2
    )
    let finishedRun = try await fixture.session.finish()
    #expect(finishedRun.succeeded)
    #expect(finishedRun.materializedSegments == completed.materializedSegments)
}

@Test(arguments: [false, true])
func liveASRAppendFailurePreservesVisibleRowsAndCounts(completing: Bool) async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    let second = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002",
        speechRanges: [4_000..<8_000]
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
    try await sealLiveSegmentation(
        writer: try SessionWriter(sessionURL: fixture.root), sessionID: fixture.sessionID,
        segmentationRunID: "seg_pipeline_test", frameCount: fixture.checkpoint.committedFrames,
        segmentCount: 2
    )
    let finished = try await fixture.session.finish()
    #expect(finished.succeeded)
    #expect(finished.materializedSegments == completed.materializedSegments)
}

@Test
func liveASRFinishIsIdempotentAndMarksSuccessfulRun() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test",
        segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    _ = try await fixture.session.process(
        segments: [segment],
        checkpoint: fixture.checkpoint
    )

    try await sealLiveSegmentation(
        writer: try SessionWriter(sessionURL: fixture.root), sessionID: fixture.sessionID,
        segmentationRunID: "seg_pipeline_test", frameCount: fixture.checkpoint.committedFrames,
        segmentCount: 1
    )
    let first = try await fixture.session.finish()
    let second = try await fixture.session.finish()

    #expect(first.succeeded)
    #expect(first.completedCount == 1)
    #expect(second == first)
    let reopened = try await LiveASRSession.open(
        sessionID: fixture.sessionID, sessionURL: fixture.root,
        writer: try SessionWriter(sessionURL: fixture.root), asr: CountingASREngine()
    )
    #expect(try await reopened.finish() == first)

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: fixture.root.appending(path: "events.jsonl"))
    )
    let events = try recovered.lines.map { line in
        try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }
    #expect(events.filter {
        $0["event_type"] as? String == "processing.run.completed"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == "asr"
    }.count == 1)
}

@Test(.timeLimit(.minutes(10)))
func liveASRConcurrentFinishCallersAwaitTheSameCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(
        directory: SessionLayout(sessionURL: root).processingDirectory,
        chunkDurationSeconds: 1,
        sessionURL: root
    )
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    try await seedLivePipeline(
        writer: writer, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: checkpoint.sampleRate,
        asrProvenance: engine.provenance
    )
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    _ = try await session.register(segments: [segment])
    try await sealLiveSegmentation(
        writer: writer, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        frameCount: checkpoint.committedFrames, segmentCount: 1
    )

    let processing = Task {
        try await session.process(reader: try ProcessingTimelineReader(
            directory: SessionLayout(sessionURL: root).processingDirectory, checkpoint: checkpoint, sessionURL: root
        ))
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
    } == ["processing.run.completed", "asr.completed", "processing.run.completed"])
}

@Test
func liveASRFinishRetriesAfterCompletionAppendFailure() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
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
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002",
        speechRanges: [4_000..<8_000]
    )
    let lateProgress = try await fixture.session.register(segments: [lateSegment])
    #expect(lateProgress.completedCount == 1)
    #expect(lateProgress.pendingCount == 0)
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: backupURL, to: eventsURL)
    try await sealLiveSegmentation(
        writer: try SessionWriter(sessionURL: fixture.root), sessionID: fixture.sessionID,
        segmentationRunID: "seg_pipeline_test", frameCount: fixture.checkpoint.committedFrames,
        segmentCount: 1
    )

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
    } == ["asr.completed", "processing.run.completed", "processing.run.completed"])
    #expect(eventTypes.filter { $0 == "segment.created" }.count == 1)
}

@Test
func liveASRFailureKeepsRunUnsuccessful() async throws {
    let fixture = try await makeLiveASRFixture(failOnCall: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segments = [
        SegmentReference(
            segmentationRunID: "seg_pipeline_test",
            segmentID: "seg_000001",
            speechRanges: [0..<4_000]
        ),
        SegmentReference(
            segmentationRunID: "seg_pipeline_test",
            segmentID: "seg_000002",
            speechRanges: [4_000..<8_000]
        )
    ]

    let progress = try await fixture.session.process(
        segments: segments,
        checkpoint: fixture.checkpoint
    )
    #expect(progress.completedCount == 1)
    #expect(progress.failedCount == 1)
    #expect(progress.pendingCount == 1)
    #expect(progress.materializedSegments.map(\.text) == ["segment-1"])
    #expect(try await fixture.session.register(segments: segments) == progress)

    let completion = try await fixture.session.finish()
    #expect(!completion.succeeded)
    #expect(completion.completedCount == 1)
    #expect(completion.failedCount == 1)
    #expect(completion.pendingCount == 1)
    #expect(completion.materializedSegments == progress.materializedSegments)
}

@Test
func liveASRUnwritableFailureStopsProcessingAndLeavesSegmentPending() async throws {
    let fixture = try await makeLiveASRFixture(failOnCall: 2)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001", speechRanges: [0..<4_000]
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002", speechRanges: [4_000..<8_000]
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
        segmentationRunID: "seg_pipeline_test",
        segmentID: "seg_000001",
        speechRanges: [0..<4_000]
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

    let audio = try DurableAudioWriter(
        directory: SessionLayout(sessionURL: root).processingDirectory,
        chunkDurationSeconds: 1,
        sessionURL: root
    )
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    try await seedLivePipeline(
        writer: writer, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: checkpoint.sampleRate,
        asrProvenance: engine.provenance
    )
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    let nextSegment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002",
        speechRanges: [4_000..<8_000]
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
    } == ["asr.completed"])
}

@Test(.timeLimit(.minutes(10)))
func cancelledLiveASRProcessingRetainsRegisteredSegmentsForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(
        directory: SessionLayout(sessionURL: root).processingDirectory,
        chunkDurationSeconds: 1,
        sessionURL: root
    )
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    try await seedLivePipeline(
        writer: writer, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: checkpoint.sampleRate,
        asrProvenance: engine.provenance
    )
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    let segments = (0..<3).map { index in
        SegmentReference(
            segmentationRunID: "seg_pipeline_test", segmentID: "seg_00000\(index + 1)",
            speechRanges: [Int64(index) * 4_000..<Int64(index + 1) * 4_000]
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
    let engine = CountingASREngine()
    let sessionID = UUID()
    try await seedLivePipeline(
        writer: durableWriter, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: 16_000, asrProvenance: engine.provenance
    )
    let writer = GatedRegistrationWriter(writer: durableWriter)
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
        speechRanges: [0..<4_000]
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

@Test(.timeLimit(.minutes(10)))
func liveASRRegistrationCompletesAfterDurableAppendDespiteCallerCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let durableWriter = try SessionWriter(sessionURL: root)
    let engine = CountingASREngine()
    let sessionID = UUID()
    try await seedLivePipeline(
        writer: durableWriter, sessionID: sessionID, segmentationRunID: "seg_pipeline_test",
        asrRunID: "asr_pipeline_test", sampleRate: 16_000, asrProvenance: engine.provenance
    )
    let writer = DurableThenGatedRegistrationWriter(writer: durableWriter)
    let session = try await LiveASRSession.open(
        sessionID: sessionID, sessionURL: root, writer: writer, asr: engine
    )
    let segment = SegmentReference(
        segmentationRunID: "seg_pipeline_test", segmentID: "seg_cancelled_register",
        speechRanges: [0..<4_000]
    )
    let registration = Task {
        try await session.register(segments: [segment])
    }

    await writer.waitUntilDurableAppendReturns()
    registration.cancel()
    await writer.releaseAppendReturn()

    let progress = try await registration.value
    #expect(progress.pendingCount == 1)
    #expect(progress.completedCount == 0)
    #expect(progress.failedCount == 0)
    #expect(progress.materializedSegments.isEmpty)

    let snapshot = await session.snapshot()
    #expect(snapshot.segments.map(\.segmentID) == [segment.segmentID])
    #expect(snapshot.segments.first?.outcome == .pending)
    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let savedSegments = try recovered.lines.compactMap { line -> String? in
        let event = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        guard event["event_type"] as? String == "segment.created" else { return nil }
        return try #require(event["segment_id"] as? String)
    }
    #expect(savedSegments == [segment.segmentID])
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
                segmentationRunID: "seg_pipeline_test", segmentID: "row_\(index)",
                speechRanges: [Int64(index) * 80_000..<Int64(index + 1) * 80_000]
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

@Test
func liveAndStoredExecutionSaveTheSameSegmentResults() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segments = [
        SegmentReference(
            segmentationRunID: "seg_pipeline_test", segmentID: "seg_000001",
            speechRanges: [0..<2_000, 3_000..<4_000]
        ),
        SegmentReference(
            segmentationRunID: "seg_pipeline_test", segmentID: "seg_000002",
            speechRanges: [4_000..<8_000]
        )
    ]
    let liveEventsURL = fixture.root.appending(path: "events.jsonl")
    let first = try await fixture.session.process(segments: [segments[0]], checkpoint: fixture.checkpoint)
    #expect(first.completedCount == 1)
    #expect(!String(decoding: try Data(contentsOf: liveEventsURL), as: UTF8.self).contains("processing.run.completed"))
    let second = try await fixture.session.process(segments: [segments[1]], checkpoint: fixture.checkpoint)
    #expect(second.completedCount == 2)
    #expect(!String(decoding: try Data(contentsOf: liveEventsURL), as: UTF8.self).contains("processing.run.completed"))
    try await sealLiveSegmentation(
        writer: try SessionWriter(sessionURL: fixture.root), sessionID: fixture.sessionID,
        segmentationRunID: "seg_pipeline_test", frameCount: fixture.checkpoint.committedFrames,
        segmentCount: 2
    )
    let liveCompletion = try await fixture.session.finish()
    #expect(liveCompletion.completedCount == 2)
    #expect(liveCompletion.materializedSegments.map(\.text) == ["segment-1", "segment-2"])

    let storedRoot = fixture.root.appending(path: "stored")
    try FileManager.default.createDirectory(at: storedRoot, withIntermediateDirectories: true)
    let storedWriter = try SessionWriter(sessionURL: storedRoot)
    let storedSessionID = UUID()
    let storedEngine = CountingASREngine()
    try await seedLivePipeline(
        writer: storedWriter, sessionID: storedSessionID,
        segmentationRunID: "seg_pipeline_test", asrRunID: "asr_pipeline_test",
        sampleRate: fixture.checkpoint.sampleRate, asrProvenance: storedEngine.provenance
    )
    _ = try await storedWriter.append(EventDraft(
        eventType: "processing.run.started", sessionID: storedSessionID,
        processingRunID: "asr_pipeline_test",
        payload: ProcessingRunStartedPayload(stage: .asr, provenance: storedEngine.provenance)
    ))
    var pendingSince: [String: Date] = [:]
    for segment in segments {
        _ = try await storedWriter.append(.segmentCreated(sessionID: storedSessionID, segment: segment))
        let pending = try await storedWriter.append(EventDraft(
            eventType: "asr.pending", sessionID: storedSessionID, processingRunID: "asr_pipeline_test",
            segmentationRunID: "seg_pipeline_test", segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame, sourceEndFrame: segment.endFrame, payload: EmptyPayload()
        ))
        pendingSince[segment.segmentID] = pending.createdAt
    }
    let reader = try ProcessingTimelineReader(
        directory: SessionLayout(sessionURL: fixture.root).processingDirectory, checkpoint: fixture.checkpoint, sessionURL: fixture.root
    )
    let coordinator = PipelineCoordinator(
        sessionID: storedSessionID, segmentationRunID: "seg_pipeline_test", asrRunID: "asr_pipeline_test",
        writer: storedWriter, asr: storedEngine, loader: ASRAudioLoader(reader: reader),
        pacingMode: .normal, sleep: { try await Task.sleep(for: $0) }, shouldPause: { nil }
    )
    let stored = try await coordinator.run(segments: segments, pendingSince: pendingSince, existingEvents: [])
    if case .completed = stored.disposition { } else { Issue.record("stored ASR run did not complete") }
    #expect(stored.completedCount == 2)

    func savedResults(at root: URL) throws -> [NSDictionary] {
        let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: root.appending(path: "events.jsonl")))
        return try recovered.lines.compactMap { line in
            var event = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            guard event["event_type"] as? String == "asr.completed" else { return nil }
            for key in ["event_seq", "event_id", "created_at", "session_id"] { event.removeValue(forKey: key) }
            return event as NSDictionary
        }
    }
    let liveResults = try savedResults(at: fixture.root)
    let storedResults = try savedResults(at: storedRoot)
    #expect(liveResults.count == 2)
    #expect(storedResults.count == 2)
    #expect(liveResults == storedResults)
    #expect(liveResults.compactMap { ($0["payload"] as? NSDictionary)?["text"] as? String } == ["segment-1", "segment-2"])
}
