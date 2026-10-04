import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

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

private func makeLiveASRFixture(
    failOnCall: Int? = nil
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

    let writer = try DurableAudioWriter(
        directory: root,
        sampleRate: 16_000,
        channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await writer.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await writer.committedSnapshot()

    let engine = CountingASREngine(failOnCall: failOnCall)
    let session = LiveASRSession(
        sessionID: UUID(),
        segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test",
        processingDirectory: root,
        writer: try SessionWriter(sessionURL: root),
        asr: engine,
        sampleRate: checkpoint.sampleRate
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
func liveASRProgressPreservesRowsAcrossRegistrationAndRefreshesPriorityRuns() async throws {
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
    let recognized = try await fixture.session.process(
        segments: [first], checkpoint: fixture.checkpoint
    )
    let registered = try await fixture.session.register(segments: [first, second, second])
    #expect(registered.materializedSegments == recognized.materializedSegments)
    #expect(registered.completedCount == 1)
    #expect(registered.failedCount == 0)
    #expect(registered.pendingCount == 1)
    #expect(try await fixture.session.register(segments: [first, second]) == registered)

    let classified = await fixture.session.applyContentPriority(event: .contentPriority(
        seq: 100, runID: "priority_a", segmentID: first.segmentID, priority: .lowPriority
    ))
    #expect(classified.progress.materializedSegments.map(\.contentPriority) == [.lowPriority])
    let revised = await fixture.session.applyContentPriority(event: .contentPriority(
        seq: 101, runID: "priority_a", segmentID: first.segmentID, priority: .primary
    ))
    #expect(revised.progress.materializedSegments.map(\.contentPriority) == [.primary])
    #expect(classified.progress.materializedSegments.map(\.contentPriority) == [.lowPriority])

    // A new active run on a pending row also removes assignments from the old run.
    let switched = await fixture.session.applyContentPriority(event: .contentPriority(
        seq: 102, runID: "priority_b", segmentID: second.segmentID, priority: .lowPriority
    ))
    #expect(switched.activeRuns.contentPriority == "priority_b")
    #expect(switched.progress.materializedSegments.map(\.contentPriority) == [nil])
    #expect(switched.progress.pendingCount == 1)
    #expect(try await fixture.session.register(segments: [second]) == switched.progress)

    let completed = try await fixture.session.process(
        segments: [second], checkpoint: fixture.checkpoint
    )
    #expect(completed.materializedSegments.map(\.text) == ["segment-1", "segment-2"])
    #expect(completed.materializedSegments.map(\.contentPriority) == [nil, .lowPriority])
    #expect(completed.completedCount == 2)
    #expect(completed.failedCount == 0)
    #expect(completed.pendingCount == 0)
    #expect(await fixture.session.snapshot().progress == completed)
    let finished = try await fixture.session.finish()
    #expect(finished.succeeded)
    #expect(finished.materializedSegments == completed.materializedSegments)
    #expect(finished.completedCount == 2)
    #expect(finished.failedCount == 0)
    #expect(finished.pendingCount == 0)
    #expect(registered.materializedSegments == recognized.materializedSegments)
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

    let eventsText = try String(
        contentsOf: fixture.root.appending(path: "events.jsonl"),
        encoding: .utf8
    )
    #expect(
        eventsText.components(
            separatedBy: "\"event_type\":\"processing.run.completed\""
        ).count - 1 == 1
    )
}

@Test
func liveASRConcurrentFinishCallersAwaitTheSameCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(
        directory: root, sampleRate: 16_000, channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: engine,
        sampleRate: checkpoint.sampleRate
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
    try await Task.sleep(for: .milliseconds(200))
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
    let fixture = try await makeLiveASRFixture(failOnCall: 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )
    _ = try await fixture.session.register(segments: [segment])

    let eventsURL = fixture.root.appending(path: "events.jsonl")
    let backupURL = fixture.root.appending(path: "events.backup")
    try FileManager.default.moveItem(at: eventsURL, to: backupURL)
    try FileManager.default.createDirectory(at: eventsURL, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        try await fixture.session.process(segments: [segment], checkpoint: fixture.checkpoint)
    }
    let pending = await fixture.session.snapshot().progress
    #expect(pending.completedCount == 0)
    #expect(pending.failedCount == 0)
    #expect(pending.pendingCount == 1)
    #expect(pending.materializedSegments.isEmpty)
    try FileManager.default.removeItem(at: eventsURL)
    try FileManager.default.moveItem(at: backupURL, to: eventsURL)

    let retried = try await fixture.session.process(segments: [segment], checkpoint: fixture.checkpoint)
    #expect(retried.failedCount == 0)
    #expect(retried.completedCount == 1)
    #expect(retried.pendingCount == 0)
    #expect(await fixture.engine.counts().transcribe == 2)
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

@Test
func liveASRDoesNotAppendResultsAfterRunCompleted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = try DurableAudioWriter(
        directory: root, sampleRate: 16_000, channelCount: 1,
        chunkDurationSeconds: 1
    )
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let engine = SuspendedASREngine()
    let session = LiveASRSession(
        sessionID: UUID(), segmentationRunID: "seg_live_test",
        asrRunID: "asr_live_test", processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: engine,
        sampleRate: checkpoint.sampleRate
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
    try await Task.sleep(for: .milliseconds(200))
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

@Test
func liveASRConcurrentRegistrationPersistsSegmentOnce() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let segment = SegmentReference(
        segmentationRunID: "seg_live_test", segmentID: "seg_000001",
        startFrame: 0, endFrame: 4_000
    )

    async let first = fixture.session.register(segments: [segment])
    async let second = fixture.session.register(segments: [segment])
    _ = try await (first, second)
    let progress = await fixture.session.snapshot().progress
    #expect(progress.pendingCount == 1)
    #expect(progress.completedCount == 0)
    #expect(progress.failedCount == 0)
    #expect(progress.materializedSegments.isEmpty)

    let log = try String(
        contentsOf: fixture.root.appending(path: "events.jsonl"),
        encoding: .utf8
    )
    let createdCount = log.split(separator: "\n")
        .filter { $0.contains("\"segment.created\"") }.count
    #expect(createdCount == 1)
}

/// Measures duplicate pending registration without inference or recognized-row updates.
/// Five-second event cadence; uses pending references, not hours of allocated audio.
@Test("Measure live registration cost at 10-minute, 1-hour and 4-hour event equivalents")
func bugHuntMeasureLiveRegistrationCost() async throws {
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
        print("BUG_HUNT registration equivalent_seconds=\(count * 5) pending=\(count) median_us=\(median)")
        previous = count
    }
}
