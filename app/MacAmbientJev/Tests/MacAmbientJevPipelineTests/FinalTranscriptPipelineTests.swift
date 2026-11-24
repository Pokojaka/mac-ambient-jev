import Dispatch
import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private actor FinalizationCallLog {
    private var values: [String] = []

    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private final class SynchronousCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    func recordCall() {
        lock.lock()
        callCount += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}

private actor FinalizationStatusRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor FinalizationStateRecorder {
    struct Entry: Sendable {
        let texts: [String]
        let state: ProcessingState
    }

    private var values: [Entry] = []

    func append(_ value: ([String], ProcessingState)) {
        values.append(Entry(texts: value.0, state: value.1))
    }

    func snapshot() -> [Entry] { values }
}

private struct FakeFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    let segments: [SegmentReference]
    let log: FinalizationCallLog

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        await log.append("vad")
        return segments.map {
            SegmentReference(
                segmentationRunID: runID,
                segmentID: $0.segmentID,
                speechRanges: $0.speechRanges
            )
        }
    }
}

private actor FakeFinalASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private let log: FinalizationCallLog
    private let values: [String]
    private let failOnCall: Int?
    private var callIndex = 0
    private var audioFrameCounts: [Int] = []

    init(log: FinalizationCallLog, values: [String], failOnCall: Int? = nil) {
        self.log = log
        self.values = values
        self.failOnCall = failOnCall
    }

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let index = callIndex
        callIndex += 1
        audioFrameCounts.append(input.samples.count)
        await log.append("asr:\(index)")
        guard index != failOnCall else { throw FakeFinalizationError.expected }
        return ASRResult(text: values[index], detectedLanguage: "ja")
    }

    func unload() async {}

    func recordedAudioFrameCounts() -> [Int] { audioFrameCounts }
}

private actor CancellationGate {
    private var started = false
    private var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, any Error>] = []

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func suspendUntilCancelled() async throws {
        markStarted()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !cancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                cancellationWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancel() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}

private actor CancellationGatedFinalASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private let gate: CancellationGate

    init(gate: CancellationGate) {
        self.gate = gate
    }

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        try await gate.suspendUntilCancelled()
        return ASRResult(text: "取消されなかった認識", detectedLanguage: "ja")
    }

    func unload() async {}
}

private struct CancellationGatedFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    let gate: CancellationGate

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        try await gate.suspendUntilCancelled()
        return [SegmentReference(segmentationRunID: runID, segmentID: "vad", speechRanges: [0..<16_000])]
    }
}

private struct CancellationGatedCompactionAudioHandling: SessionProcessingAudioHandling {
    let gate: CancellationGate

    func open(
        _ source: SessionAudioSource,
        layout: SessionLayout,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> any TimelineAudioReading {
        try SessionAudioReaders.open(source, layout: layout)
    }

    func compactRecording(layout: SessionLayout) async throws {
        try await gate.suspendUntilCancelled()
    }
}

private enum FakeFinalizationError: Error {
    case expected
}

private actor PreparationFailingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var prepareCallCount = 0

    func prepare() async throws {
        prepareCallCount += 1
        throw FakeFinalizationError.expected
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw FakeFinalizationError.expected
    }

    func unload() async {}
}

private func finalizationFixture(
    frames: Int = 16_000,
    samples: [Float]? = nil,
    sessionID: UUID = UUID()
) async throws -> (AppPaths, URL, AudioCheckpoint) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: processingDirectory,
        chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await writer.append(samples: samples ?? Array(repeating: 0.1, count: frames))
    return (paths, sessionURL, await writer.committedSnapshot())
}

