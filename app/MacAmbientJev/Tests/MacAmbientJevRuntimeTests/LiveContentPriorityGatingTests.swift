import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor RowRecorder {
    private(set) var updates: [[MaterializedTranscriptSegment]] = []
    private(set) var statuses: [String] = []

    func record(_ rows: [MaterializedTranscriptSegment]) { updates.append(rows) }
    func record(status: String) { statuses.append(status) }
    var latest: [MaterializedTranscriptSegment] { updates.last ?? [] }
    var updateCount: Int { updates.count }

    func waitForRows(_ count: Int) async throws {
        for _ in 0..<500 {
            if latest.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("rows never reached \(count)")
    }
}

private actor SequencedASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var count = 0
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        count += 1
        return ASRResult(text: "発話\(count)", detectedLanguage: "ja")
    }
    func unload() async {}
}

private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    func pass() async {
        arrivals += 1
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
    func waitForArrival() async throws {
        for _ in 0..<500 {
            if arrivals > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("provider was never called")
    }
}

private struct ScriptedProvider: DecisionProvider {
    let latch: Latch?
    let failure: JevClientError?
    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        await latch?.pass()
        if let failure { throw failure }
        return ContentPriorityDecision(
            priority: text == "発話1" ? .lowPriority : .primary,
            confidence: 0.95, model: "scripted", inputTokens: 1
        )
    }
}

private struct LiveFixture {
    let sessionID = UUID()
    let sessionURL: URL
    let processor: NativeSessionProcessor
    let checkpoint: AudioCheckpoint
    let root: URL
    let segments: [SegmentReference]

    init(contentPriority: ContentPriorityAccess) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let paths = AppPaths(
            applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
            cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: nil
        )
        sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone), createdAt: Date()
        )
        let audioWriter = try DurableAudioWriter(
            directory: sessionURL
                .appending(path: "audio", directoryHint: .isDirectory)
                .appending(path: "processing", directoryHint: .isDirectory),
            sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
        )
        try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
        checkpoint = await audioWriter.committedSnapshot()
        processor = NativeSessionProcessor(
            paths: paths,
            engines: SessionProcessingEngines(
                asr: SequencedASR(),
                diarization: FluidOfflineDiarizationEngine(paths: paths),
                finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
            ),
            contentPriority: contentPriority
        )
        segments = [
            SegmentReference(segmentationRunID: "live_seg", segmentID: "seg_1", startFrame: 0, endFrame: 4_000),
            SegmentReference(segmentationRunID: "live_seg", segmentID: "seg_2", startFrame: 4_000, endFrame: 8_000),
        ]
        _ = try await processor.startLiveTranscription(
            sessionID: sessionID, segmentationRunID: "live_seg", sampleRate: checkpoint.sampleRate
        )
        _ = try await processor.registerLiveSegments(sessionID: sessionID, segments: segments)
    }

    func run(_ recorder: RowRecorder) async throws {
        _ = try await processor.processLiveSegments(
            sessionID: sessionID, segments: segments, checkpoint: checkpoint,
            onStatus: { await recorder.record(status: $0) },
            onUpdate: { rows, _ in await recorder.record(rows) }
        )
    }

    func eventTypes() throws -> [String] {
        let data = try Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["event_type"] as? String
        }
    }
}

@Test
func liveRowsStayHiddenUntilJevDecidesThenAppearAlreadyClassifiedInTimeOrder() async throws {
    let latch = Latch()
    let provider = ScriptedProvider(latch: latch, failure: nil)
    let decisions = JevDecisionCoordinator(provider: provider, usageCounter: JevUsageCounter())
    let fixture = try await LiveFixture(contentPriority: .jev({ decisions }))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = RowRecorder()

    try await fixture.run(recorder)
    try await latch.waitForArrival()
    #expect(await recorder.latest.isEmpty)

    await latch.release()
    try await recorder.waitForRows(2)
    let updates = await recorder.updates
    for rows in updates {
        #expect(rows.allSatisfy { $0.contentPriority != nil })
        #expect(rows.map(\.segmentID) == Array(["seg_1", "seg_2"].prefix(rows.count)))
    }
    let final = await recorder.latest
    #expect(final.map(\.contentPriority) == [.lowPriority, .primary])
    #expect(try fixture.eventTypes().contains("content_priority.assigned"))
}

@Test(arguments: [false, true])
func liveRowsAppearImmediatelyWhenJevIsOffOrFails(jevOff: Bool) async throws {
    let access: ContentPriorityAccess = jevOff
        ? .jev({ nil })
        : .jev({ JevDecisionCoordinator(
            provider: ScriptedProvider(latch: nil, failure: .httpStatus(503)),
            usageCounter: JevUsageCounter()
        ) })
    let fixture = try await LiveFixture(contentPriority: access)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = RowRecorder()

    try await fixture.run(recorder)
    try await recorder.waitForRows(2)
    #expect(await recorder.latest.map(\.text) == ["発話1", "発話2"])
    if jevOff {
        #expect(await recorder.latest.map(\.contentPriority) == [nil, nil])
    }
}

@Test
func liveAuthorizationFailureShowsStatusAndRowsAppearNormally() async throws {
    let access: ContentPriorityAccess = .jev({ JevDecisionCoordinator(
        provider: ScriptedProvider(latch: nil, failure: .httpStatus(401)),
        usageCounter: JevUsageCounter()
    ) })
    let fixture = try await LiveFixture(contentPriority: access)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = RowRecorder()

    try await fixture.run(recorder)
    try await recorder.waitForRows(2)
    for _ in 0..<500 where !(await recorder.statuses.contains(UserFacingStatus.jevAuthorizationRequired.text)) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.statuses.contains(UserFacingStatus.jevAuthorizationRequired.text))
    #expect(await recorder.latest.map(\.text) == ["発話1", "発話2"])
}

@Test
func stoppingRecordingCancelsInFlightLiveJevAndNeverPublishesItsResult() async throws {
    let latch = Latch()
    let decisions = JevDecisionCoordinator(
        provider: ScriptedProvider(latch: latch, failure: nil), usageCounter: JevUsageCounter()
    )
    let fixture = try await LiveFixture(contentPriority: .jev({ decisions }))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let recorder = RowRecorder()

    try await fixture.run(recorder)
    try await latch.waitForArrival()
    await fixture.processor.stopLiveContentPriority(sessionID: fixture.sessionID)
    let countAtStop = await recorder.updateCount
    await latch.release()
    try await Task.sleep(for: .milliseconds(200))

    #expect(await recorder.updateCount == countAtStop)
    #expect(await recorder.latest.isEmpty)
    #expect(!(try fixture.eventTypes().contains("content_priority.assigned")))
}
