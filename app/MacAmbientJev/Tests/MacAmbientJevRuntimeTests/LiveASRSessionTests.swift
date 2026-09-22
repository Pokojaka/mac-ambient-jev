import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor CountingASREngine: ASREngine {
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
        return ASRResult(text: "segment-\(transcribeCalls)")
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCalls, transcribeCalls)
    }
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
func liveASRFailureKeepsRunUnsuccessfulForFallback() async throws {
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

    let completion = try await fixture.session.finish()
    #expect(!completion.succeeded)
    #expect(completion.completedCount == 1)
    #expect(completion.failedCount == 1)
}


@Test
func liveASRRegistrationIsRecoverableBeforeInferenceStarts() async throws {
    let fixture = try await makeLiveASRFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let segment = SegmentReference(
        segmentationRunID: "seg_live_test",
        segmentID: "seg_000001",
        startFrame: 0,
        endFrame: 4_000
    )

    let registered = try await fixture.session.register(
        segments: [segment]
    )
    #expect(registered.completedCount == 0)
    #expect(registered.failedCount == 0)
    #expect(registered.pendingCount == 1)

    let countsBeforeInference = await fixture.engine.counts()
    #expect(countsBeforeInference.prepare == 0)
    #expect(countsBeforeInference.transcribe == 0)

    let recovered = try SessionRecovery.recoverJSONL(
        Data(
            contentsOf: fixture.root.appending(path: "events.jsonl")
        )
    )
    let plan = try EventLogRecoveryAnalyzer().latestASRPlan(
        lines: recovered.lines
    )

    #expect(plan?.segmentationRunID == "seg_live_test")
    #expect(plan?.asrRunID == "asr_live_test")
    #expect(plan?.pendingSegments == [segment])
    #expect(plan?.hasFailures == false)
    #expect(plan?.runSucceeded == false)
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