private func processFinal(
    _ processor: NativeSessionProcessor,
    sessionID: UUID,
    sessionURL: URL,
    metadataPolicy: UnreadableMetadataPolicy,
    statuses: FinalizationStatusRecorder,
    states: FinalizationStateRecorder,
    phases: FinalizationCallLog
) async throws -> SessionProcessingResult {
    return await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { _ in nil },
        onPhase: { await phases.append("phase:\($0.rawValue)") },
        metadataPolicy: metadataPolicy,
        onStatus: { await statuses.append($0.text) },
        onUpdate: { segments, state in await states.append((segments.map(\.text), state)) }
    )
}

private func cancelProcessingWhenGateStarts(
    _ processor: NativeSessionProcessor,
    sessionID: UUID,
    gate: CancellationGate,
    pacingMode: ASRPacingMode = .normal
) async -> SessionProcessingResult {
    let task = Task {
        await processor.processSession(
            sessionID: sessionID,
            pacingMode: pacingMode,
            shouldPause: { _ in nil },
            onPhase: { _ in },
            metadataPolicy: .reject,
            onStatus: { _ in },
            onUpdate: { _, _ in }
        )
    }
    await gate.waitUntilStarted()
    task.cancel()
    return await task.value
}

private func resumableDecisionPriority() -> ContentPriorityAccess {
    let counter = DecisionUsageCounter()
    let provider = FrozenReuseProvider(fillerRangesByText: ["再開した本文": [], "前半": []])
    return .localTagger({
        DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    }, usageCounter: counter)
}

private func recoveryProcessor(
    paths: AppPaths,
    log: FinalizationCallLog,
    audioHandling: any SessionProcessingAudioHandling = RecordingTestAudioHandling()
) -> NativeSessionProcessor {
    return NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["再開した本文"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: audioHandling,
        contentPriority: resumableDecisionPriority(),
        sleep: { _ in }
    )
}

private func eventObjects(_ sessionURL: URL) throws -> [[String: Any]] {
    try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
        .lines.compactMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

@Test(arguments: [InferenceHoldReason.thermal, .resourcePressure, .monitorFailed])
func nativeProcessorPauseReasonForSessionProcessingCoordinator(reason: InferenceHoldReason) async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(frames: 16_000, sessionID: sessionID)
    let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
    let fixtureRoot = paths.applicationSupportURL.deletingLastPathComponent().standardizedFileURL
    let cleanupRoot = try #require(
        fixtureRoot.deletingLastPathComponent().standardizedFileURL == temporaryDirectory
            && UUID(uuidString: fixtureRoot.lastPathComponent) != nil
            ? fixtureRoot
            : nil
    )
    defer { try? FileManager.default.removeItem(at: cleanupRoot) }

    let log = FinalizationCallLog()
    let typedStatusLog = FinalizationCallLog()
    let statuses = FinalizationStatusRecorder()
    let processor = recoveryProcessor(paths: paths, log: log)

    let result = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { _ in reason },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { status in
            await statuses.append(status.text)
            if status == .paused(reason) {
                await typedStatusLog.append("selected-pause-reason")
            }
        },
        onUpdate: { _, _ in }
    )

    #expect(result.disposition == .paused)
    let message = try #require(result.message)
    #expect(message.contains(reason.finalizationExplanation))
    let statusTexts = await statuses.snapshot()
    #expect(statusTexts.contains { $0.contains(reason.finalizationExplanation) })
    for otherReason in [InferenceHoldReason.thermal, .resourcePressure, .monitorFailed]
    where otherReason != reason {
        #expect(!message.contains(otherReason.finalizationExplanation))
        #expect(statusTexts.allSatisfy { !$0.contains(otherReason.finalizationExplanation) })
    }
    #expect(await typedStatusLog.snapshot() == ["selected-pause-reason"])
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .paused)
    #expect(!(await log.snapshot()).contains { $0.hasPrefix("asr:") })
    #expect(InferenceHoldReason.thermal.finalizationExplanation == UserFacingStatus.finalizationPausedForHeat.text)
}

@Test(.timeLimit(.minutes(10)))
func nativeProcessorCancellationDuringASRPausesDurablyAndRecoversOnRelaunch() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let gate = CancellationGate()
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: CancellationGatedFinalASR(gate: gate),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: resumableDecisionPriority(),
        sleep: { _ in }
    )

    let cancelled = await cancelProcessingWhenGateStarts(processor, sessionID: sessionID, gate: gate)

    #expect(cancelled.disposition == .paused)
    #expect(cancelled.message == "確定処理が中断されたため、一時停止しました")
    #expect(cancelled.metrics?.initialPendingCount == 1)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .paused)
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery?.action == .finalize)

    let relaunch = recoveryProcessor(paths: paths, log: log)
    let resumed = try await processFinal(
        relaunch, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(resumed.disposition == .completed)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .complete)
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["再開した本文"])
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery == nil)
}

@Test(.timeLimit(.minutes(10)))
func nativeProcessorCancellationDuringVADPausesDurablyAndRecoversOnRelaunch() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let gate = CancellationGate()
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["認識されない"]),
            finalTranscriptVAD: CancellationGatedFinalVAD(gate: gate)
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: resumableDecisionPriority(),
        sleep: { _ in }
    )

    let cancelled = await cancelProcessingWhenGateStarts(processor, sessionID: sessionID, gate: gate)

    #expect(cancelled.disposition == .paused)
    #expect(cancelled.message == "確定処理が中断されたため、一時停止しました")
    #expect(cancelled.metrics == nil)
    #expect(await log.snapshot().isEmpty)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .paused)
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery?.action == .finalize)

    let relaunch = recoveryProcessor(paths: paths, log: log)
    let resumed = try await processFinal(
        relaunch, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(resumed.disposition == .completed)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .complete)
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["再開した本文"])
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery == nil)
}

@Test(.timeLimit(.minutes(10)))
func nativeProcessorCancellationDuringPacingPausesDurablyAndRecoversOnRelaunch() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let gate = CancellationGate()
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["前半", "後半"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "first", speechRanges: [0..<8_000]),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "second", speechRanges: [8_000..<16_000])
                ],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: resumableDecisionPriority(),
        sleep: { _ in try await gate.suspendUntilCancelled() }
    )

    let cancelled = await cancelProcessingWhenGateStarts(
        processor, sessionID: sessionID, gate: gate, pacingMode: .lowHeat
    )

    #expect(cancelled.disposition == .paused)
    #expect(cancelled.message == "確定処理が中断されたため、一時停止しました")
    #expect(cancelled.metrics?.initialPendingCount == 2)
    #expect(cancelled.metrics?.pacingWaitCount == 1)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .paused)
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery?.action == .finalize)

    let relaunch = recoveryProcessor(paths: paths, log: log)
    let resumed = try await processFinal(
        relaunch, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(resumed.disposition == .completed)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .complete)
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["前半", "再開した本文"])
    #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery == nil)
}

@Test(.timeLimit(.minutes(10)))
func nativeProcessorCancellationDuringCompactionKeepsTheCompleteTranscriptForMaintenance() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let gate = CancellationGate()
    let log = FinalizationCallLog()
    let processor = recoveryProcessor(
        paths: paths,
        log: log,
        audioHandling: CancellationGatedCompactionAudioHandling(gate: gate)
    )

    let cancelled = await cancelProcessingWhenGateStarts(processor, sessionID: sessionID, gate: gate)

    #expect(cancelled.disposition == .paused)
    #expect(cancelled.message == "文字起こしは完了しましたが、音声の保存整理が中断されました")
    #expect(cancelled.retainedTranscript == .finalized)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(metadata.state == .complete)
    #expect(try storedFinal(sessionURL: sessionURL).state.recognitionCompleted)
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["再開した本文"])
    let inspection = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID)
    #expect(inspection.recovery == nil)
    #expect(inspection.maintenance == .compactRecording)
}

@Test
func finalTranscriptPipelinePreservesVADContextForASR() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let asr = FakeFinalASR(log: log, values: ["文脈を保った発話", "予期しない再認識"])
    let vad = FakeFinalVAD(
        segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<4_000, 8_000..<16_000])],
        log: log
    )
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: vad
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed, Comment(rawValue: result.message ?? "no failure message"))
    #expect(await statuses.snapshot().last?.contains("完了しました") == true)
    #expect(await log.snapshot() == ["vad", "asr:0"])
    let loadedMetadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
    let metadata = try #require(loadedMetadata)
    #expect(metadata.state == .complete)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let rows = try readFinalRows(sessionURL: sessionURL)
    #expect(rows.map(\.text) == ["文脈を保った発話"])
    #expect(rows.map(\.startMilliseconds) == [0])
    #expect(rows.map(\.endMilliseconds) == [1_000])
    #expect(await asr.recordedAudioFrameCounts() == [12_000])
    #expect(rows.map(\.segmentID) == ["vad"])

    let rawEvents = try recovered.lines.compactMap { line -> [String: Any]? in
        try JSONSerialization.jsonObject(with: line) as? [String: Any]
    }
    let created = rawEvents.filter { $0["event_type"] as? String == "segment.created" }
    let segmentationCompletionIndex = try #require(rawEvents.firstIndex {
        $0["event_type"] as? String == "processing.run.completed"
            && ($0["payload"] as? [String: Any])?["stage"] as? String == ProcessingStage.segmentation.rawValue
    })
    #expect(created.count == 1)
    let createdEvent = try #require(created.first)
    let createdPayload = try #require(createdEvent["payload"] as? [String: Any])
    let decodedPayload = try JSONDecoder().decode(
        SegmentCreatedPayload.self,
        from: JSONSerialization.data(withJSONObject: createdPayload)
    )
    #expect(decodedPayload.speechRanges == [0..<4_000, 8_000..<16_000])
    #expect(createdPayload["speech_ranges"] as? [[Int]] == [[0, 4_000], [8_000, 16_000]])
    #expect(created.allSatisfy { ( $0["event_seq"] as? Int ?? Int.max) < (rawEvents[segmentationCompletionIndex]["event_seq"] as? Int ?? -1) })
    let completionPayload = rawEvents[segmentationCompletionIndex]["payload"] as? [String: Any]
    #expect(completionPayload?["completed_count"] as? Int == created.count)
    #expect(Set(created.compactMap { $0["segment_id"] as? String }) == Set(rows.map(\.segmentID)))
}

private struct UnavailableTagger: LocalizedError {
    var errorDescription: String? { "モデルがありません" }
}

@Test
func decisionsSkipWhitespaceOnlyFinalTranscript() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let decisionFactoryCalls = SynchronousCallRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: [" \n\t"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_empty", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .localTagger({
            decisionFactoryCalls.recordCall()
            throw UnavailableTagger()
        }, usageCounter: DecisionUsageCounter()),
        sleep: { _ in }
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(decisionFactoryCalls.count() == 0)
}

@Test
func failedASRMarksTheGenerationFailedAndKeepsTheRecognizedRows() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, _) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["最初の確定", "失敗"], failOnCall: 1),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_1", speechRanges: [0..<8_000]),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "vad_2", speechRanges: [8_000..<16_000])
                ],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()
    let states = FinalizationStateRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: states, phases: FinalizationCallLog()
    )

    #expect(result.disposition == .failed)
    #expect(result.metrics?.initialPendingCount == 2)
    #expect(result.retainedTranscript == .finalized)
    #expect(await statuses.snapshot().last?.contains("確定処理に失敗") == true)
    let last = try #require(await states.snapshot().last)
    #expect(last.texts == ["最初の確定"])
    guard case .partialFailure = last.state else {
        Issue.record("a failed finalization reports a partial failure")
        return
    }
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .failed)
    #expect(try readFinalRows(sessionURL: sessionURL).map(\.text) == ["最初の確定"])
}

@Test
func stoppingALiveRecordingEndsWithFinalizationStatus() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["確定文"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    _ = try await processor.startLiveTranscription(sessionID: sessionID, sampleRate: checkpoint.sampleRate)
    let statuses = FinalizationStatusRecorder()

    let finish = await processor.processSession(
        sessionID: sessionID,
        pacingMode: .normal,
        shouldPause: { _ in nil },
        onPhase: { _ in },
        metadataPolicy: .reject,
        onStatus: { await statuses.append($0.text) },
        onUpdate: { _, _ in }
    )

    #expect(finish.disposition == .completed)
    #expect(await statuses.snapshot().last?.contains("完了しました") == true)
}

@Test
func noSpeechFinalizationSkipsASRPreparationAndCompletesZeroCountRun() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let asr = PreparationFailingASR()
    let log = FinalizationCallLog()
    let decisionFactoryCalls = SynchronousCallRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .localTagger({
            decisionFactoryCalls.recordCall()
            throw UnavailableTagger()
        }, usageCounter: DecisionUsageCounter()),
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(result.noSpeech)
    #expect(await asr.prepareCallCount == 0)
    #expect(decisionFactoryCalls.count() == 0)
    #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
    #expect(try storedFinal(sessionURL: sessionURL).pendingDecisions.pendingTargets.isEmpty)
    let recovered = try SessionRecovery.recoverJSONL(Data(contentsOf: sessionURL.appending(path: "events.jsonl")))
    let completions = try recovered.lines.compactMap { line -> (String, Bool, Int, Int)? in
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event_type"] as? String == "processing.run.completed",
              let runID = object["processing_run_id"] as? String,
              let payload = object["payload"] as? [String: Any],
              payload["stage"] as? String == ProcessingStage.asr.rawValue,
              let succeeded = payload["succeeded"] as? Bool,
              let completedCount = payload["completed_count"] as? Int,
              let failedCount = payload["failed_count"] as? Int else {
            return nil
        }
        return (runID, succeeded, completedCount, failedCount)
    }
    #expect(completions.count == 1)
    #expect(completions.first?.1 == true)
    #expect(completions.first?.2 == 0)
    #expect(completions.first?.3 == 0)
}

@Test
func deferredDecisionsKeepFinalizationRunningUntilLocalTranscriptIsVisible() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["表示する本文"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000001", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .localTagger({ throw UnavailableTagger() }, usageCounter: DecisionUsageCounter()),
        sleep: { _ in }
    )
    let states = FinalizationStateRecorder()
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: states, phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    let observedStates = await states.snapshot()
    #expect(observedStates.contains { $0.texts == ["表示する本文"] && $0.state == .running })
    #expect(observedStates.last?.state == .complete)
    #expect(await statuses.snapshot().last
        == "\(UserFacingStatus.decisionDeferred.text)。判定エンジンを初期化できませんでした: モデルがありません")
    // The local transcript is complete with every segment boundary-pending.
    #expect(try storedFinal(sessionURL: sessionURL).pendingDecisions.boundarySegments.map(\.segmentID) == ["seg_000001"])
    let rows = try readFinalRows(sessionURL: sessionURL)
    #expect(rows.map(\.clauseState) == [.boundaryPending])
    #expect(rows.map(\.displayText) == ["表示する本文"])
}

private struct FailingDecisionProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw DecisionResponseError.missingAnswer
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        throw DecisionResponseError.missingAnswer
    }
}

@Test
func failedModelRequestsDeferFinalizationAndRetryDecisions() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let counter = DecisionUsageCounter()
    let decisionFactoryCalls = SynchronousCallRecorder()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["一つ目", "二つ目"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [
                    SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000001", speechRanges: [0..<8_000]),
                    SegmentReference(segmentationRunID: "ignored", segmentID: "seg_000002", speechRanges: [8_000..<16_000])
                ],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .localTagger({
            // Every decision request asks the factory for a coordinator; requests fail until the retry starts.
            let provider: any DecisionProvider
            if decisionFactoryCalls.count() == 0 {
                provider = FailingDecisionProvider()
            } else {
                provider = FrozenReuseProvider(fillerRangesByText: [:])
            }
            return DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
        }, usageCounter: counter),
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )

    #expect(result.disposition == .completed)
    #expect(await statuses.snapshot().last == UserFacingStatus.decisionDeferred.text)
    let pending = try storedFinal(sessionURL: sessionURL).pendingDecisions.boundarySegments
    // Terminal segments still require boundary inference; failed requests leave both sources pending.
    #expect(pending.map(\.segmentID) == ["seg_000001", "seg_000002"])

    decisionFactoryCalls.recordCall()
    let retryStatuses = FinalizationStatusRecorder()
    let retryResult = await processor.retryContentPrioritySession(
        sessionID: sessionID,
        boundarySegments: pending,
        clauses: [],
        onStatus: { await retryStatuses.append($0.text) },
        onUpdate: { _, _ in }
    )
    #expect(retryResult.disposition == .completed)
    #expect(retryResult.message == nil)
    #expect(await retryStatuses.snapshot().last == "保留中の判定を更新しました")
    #expect(try storedFinal(sessionURL: sessionURL).pendingDecisions.pendingTargets.isEmpty)
}

@Test
func finalTranscriptPipelineEmitsASRPhaseBeforeTranscription() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["えー、本文"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )

    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: log
    )

    #expect(result.disposition == .completed)
    let rows = try readFinalRows(sessionURL: sessionURL)
    #expect(rows.map(\.textProjection.text) == ["えー、本文"])
    #expect(rows.map(\.displayText) == ["えー、本文"])
    #expect(await log.snapshot() == [
        "phase:preparing", "vad", "phase:asr", "asr:0",
        "phase:postprocessing", "phase:complete"
    ])
}

@Test
func everyRunRecordsItsProvenanceOnceAndRepeatedProcessingReusesTheGeneration() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["一回目", "二回目"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    var startedRunsByAttempt: [[String: String]] = []
    for _ in 0..<2 {
        let result = try await processFinal(
            processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
            statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
        )
        #expect(result.disposition == .completed)
        let runs = try storedFinal(sessionURL: sessionURL).state.runs
        let started = try eventObjects(sessionURL).filter { $0["event_type"] as? String == "processing.run.started" }
        var engines: [String: String] = [:]
        for (stage, runID) in [
            ("segmentation", runs.segmentation), ("asr", runs.asr),
        ] {
            let ofRun = started.filter { $0["processing_run_id"] as? String == runID }
            #expect(ofRun.count == 1)
            let payload = ofRun.first?["payload"] as? [String: Any]
            #expect(payload?["stage"] as? String == stage)
            let provenance = payload?["provenance"] as? [String: Any]
            engines[stage] = provenance?["engine"] as? String
            #expect(provenance?["version"] as? String != nil)
        }
        #expect(engines == [
            "segmentation": "fake-vad",
            "asr": "fake-asr",
        ])
        startedRunsByAttempt.append(Dictionary(uniqueKeysWithValues: started.compactMap { object in
            (object["processing_run_id"] as? String).map { ($0, $0) }
        }))
    }
    #expect(startedRunsByAttempt[1] == startedRunsByAttempt[0])
    #expect(await log.snapshot() == ["vad", "asr:0"])
}

@Test
func unreadableMetadataIsReplacedOnlyByExplicitReprocessing() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let metadataURL = sessionURL.appending(path: "processing_metadata.json")
    let broken = Data("{broken".utf8)
    try broken.write(to: metadataURL)
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: ["再処理"]),
            finalTranscriptVAD: FakeFinalVAD(
                segments: [SegmentReference(segmentationRunID: "ignored", segmentID: "vad", speechRanges: [0..<16_000])],
                log: log
            )
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )

    let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
    #expect(scan.candidates.isEmpty)
    #expect(scan.failures.map(\.sessionURL) == [sessionURL])

    let rejected = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(rejected.disposition == .failed)
    #expect(try Data(contentsOf: metadataURL) == broken)
    #expect(await log.snapshot().isEmpty)

    let replaced = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .replace,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(replaced.disposition == .completed)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .complete)
}

/// Accepts every candidate, never continues, and answers LOW for every clause.
private actor FrozenReuseProvider: DecisionProvider {
    private let fillerRangesByText: [String: [TextUTF16Range]]
    private var boundaryTexts: [String] = []
    private var priorityTexts: [String] = []

    init(fillerRangesByText: [String: [TextUTF16Range]]) {
        self.fillerRangesByText = fillerRangesByText
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryTexts.append(request.text)
        let fillerRanges: [TextUTF16Range]
        if fillerRangesByText.isEmpty {
            fillerRanges = []
        } else if let exactRanges = fillerRangesByText[request.text] {
            fillerRanges = exactRanges
        } else {
            throw DecisionResponseError.missingAnswer
        }
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next.map { _ in 0.1 },
            fillerRanges: fillerRanges,
            inputTokens: 3
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityTexts.append(contentsOf: targets.map(\.text))
        let decision = try ContentPriorityDecision(
            priority: .lowPriority, confidence: 0.95,
            probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: 3
        )
    }

    func assessedBoundaryTexts() -> [String] { boundaryTexts }
    func sentPriorityTexts() -> [String] { priorityTexts }
}

private func storedFinal(sessionURL: URL) throws -> StoredTranscriptEvents {
    let layout = SessionLayout(sessionURL: sessionURL)
    return try #require(try EventLogTranscriptReader().read(
        eventsURL: layout.eventsURL, sessionID: try layout.loadManifest().sessionID
    ))
}

private func readFinalRows(sessionURL: URL) throws -> [MaterializedTranscriptSegment] {
    let stored = try storedFinal(sessionURL: sessionURL)
    return try TranscriptMaterializer(sampleRate: 16_000).materialize(
        events: stored.events, activeRuns: stored.state.runs
    )
}

@Test("Validated empty VAD completes without speech inference")
func validatedEmptyVADCompletesWithoutSpeechInference() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(
        samples: Array(repeating: 0, count: 16_000), sessionID: sessionID
    )
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let asr = PreparationFailingASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()
    var previousRuns: ActiveRuns?
    var storedFLAC: Data?
    for _ in 1...2 {
        let result = try await processFinal(
            processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
            statuses: statuses, states: FinalizationStateRecorder(),
            phases: FinalizationCallLog()
        )
        #expect(result.disposition == .completed)
        #expect(result.noSpeech)
        #expect(result.metrics == nil)
        #expect(await statuses.snapshot().last == "発話区間は検出されませんでした")
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        #expect(metadata.state == .complete)
        let stored = try storedFinal(sessionURL: sessionURL)
        #expect(stored.pendingDecisions.pendingTargets.isEmpty)
        let runs = stored.state.runs
        #expect(previousRuns == nil || runs == previousRuns)
        previousRuns = runs
        #expect(try readFinalRows(sessionURL: sessionURL).isEmpty)
        #expect(try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).inspect(sessionID: sessionID).recovery == nil)
        let objects = try eventObjects(sessionURL)
        let stageRuns: [(ProcessingStage, String?, RunProvenance)] = [
            (.segmentation, runs.segmentation, FakeFinalVAD(segments: [], log: log).provenance),
            (.asr, runs.asr, asr.provenance)
        ]
        for (stage, run, expectedProvenance) in stageRuns {
            let runID = try #require(run)
            let starts = objects.filter {
                $0["event_type"] as? String == "processing.run.started"
                    && $0["processing_run_id"] as? String == runID
            }
            #expect(starts.count == 1)
            let startedPayload = try #require(starts.first?["payload"] as? [String: Any])
            #expect(startedPayload["stage"] as? String == stage.rawValue)
            let provenance = try #require(startedPayload["provenance"] as? [String: Any])
            #expect(try JSONDecoder().decode(RunProvenance.self, from: JSONSerialization.data(
                withJSONObject: provenance
            )) == expectedProvenance)
            let completions = objects.filter {
                $0["event_type"] as? String == "processing.run.completed"
                    && $0["processing_run_id"] as? String == runID
            }
            #expect(completions.count == 1)
            let payload = try #require(completions.first?["payload"] as? [String: Any])
            #expect(payload["stage"] as? String == stage.rawValue)
            #expect(payload["succeeded"] as? Bool == true)
            #expect(payload["completed_count"] as? Int == 0)
            #expect(payload["failed_count"] as? Int == 0)
        }
        #expect(objects.allSatisfy {
            ["pipeline.started", "processing.run.started", "processing.run.completed",
             "segmentation.input.sealed", "segmentation.completed"].contains($0["event_type"] as? String)
        })
        #expect(await log.snapshot() == ["vad"])
        #expect(await asr.prepareCallCount == 0)
        let flac = try Data(contentsOf: SessionLayout(sessionURL: sessionURL).recordingFLACURL)
        #expect(storedFLAC == nil || flac == storedFLAC)
        storedFLAC = flac
    }
}

private struct ThrowingFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "failing-vad", model: nil, version: "test", configuration: [:])

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        throw FakeFinalizationError.expected
    }
}

@Test
func failedVADDoesNotCompleteSegmentationOrReportNoSpeech() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(
        samples: Array(repeating: 0, count: 16_000), sessionID: sessionID
    )
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: PreparationFailingASR(),
            finalTranscriptVAD: ThrowingFinalVAD()
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let statuses = FinalizationStatusRecorder()
    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: statuses, states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(result.disposition == .failed)
    #expect(!result.noSpeech)
    #expect(result.metrics == nil)
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
    #expect(metadata.state == .failed)
    let state = try #require(try ProcessingLogState(
        eventsURL: SessionLayout(sessionURL: sessionURL).eventsURL, sessionID: sessionID
    ))
    #expect(state.generation.id == metadata.generationID)
    #expect(!state.segmentationCompleted)
    #expect(state.runCompletions.isEmpty)
    #expect(await statuses.snapshot().last?.contains("確定処理に失敗") == true)
}

@Test func processorLookupFailuresDoNotPublishEmptyTranscriptsOrRunEngines() async throws {
    let sessionID = UUID()
    let (paths, sessionURL, checkpoint) = try await finalizationFixture(sessionID: sessionID)
    defer { try? FileManager.default.removeItem(at: paths.applicationSupportURL.deletingLastPathComponent()) }
    let log = FinalizationCallLog()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: FakeFinalASR(log: log, values: []),
            finalTranscriptVAD: FakeFinalVAD(segments: [], log: log)
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let absent = UUID()
    do {
        _ = try await processor.startLiveTranscription(sessionID: absent, sampleRate: 16_000)
        Issue.record("missing identity must fail")
    } catch {
        #expect(error as? SessionDirectoryLookupError == .notFound(absent))
    }
    let duplicate = paths.sessionsRoot.appending(path: "malformed")
    try FileManager.default.copyItem(at: sessionURL, to: duplicate)
    let originalLog = try Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL)
    let result = try await processFinal(
        processor, sessionID: sessionID, sessionURL: sessionURL, metadataPolicy: .reject,
        statuses: FinalizationStatusRecorder(), states: FinalizationStateRecorder(), phases: FinalizationCallLog()
    )
    #expect(result.disposition == .failed)
    #expect(!result.noSpeech)
    #expect(result.metrics == nil)
    let imported = await processor.processSession(
        sessionID: absent,
        pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(imported.disposition == .failed)
    #expect(!imported.noSpeech)
    #expect(await log.snapshot().isEmpty)
    #expect(try Data(contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL) == originalLog)
    #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load() == nil)
}
