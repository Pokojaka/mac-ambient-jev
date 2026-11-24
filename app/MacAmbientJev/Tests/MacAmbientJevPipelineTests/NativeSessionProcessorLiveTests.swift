import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private enum UnexpectedLiveTestFinalization: Error {
    case called
}

private struct UnusedLiveTestVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "unused-live-test-vad", model: nil, version: "test", configuration: [:])

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        throw UnexpectedLiveTestFinalization.called
    }
}

private actor LiveUpdateRecorder {
    private struct RowsWaiter {
        let condition: @Sendable ([MaterializedTranscriptSegment]) -> Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var segments: [MaterializedTranscriptSegment] = []
    private(set) var history: [[MaterializedTranscriptSegment]] = []
    private var waiters: [UUID: RowsWaiter] = [:]

    func record(_ value: [MaterializedTranscriptSegment]) {
        segments = value
        history.append(value)
        resolveWaiters()
    }

    func snapshot() -> [MaterializedTranscriptSegment] {
        segments
    }

    func waitFor(_ condition: @escaping @Sendable ([MaterializedTranscriptSegment]) -> Bool) async throws {
        if condition(segments) { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !condition(segments) else {
                    continuation.resume(returning: ())
                    return
                }
                waiters[id] = RowsWaiter(condition: condition, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resolveWaiters() {
        let resolved = waiters.filter { $0.value.condition(segments) }
        for (id, waiter) in resolved {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: ())
        }
    }
}

private actor StubLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var prepareCount = 0
    private var transcribeCount = 0

    func prepare() async throws {
        prepareCount += 1
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        transcribeCount += 1
        return ASRResult(
            text: "ライブ文字起こし\(transcribeCount)",
            detectedLanguage: "ja"
        )
    }

    func unload() async {}

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCount, transcribeCount)
    }
}

@Test
func nativeSessionProcessorStreamsLiveSegmentsWithoutRealModel() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = AppPaths(
        applicationSupportURL: root.appending(
            path: "support",
            directoryHint: .isDirectory
        ),
        cacheURL: root.appending(
            path: "cache",
            directoryHint: .isDirectory
        ),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let processingDirectory = sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)

    let audioWriter = try DurableAudioWriter(directory: processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await audioWriter.append(
        samples: Array(repeating: Float(0.1), count: 16_000)
    )
    let checkpoint = await audioWriter.committedSnapshot()

    let asr = StubLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: UnusedLiveTestVAD()
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let segmentationRunID = try await processor.startLiveTranscription(
        sessionID: sessionID,
        sampleRate: checkpoint.sampleRate
    )

    let segments = [
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000001",
            speechRanges: [0..<4_000]
        ),
        SegmentReference(
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000002",
            speechRanges: [4_000..<8_000]
        )
    ]

    _ = try await processor.registerLiveSegments(
        sessionID: sessionID,
        segments: segments
    )

    let recorder = LiveUpdateRecorder()
    let progress = try await processor.processLiveSegments(
        sessionID: sessionID,
        segments: segments,
        checkpoint: checkpoint,
        shouldPause: { _ in nil },
        onStatus: nil,
        onUpdate: { segments, _ in
            await recorder.record(segments)
        }
    )

    #expect(progress.completedCount == 2)
    #expect(progress.failedCount == 0)
    #expect(progress.pendingCount == 0)
    #expect(progress.materializedSegments.map(\.text) == [
        "ライブ文字起こし1",
        "ライブ文字起こし2"
    ])
    #expect(
        await recorder.snapshot() == progress.materializedSegments
    )

    let counts = await asr.counts()
    #expect(counts.prepare == 1)
    #expect(counts.transcribe == 2)
}

private actor ScriptedStopASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var failingCalls: Set<Int>
    private var calls = 0

    init(failingCalls: Set<Int> = []) { self.failingCalls = failingCalls }

    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        if failingCalls.contains(calls) { throw UnexpectedLiveTestFinalization.called }
        return ASRResult(text: "認識\(calls)", detectedLanguage: "ja")
    }
    func unload() async {}
    func callCount() -> Int { calls }
    func stopFailing() { failingCalls = [] }
}

private struct StopFixture {
    let root: URL
    let processor: NativeSessionProcessor
    let sessionID: UUID
    let layout: SessionLayout
    let checkpoint: AudioCheckpoint
    let segments: [SegmentReference]

    func stop(resume: Bool = false) async -> SessionProcessingResult {
        if resume {
            return await processor.resumeSession(
                sessionID: sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
                onStatus: { _ in }, onUpdate: { _, _ in }
            )
        }
        return await processor.processSession(
            sessionID: sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
            metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
        )
    }
}

/// A recording whose live segmentation finished with two registered segments; the first is recognized live.
private func makeStopFixture(asr: ScriptedStopASR) async throws -> StopFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory), sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let audioWriter = try DurableAudioWriter(
        directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audioWriter.committedSnapshot()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(asr: asr, finalTranscriptVAD: UnusedLiveTestVAD()),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    // The live side runs through the real coordinator: its stop seals and completes the segmentation.
    let segmentFor: @Sendable (String, Int) -> SegmentReference = { runID, ordinal in
        SegmentReference(
            segmentationRunID: runID, segmentID: String(format: "seg_%06d", ordinal),
            speechRanges: [Int64(ordinal - 1) * 4_000..<Int64(ordinal) * 4_000]
        )
    }
    let effects = await StopTestEffects(sessionID: sessionID)
    let live = await LiveTranscriptionCoordinator(
        state: LiveTranscriptionState(), effects: effects, processor: processor,
        thermalMonitor: PublishedRetryNoThermalMonitor(), resourceMonitor: nil,
        sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
    )
    try await live.startVAD(sessionID: sessionID, checkpoint: checkpoint) { runID in
        TwoSegmentVAD(segmentationRunID: runID, tail: [segmentFor(runID, 2)])
    }
    let runID = try #require(try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID)?.segmentationRunID)
    let first = segmentFor(runID, 1)
    await live.enqueue(sessionID: sessionID, segments: [first], checkpoint: checkpoint)
    await live.waitForDrain(sessionID: sessionID)
    #expect(await asr.callCount() == 1)
    // The tail is registered at stop and recognized by the stop's drain, not live.
    await effects.setModelsIdle()
    await live.stopVADPolling()
    await live.finishVAD(sessionID: sessionID, checkpoint: checkpoint)
    return StopFixture(root: root, processor: processor, sessionID: sessionID, layout: layout,
                       checkpoint: checkpoint, segments: [first, segmentFor(runID, 2)])
}

private actor CountingStoredVAD: FinalTranscriptVADSegmenter {
    nonisolated let provenance = RunProvenance(engine: "counting-stored-vad", model: nil, version: "test", configuration: [:])
    private var calls = 0

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        calls += 1
        return [SegmentReference(segmentationRunID: runID, segmentID: "seg_000001", speechRanges: [0..<8_000])]
    }

    func callCount() -> Int { calls }
}

private actor PollFailingVAD: LiveVADProcessing {
    nonisolated let segmentationRunID: String

    init(segmentationRunID: String) { self.segmentationRunID = segmentationRunID }

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        throw UnexpectedLiveTestFinalization.called
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0,
                        committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }
}

private final class FirstPollOnlySleep: @unchecked Sendable {
    private var polled = false
    func sleep() async throws {
        if !polled { polled = true; return }
        try await Task.sleep(for: .seconds(3_600))
    }
}

@Test
func aVADThatFailedDoesNotCertifySegmentationAndStopReplaysTheStoredVAD() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory), sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let audioWriter = try DurableAudioWriter(
        directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL
    )
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audioWriter.committedSnapshot()
    let storedVAD = CountingStoredVAD()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(asr: ScriptedStopASR(), finalTranscriptVAD: storedVAD),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    let effects = await StopTestEffects(sessionID: sessionID, checkpoint: checkpoint)
    let liveState = await LiveTranscriptionState()
    let pollSleep = FirstPollOnlySleep()
    let live = await LiveTranscriptionCoordinator(
        state: liveState, effects: effects, processor: processor,
        thermalMonitor: PublishedRetryNoThermalMonitor(), resourceMonitor: nil,
        sleep: { _ in try await pollSleep.sleep() }
    )
    try await live.startVAD(sessionID: sessionID, checkpoint: checkpoint) { runID in
        PollFailingVAD(segmentationRunID: runID)
    }
    // A transient poll error is recorded; the EOF flush then succeeds.
    while await liveState.vadFailureText == nil { await Task.yield() }
    await live.stopVADPolling()
    await live.finishVAD(sessionID: sessionID, checkpoint: checkpoint)

    let beforeStop = try #require(try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID))
    #expect(!beforeStop.segmentationCompleted)
    await processor.cancelLiveTranscription(sessionID: sessionID)

    let result = await processor.processSession(
        sessionID: sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )

    #expect(result.disposition == .completed, "\(result.message ?? "no failure message")")
    #expect(await storedVAD.callCount() == 1)
}

private actor TwoSegmentVAD: LiveVADProcessing {
    nonisolated let segmentationRunID: String
    private let tail: [SegmentReference]

    init(segmentationRunID: String, tail: [SegmentReference]) {
        self.segmentationRunID = segmentationRunID
        self.tail = tail
    }

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        preconditionFailure("polling is not used")
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(emittedSegments: tail, totalSegmentCount: 2,
                        committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }
}

@MainActor
private final class StopTestEffects: LiveTranscriptionEffects {
    let recordingSessionID: UUID?
    var modelPhase = ModelPreparationStatus.Phase.ready

    private let checkpoint: AudioCheckpoint?

    init(sessionID: UUID, checkpoint: AudioCheckpoint? = nil) {
        recordingSessionID = sessionID
        self.checkpoint = checkpoint
    }

    func setModelsIdle() { modelPhase = .idle }
    func isCurrentRecording(_ sessionID: UUID) -> Bool { sessionID == recordingSessionID }
    func committedLiveCheckpoint() async throws -> AudioCheckpoint {
        guard let checkpoint else { preconditionFailure("polling is not used") }
        return checkpoint
    }
    func awaitIdleRelease() async {}
    func awaitModelPreparation() async {}
    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler { { _ in } }
    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler { { _, _ in } }
    func liveDidChange(_ event: LiveTranscriptionEvent) {}
}

@Test
func stopDoesNotRecognizeSavedSegmentsAgain() async throws {
    let asr = ScriptedStopASR()
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await asr.callCount() == 1)

    let result = await fixture.stop()

    #expect(result.disposition == .completed, "\(result.message ?? "no failure message")")
    #expect(await asr.callCount() == 2)
    let stored = try EventLogTranscriptReader().validateCompletion(
        eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID, frameCount: fixture.checkpoint.committedFrames
    )
    let rows = try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
        .materialize(events: stored.events, activeRuns: stored.state.runs)
    #expect(rows.map(\.text) == ["認識1", "認識2"])
}

@Test
func stopAfterALiveASRFailureIsFailedAndNotAutoResumable() async throws {
    let asr = ScriptedStopASR(failingCalls: [1])
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let stopped = await fixture.stop()

    #expect(stopped.disposition == .failed)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.state == .failed)
    #expect(await asr.callCount() == 1)
}

@Test
func aCancelledStopAfterALiveASRFailureStaysFailed() async throws {
    let asr = ScriptedStopASR(failingCalls: [1])
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let task = Task { () -> SessionProcessingResult in
        while !Task.isCancelled { await Task.yield() }
        return await fixture.stop()
    }
    task.cancel()
    let stopped = await task.value

    #expect(stopped.disposition == .failed)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.state == .failed)
}

@Test
func aCancelledStopReportsAMalformedLogRecordAsFailed() async throws {
    let fixture = try await makeStopFixture(asr: ScriptedStopASR())
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let log = try FileHandle(forWritingTo: fixture.layout.eventsURL)
    try log.seekToEnd()
    try log.write(contentsOf: Data("{\"malformed\": true}\n".utf8))
    try log.close()

    let task = Task { () -> SessionProcessingResult in
        while !Task.isCancelled { await Task.yield() }
        return await fixture.stop()
    }
    task.cancel()
    let stopped = await task.value

    #expect(stopped.disposition == .failed)
}

@Test
func stopFailsOnAnASRFailureAndResumeRecognizesOnlyTheFailedSegment() async throws {
    let asr = ScriptedStopASR(failingCalls: [2])
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let stopped = await fixture.stop()

    #expect(stopped.disposition == .failed)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.state == .failed)
    let failed = try #require(try ProcessingLogState(eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID))
    #expect(failed.hasUnresolvedASRFailure && !failed.recognitionCompleted)

    await asr.stopFailing()
    let resumed = await fixture.stop(resume: true)

    #expect(resumed.disposition == .completed, "\(resumed.message ?? "no failure message")")
    #expect(await asr.callCount() == 3)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.state == .complete)
}

private final class StopThermalMonitor: ThermalMonitoring, Sendable {
    private let pressure: Mutex<ThermalPressure>
    init(_ pressure: ThermalPressure) { self.pressure = Mutex(pressure) }
    func set(_ new: ThermalPressure) { pressure.withLock { $0 = new } }
    var isCritical: Bool { pressure.withLock { $0 } == .critical }
    var liveASRDecision: LiveASRThermalDecision { LiveASRThermalPolicy.decision(pressure: pressure.withLock { $0 }) }
    @MainActor
    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any ThermalStateObservation {
        PublishedRetryThermalObservation()
    }
}

/// The queue side of a stop: the live worker is already idle, so the drain wait has nothing to wait for.
@MainActor
private final class StopQueueEffects: SessionProcessingEffects {
    var processingQueue = SessionProcessingQueue()
    var pausesProcessing = false
    var modelsReady = true
    private(set) var finished: [BatchDisposition?] = []

    func prepareModels() {}
    func awaitIdleRelease() async {}
    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler { { _ in } }
    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler { { _, _ in } }
    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome { .drained }
    func liveASRFailure(sessionID: UUID) -> String? { nil }
    func cleanupLiveASRState(sessionID: UUID) {}
    func refreshSavedSessions() {}
    func autoExportIfEnabled(sessionID: UUID) async {}
    func processingDidChange(_ event: SessionProcessingEvent) {
        if case .finished(_, let result) = event { finished.append(result?.disposition) }
    }
}

/// Resuming a held stop continues the generation it began: same generation and run IDs, no repeated ASR call.
private func expectStopContinuedTheSameGeneration(
    _ fixture: StopFixture, before: ProcessingLogState, asr: ScriptedStopASR
) async throws {
    #expect(await asr.callCount() == 2)
    let after = try #require(try ProcessingLogState(eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID))
    #expect(after.generation.id == before.generation.id)
    #expect(after.segmentationRunID == before.segmentationRunID && after.asrRunID == before.asrRunID)
    let stored = try EventLogTranscriptReader().validateCompletion(
        eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID, frameCount: fixture.checkpoint.committedFrames
    )
    let rows = try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
        .materialize(events: stored.events, activeRuns: stored.state.runs)
    #expect(rows.map(\.text) == ["認識1", "認識2"])
}

@MainActor
@Test(.timeLimit(.minutes(10)))
func coolingAfterStopContinuesTheSameGeneration() async throws {
    let asr = ScriptedStopASR()
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try #require(try ProcessingLogState(eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID))
    let thermal = StopThermalMonitor(.critical)
    let effects = StopQueueEffects()
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: fixture.processor, thermalMonitor: thermal, resourceHolds: nil
    )

    coordinator.enqueue(.finalize(sessionID: fixture.sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.reason) == [.inference(.thermal)])
    #expect(await asr.callCount() == 1)

    thermal.set(.nominal)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(effects.finished == [.completed])
    try await expectStopContinuedTheSameGeneration(fixture, before: before, asr: asr)
}

@MainActor
@Test(.timeLimit(.minutes(10)))
func aModelHoldAfterStopContinuesTheSameGeneration() async throws {
    let asr = ScriptedStopASR()
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try #require(try ProcessingLogState(eventsURL: fixture.layout.eventsURL, sessionID: fixture.sessionID))
    let effects = StopQueueEffects()
    effects.modelsReady = false
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: fixture.processor, thermalMonitor: StopThermalMonitor(.nominal), resourceHolds: nil
    )

    coordinator.enqueue(.finalize(sessionID: fixture.sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.modelHeld.count == 1)
    #expect(await asr.callCount() == 1)

    effects.modelsReady = true
    coordinator.resumeModelHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(effects.finished == [.completed])
    try await expectStopContinuedTheSameGeneration(fixture, before: before, asr: asr)
}

@MainActor
@Test(.timeLimit(.minutes(10)))
func aDurableASRFailureIsReportedFailedUnderCriticalThermalNotHeld() async throws {
    let asr = ScriptedStopASR(failingCalls: [1])
    let fixture = try await makeStopFixture(asr: asr)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let effects = StopQueueEffects()
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: fixture.processor, thermalMonitor: StopThermalMonitor(.critical), resourceHolds: nil
    )

    coordinator.enqueue(.finalize(sessionID: fixture.sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.finished == [.failed])
    #expect(effects.processingQueue.held.isEmpty)
    #expect(await asr.callCount() == 1)
    #expect(try ProcessingMetadataStore(sessionURL: fixture.layout.sessionURL).load()?.state == .failed)
}

/// Heat rises once the first segment is recognized.
private actor HeatingLiveASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private let thermal: StopThermalMonitor
    private var calls = 0

    init(thermal: StopThermalMonitor) { self.thermal = thermal }

    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        if calls == 1 { thermal.set(.critical) }
        return ASRResult(text: "認識\(calls)", detectedLanguage: "ja")
    }
    func unload() async {}
    func callCount() -> Int { calls }
}

/// What the live worker's cooling wait does the first time it runs.
@MainActor
private final class FirstCoolingWait {
    var action: (@MainActor () async -> Void)?
    func run() async {
        let action = self.action
        self.action = nil
        await action?()
    }
}

/// Heat stops a two-segment batch after its first segment. While the worker cools, VAD registers a later segment
/// whose audio lies beyond the batch's checkpoint. After cooling the batch finishes only its own segment, and the
/// later segment runs in its own batch: every segment completes and no ASR failure is logged.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aBatchStoppedByHeatResumesItsOwnSegmentsWhileALaterSegmentWaitsForItsBatch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory), sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let layout = SessionLayout(sessionURL: sessionURL)
    let audioWriter = try DurableAudioWriter(
        directory: layout.processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL
    )
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 8_000))
    let firstCheckpoint = await audioWriter.committedSnapshot()
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 8_000))
    let laterCheckpoint = await audioWriter.committedSnapshot()
    #expect(firstCheckpoint.committedFrames == 8_000 && laterCheckpoint.committedFrames == 16_000)

    let thermal = StopThermalMonitor(.fair)
    let asr = HeatingLiveASR(thermal: thermal)
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(asr: asr, finalTranscriptVAD: UnusedLiveTestVAD()),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    let runID = try await processor.startLiveTranscription(sessionID: sessionID, sampleRate: 16_000)
    let segment: (Int) -> SegmentReference = { ordinal in
        SegmentReference(
            segmentationRunID: runID, segmentID: String(format: "seg_%06d", ordinal),
            speechRanges: [Int64(ordinal - 1) * 4_000..<Int64(ordinal) * 4_000]
        )
    }
    let liveState = LiveTranscriptionState()
    let coolingWait = FirstCoolingWait()
    let effects = StopTestEffects(sessionID: sessionID)
    let live = LiveTranscriptionCoordinator(
        state: liveState, effects: effects, processor: processor,
        thermalMonitor: thermal, resourceMonitor: nil, sleep: { _ in await coolingWait.run() }
    )
    coolingWait.action = {
        await live.enqueue(sessionID: sessionID, segments: [segment(4)], checkpoint: laterCheckpoint)
        thermal.set(.fair)
    }

    await live.enqueue(sessionID: sessionID, segments: [segment(1), segment(2)], checkpoint: firstCheckpoint)
    while await live.waitForDrain(sessionID: sessionID) == .suspendedForCooling { await Task.yield() }

    #expect(coolingWait.action == nil)
    #expect(liveState.failure(sessionID: sessionID) == nil)
    #expect(await asr.callCount() == 3)
    withExtendedLifetime(effects) {}
    let log = try String(contentsOf: layout.eventsURL, encoding: .utf8)
    #expect(!log.contains("\"asr.failed\""))
    #expect(log.components(separatedBy: "\"asr.completed\"").count - 1 == 3)
}

private actor GatedLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private var release: CheckedContinuation<Void, Never>?
    private var waitingForStart: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        waitingForStart?.resume()
        waitingForStart = nil
        await withCheckedContinuation { continuation in
            release = continuation
        }
        return ASRResult(text: "取り消し後の結果", detectedLanguage: nil)
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

    func unload() async {}
}

private actor UpdateCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor ProcessingStateRecorder {
    private(set) var states: [ProcessingState] = []

    func record(_ state: ProcessingState) {
        states.append(state)
    }

    func snapshot() -> [ProcessingState] { states }
}

private actor ProcessingStatusRecorder {
    private(set) var statuses: [NativeSessionProcessor.Status] = []

    func record(_ status: NativeSessionProcessor.Status) {
        statuses.append(status)
    }

    func reset() {
        statuses = []
    }
}

@Test
func cancelledLiveTranscriptionDoesNotPublishInFlightResult() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: sessionID, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let audioWriter = try DurableAudioWriter(directory: sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory), chunkDurationSeconds: 1, sessionURL: sessionURL)
    try await audioWriter.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audioWriter.committedSnapshot()
    let asr = GatedLiveProcessorASR()
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: asr,
            finalTranscriptVAD: UnusedLiveTestVAD()
        ),
        audioHandling: RecordingTestAudioHandling(),
        contentPriority: .disabled,
        sleep: { _ in }
    )
    let segmentationRunID = try await processor.startLiveTranscription(
        sessionID: sessionID, sampleRate: checkpoint.sampleRate
    )
    let segment = SegmentReference(
        segmentationRunID: segmentationRunID, segmentID: "seg_000001",
        speechRanges: [0..<4_000]
    )
    let updates = UpdateCounter()

    let processing = Task {
        try await processor.processLiveSegments(
            sessionID: sessionID, segments: [segment], checkpoint: checkpoint,
            shouldPause: { _ in nil }, onStatus: nil,
            onUpdate: { _, _ in await updates.increment() }
        )
    }
    await asr.waitUntilTranscribing()
    await processor.cancelLiveTranscription(sessionID: sessionID)
    await asr.resume()
    _ = try await processing.value

    #expect(await updates.count == 0)
}

private actor ScriptedLiveProcessorASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "scripted-asr", model: nil, version: "test", configuration: [:])
    private var texts: [String]
    private(set) var callCount = 0
    init(texts: [String]) { self.texts = texts }
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        callCount += 1
        return ASRResult(text: texts.removeFirst(), detectedLanguage: "ja")
    }
    func unload() async {}
}

private struct LiveProcessorFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fixture-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(segmentationRunID: runID, segmentID: "final", speechRanges: [0..<16_000])]
    }
}

private actor NativeClauseProvider: DecisionProvider {
    private struct HeldWaiter {
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let holdPriorityNumber: Int?
    private let failedPriorityNumbers: Set<Int>
    private let primaryPriorityNumbers: Set<Int>
    private var gate: CheckedContinuation<Void, Never>?
    private var heldWaiters: [UUID: HeldWaiter] = [:]
    private var beforePriority: (@Sendable (Int) throws -> Void)?
    private(set) var requests: [[String]] = []
    private(set) var boundaryRequests: [ClauseBoundaryRequest] = []

    init(holdPriorityNumber: Int?, failedPriorityNumbers: Set<Int>, primaryPriorityNumbers: Set<Int> = []) {
        self.holdPriorityNumber = holdPriorityNumber
        self.failedPriorityNumbers = failedPriorityNumbers
        self.primaryPriorityNumbers = primaryPriorityNumbers
    }

    func setBeforePriority(_ action: @escaping @Sendable (Int) throws -> Void) { beforePriority = action }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequests.append(request)
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.95) }),
            continuationProbability: request.next.map { _ in 0.05 },
            fillerRanges: [],
            inputTokens: 5
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        requests.append(targets.map(\.text))
        let number = requests.count
        if number == holdPriorityNumber {
            await withCheckedContinuation { continuation in
                gate = continuation
                resolveHeldWaiters()
            }
        }
        try beforePriority?(number)
        if failedPriorityNumbers.contains(number) { throw DecisionResponseError.missingAnswer }
        // A late live LOW answer must not replace the final fresh PRIMARY answer.
        let low = !primaryPriorityNumbers.contains(number) && (holdPriorityNumber == nil || number <= 2)
        let decision = try ContentPriorityDecision(
            priority: low ? .lowPriority : .primary, confidence: 0.95,
            probabilities: low ? ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975] : ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: 7
        )
    }

    func waitUntilHeld() async throws {
        if gate != nil { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard gate == nil else {
                    continuation.resume(returning: ())
                    return
                }
                heldWaiters[id] = HeldWaiter(continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelHeldWaiter(id) }
        }
    }

    private func cancelHeldWaiter(_ id: UUID) {
        guard let waiter = heldWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resolveHeldWaiters() {
        let waiters = Array(heldWaiters.values)
        heldWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(returning: ())
        }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

private struct NativeDecisionFixture {
    let root: URL
    let paths: AppPaths
    let sessionID: UUID
    let sessionURL: URL
    let checkpoint: AudioCheckpoint
    let asr: ScriptedLiveProcessorASR
    let processor: NativeSessionProcessor

    init(
        texts: [String], factory: @escaping NativeSessionProcessor.DecisionCoordinatorFactory, counter: DecisionUsageCounter,
        makeDecisionEventWriter: @escaping NativeSessionProcessor.DecisionEventWriterFactory = { try SessionWriter(sessionURL: $0) }
    ) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        paths = AppPaths(
            applicationSupportURL: root.appending(path: "support"), cacheURL: root.appending(path: "cache"),
            sessionsRootOverride: nil
        )
        sessionID = UUID()
        sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let audio = try DurableAudioWriter(directory: SessionLayout(sessionURL: sessionURL).processingDirectory, chunkDurationSeconds: 1, sessionURL: sessionURL)
        try await audio.append(samples: Array(repeating: 0.1, count: 16_000))
        checkpoint = await audio.committedSnapshot()
        asr = ScriptedLiveProcessorASR(texts: texts)
        processor = NativeSessionProcessor(
            paths: paths,
            engines: SessionProcessingEngines(asr: asr, finalTranscriptVAD: LiveProcessorFinalVAD()),
            audioHandling: RecordingTestAudioHandling(),
            contentPriority: .localTagger(factory, usageCounter: counter),
            sleep: { _ in },
            makeDecisionEventWriter: makeDecisionEventWriter
        )
    }

    func stored() throws -> StoredTranscriptEvents {
        try #require(try EventLogTranscriptReader().read(
            eventsURL: SessionLayout(sessionURL: sessionURL).eventsURL, sessionID: sessionID
        ))
    }

    func rows() throws -> [MaterializedTranscriptSegment] {
        let stored = try stored()
        return try TranscriptMaterializer(sampleRate: 16_000).materialize(
            events: stored.events, activeRuns: stored.state.runs
        )
    }
}

private struct TaggerLoadFailure: Error {}

private struct NativeDecisionRetryInitializationFailure: LocalizedError, Sendable {
    var errorDescription: String? { "テスト初期化エラー" }
}

@Test(.timeLimit(.minutes(10)))
func cancellingLiveDecisionsAfterAFailedTaggerLoadClearsItsPendingKeys() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await NativeDecisionFixture(
        texts: ["前の本文", "次の本文"], factory: { throw TaggerLoadFailure() }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let liveRunID = try await fixture.processor.startLiveTranscription(
        sessionID: fixture.sessionID, sampleRate: 16_000
    )
    let updates = LiveUpdateRecorder()
    _ = try await fixture.processor.processLiveSegments(
        sessionID: fixture.sessionID,
        segments: [
            SegmentReference(segmentationRunID: liveRunID, segmentID: "a", speechRanges: [0..<4_000]),
            SegmentReference(segmentationRunID: liveRunID, segmentID: "b", speechRanges: [4_000..<8_000])
        ],
        checkpoint: fixture.checkpoint, shouldPause: { _ in nil }, onStatus: nil,
        onUpdate: { rows, _ in await updates.record(rows) }
    )
    try await updates.waitFor { $0.first?.clauseState == .boundaryPending }
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 1)
    await fixture.processor.cancelLiveTranscription(sessionID: fixture.sessionID)
    #expect(await counter.snapshot().pendingBoundarySegmentCount == 0)
    #expect(await counter.snapshot().sendCount == 0)
}

@Test(.timeLimit(.minutes(10)))
func aCancelledRetryWritesNoCompletionAndTheNextRetryRebuildsWithFreshRuns() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: 2, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["再試行する本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let before = try fixture.stored()
    let pending = before.pendingDecisions.clauses
    #expect(pending.count == 1)

    let sessionID = fixture.sessionID, processor = fixture.processor
    let cancelled = Task {
        await processor.retryContentPrioritySession(
            sessionID: sessionID, boundarySegments: [], clauses: pending, onStatus: { _ in }, onUpdate: { _, _ in }
        )
    }
    try await provider.waitUntilHeld()
    cancelled.cancel()
    await provider.release()
    let cancelledResult = await cancelled.value

    #expect(cancelledResult.disposition == .paused)
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: eventsURL)).lines
    #expect(try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: lines, sessionID: fixture.sessionID))
    #expect(try fixture.stored().state.runs == before.state.runs)

    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let after = try fixture.stored()
    #expect(after.state.runs.clauseBoundary != before.state.runs.clauseBoundary)
    #expect(after.state.runs.contentPriority != before.state.runs.contentPriority)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    #expect(await provider.requests.count == 3)
}

@Test
func retryRejectsATargetThatIsNotPendingAndWritesNothing() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["判定保留中の本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    let logBefore = try Data(contentsOf: eventsURL)
    let notPending = try ClauseReference(boundaryRunID: "boundary_unknown", clauseID: "c1_0")

    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [notPending], onStatus: { _ in }, onUpdate: { _, _ in }
    )

    #expect(result.disposition == .failed)
    #expect(result.message == "発話文の判定を再試行できませんでした: 判定の再試行対象がありません")
    #expect(try Data(contentsOf: eventsURL) == logBefore)
    #expect(await provider.requests.count == 1)
}

@Test
func aFirstDecisionPairMustCoverEveryRecognizedSource() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["最初の判定。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let decisionsOff = NativeSessionProcessor(
        paths: fixture.paths,
        engines: SessionProcessingEngines(asr: fixture.asr, finalTranscriptVAD: LiveProcessorFinalVAD()),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    _ = await decisionsOff.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let before = try fixture.stored()
    #expect(before.state.runs.clauseBoundary == nil)
    let recognized = before.pendingDecisions.boundarySegments
    #expect(recognized.count == 1)

    let rejected = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [], onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(rejected.disposition == .failed)
    #expect(try fixture.stored().state.runs.clauseBoundary == nil)

    let accepted = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: recognized, clauses: [], onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(accepted.disposition == .completed)
    let after = try fixture.stored()
    #expect(after.state.runs.clauseBoundary != nil)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    #expect(try fixture.rows().first?.clauseSlices.map(\.priority) == [.lowPriority])
}

private actor RetryUpdateGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var didEnter = false

    func suspend() async {
        didEnter = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entered = $0 }
    }

    func open() {
        release?.resume()
        release = nil
    }
}

@Test(.timeLimit(.minutes(10)))
func aRetryCancelledBeforeItsDrainWritesNothing() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["再試行する本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let pending = try fixture.stored().pendingDecisions.clauses
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    // A complete final record without its line feed: opening a writer would repair it.
    let logBefore = try Data(contentsOf: eventsURL).dropLast()
    try Data(logBefore).write(to: eventsURL)
    let gate = RetryUpdateGate()
    let sessionID = fixture.sessionID, processor = fixture.processor

    let retry = Task {
        await processor.retryContentPrioritySession(
            sessionID: sessionID, boundarySegments: [], clauses: pending, onStatus: { _ in },
            onUpdate: { _, state in if state == .running { await gate.suspend() } }
        )
    }
    await gate.waitUntilEntered()
    retry.cancel()
    await gate.open()
    let result = await retry.value

    #expect(result.disposition == .paused)
    #expect(try Data(contentsOf: eventsURL) == Data(logBefore))
    #expect(await provider.requests.count == 1)
}

@Test(.timeLimit(.minutes(10)))
func aSelectionWriteThatFailsAfterReachingTheLogIsReportedAsAnUnknownOutcomeNeverPaused() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(
        texts: ["再試行する本文。"], factory: { decisions }, counter: counter,
        makeDecisionEventWriter: { try CancelAfterSelectionEventWriter(sessionURL: $0, failsAfterWriting: true) }
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )

    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: try fixture.stored().pendingDecisions.clauses,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )

    #expect(result.disposition == .failed)
    #expect(result.message?.contains("セッションを開き直してください") == true)
}

/// Cancels the running task right after the selection event reached the log, and optionally then fails.
private actor CancelAfterSelectionEventWriter: DecisionEventWriting {
    nonisolated let eventsURL: URL
    private let writer: SessionWriter
    private let failsAfterWriting: Bool

    init(sessionURL: URL, failsAfterWriting: Bool = false) throws {
        writer = try SessionWriter(sessionURL: sessionURL)
        eventsURL = sessionURL.appending(path: "events.jsonl")
        self.failsAfterWriting = failsAfterWriting
    }

    func append<Payload: Codable & Sendable>(_ draft: EventDraft<Payload>) async throws -> EventEnvelope<Payload> {
        try await writer.append(draft)
    }

    func appendSelection(_ selection: DecisionRunReplacement, sessionID: UUID) async throws {
        try await writer.appendSelection(selection, sessionID: sessionID)
        withUnsafeCurrentTask { $0?.cancel() }
        if failsAfterWriting { throw POSIXError(.EIO) }
    }

    func appendFailedRetryCompletion(
        _ draft: EventDraft<ProcessingRunCompletedPayload>
    ) async throws -> EventEnvelope<ProcessingRunCompletedPayload> {
        try await writer.appendFailedRetryCompletion(draft)
    }
}

@Test(.timeLimit(.minutes(10)))
func aRetryCancelledAfterItsSelectionIsCompletedWithTheSelectedRows() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(
        texts: ["再試行する本文。"], factory: { decisions }, counter: counter,
        makeDecisionEventWriter: { try CancelAfterSelectionEventWriter(sessionURL: $0) }
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let before = try fixture.stored()
    let updates = LiveUpdateRecorder()

    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: before.pendingDecisions.clauses,
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )

    #expect(result.disposition == .completed)
    let after = try fixture.stored()
    #expect(after.state.runs.contentPriority != before.state.runs.contentPriority)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    #expect(await updates.snapshot() == (try fixture.rows()))
    #expect(await counter.snapshot().pendingPriorityClauseCount == 0)
}

private enum PublishedRetryLatePause: CaseIterable {
    case cancellation
    case processingPause
    case both
}

private final class PublishedRetryThermalObservation: ThermalStateObservation {}

private struct PublishedRetryNoThermalMonitor: ThermalMonitoring {
    var isCritical: Bool { false }
    var liveASRDecision: LiveASRThermalDecision { .processNow }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        PublishedRetryThermalObservation()
    }
}

private struct PublishedRetryFinishedEvent {
    let sessionID: UUID
    let disposition: BatchDisposition?
    let message: String?
}

@MainActor
private final class PublishedRetryEffects: SessionProcessingEffects {
    var processingQueue = SessionProcessingQueue()
    var pausesProcessing = false
    var onComplete: (@MainActor () -> Void)?

    private(set) var statusTexts: [String] = []
    private(set) var updateStates: [ProcessingState] = []
    private(set) var updatedSegments: [MaterializedTranscriptSegment] = []
    private(set) var finishedEvents: [PublishedRetryFinishedEvent] = []
    private(set) var heldCount = 0
    private(set) var exportCount = 0

    var modelsReady: Bool { true }
    func prepareModels() {}

    func awaitIdleRelease() async {}

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { status in await self.record(status) }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { segments, state in await self.record(segments: segments, state: state) }
    }

    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome {
        preconditionFailure("published retry test does not finish live transcription")
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        preconditionFailure("published retry test does not inspect live ASR failures")
    }

    func cleanupLiveASRState(sessionID: UUID) {
        preconditionFailure("published retry test does not clean up live ASR state")
    }

    func refreshSavedSessions() {}

    func autoExportIfEnabled(sessionID: UUID) async {
        exportCount += 1
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        switch event {
        case .held:
            heldCount += 1
        case .finished(let request, let result):
            finishedEvents.append(PublishedRetryFinishedEvent(
                sessionID: request.sessionID,
                disposition: result?.disposition,
                message: result?.message
            ))
        case .backlogged, .heldForModels, .began, .liveFailed, .next, .willFinishDrain, .drained:
            break
        }
    }

    private func record(_ status: NativeSessionProcessor.Status) {
        statusTexts.append(status.text)
    }

    private func record(segments: [MaterializedTranscriptSegment], state: ProcessingState) {
        updatedSegments = segments
        updateStates.append(state)
        if state == .complete {
            onComplete?()
        }
    }
}

@MainActor
@Test(.timeLimit(.minutes(10)), arguments: PublishedRetryLatePause.allCases)
private func publishedRetryRemainsCompletedAfterLatePause(_ latePause: PublishedRetryLatePause) async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(
        texts: ["再試行後に公開する本文。"], factory: { decisions }, counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let initialResult = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(initialResult.disposition == .completed)

    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let initialStored = try fixture.stored()
    let initialContentPriorityRun = try #require(initialStored.state.runs.contentPriority)
    let pendingClauses = initialStored.pendingDecisions.clauses
    #expect(pendingClauses.count == 1)
    let pendingClause = try #require(pendingClauses.first)

    let effects = PublishedRetryEffects()
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: fixture.processor,
        thermalMonitor: PublishedRetryNoThermalMonitor(),
        resourceHolds: nil
    )
    var completionMetadata: ProcessingMetadata?
    var completionMetadataLoadError: String?
    var completionCallbackCount = 0
    effects.onComplete = {
        completionCallbackCount += 1
        do {
            if let loaded = try store.load() {
                completionMetadata = loaded
            } else {
                completionMetadataLoadError = "processing metadata was absent at complete callback"
            }
        } catch {
            completionMetadataLoadError = error.localizedDescription
        }

        switch latePause {
        case .cancellation:
            coordinator.requestPause()
        case .processingPause:
            effects.pausesProcessing = true
        case .both:
            coordinator.requestPause()
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.retryContentPriority(
        sessionID: fixture.sessionID,
        boundarySegments: [],
        clauses: [pendingClause]
    ))
    await coordinator.waitUntilIdle()

    #expect(completionCallbackCount == 1)
    #expect(completionMetadataLoadError == nil)
    let metadataAtCompletion = try #require(completionMetadata)
    #expect(metadataAtCompletion.state == .complete)
    let storedAtCompletion = try fixture.stored()
    #expect(storedAtCompletion.state.runs.contentPriority != initialContentPriorityRun)
    #expect(storedAtCompletion.pendingDecisions.pendingTargets.isEmpty)
    #expect(effects.updateStates.contains(.complete))
    #expect(effects.updatedSegments.map(\.text) == ["再試行後に公開する本文。"])

    #expect(effects.finishedEvents.count == 1)
    let finishedAtCompletion = try #require(effects.finishedEvents.first)
    #expect(finishedAtCompletion.sessionID == fixture.sessionID)
    // A successful retry is reported as .finished(request, nil), not as a completed result.
    #expect(finishedAtCompletion.disposition == nil)
    #expect(effects.heldCount == 0)
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.exportCount == 0)
    #expect(!effects.statusTexts.contains("処理は中断されました。次回の起動時に再開できます"))

    let metadataURL = fixture.sessionURL.appending(path: "processing_metadata.json")
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    let metadataBytesAfterCompletion = try Data(contentsOf: metadataURL)
    let eventBytesAfterCompletion = try Data(contentsOf: eventsURL)
    let providerRequestsAfterCompletion = await provider.requests
    #expect(providerRequestsAfterCompletion.count == 2)
    #expect(providerRequestsAfterCompletion == [
        ["再試行後に公開する本文。"],
        ["再試行後に公開する本文。"]
    ])
    let completionRecovery = try SessionRecoveryScanner(sessionsRoot: fixture.paths.sessionsRoot)
        .inspect(sessionID: fixture.sessionID).recovery
    #expect(SessionRecoveryPlan(completionRecovery?.action).launchRecoveryRequest(sessionID: fixture.sessionID) == nil)

    // If a regression leaves a stale held retry here, resuming it is finite and must not
    // re-send a provider request or overwrite the already published snapshot.
    effects.pausesProcessing = false
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(effects.heldCount == 0)
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.finishedEvents.count == 1)
    #expect(effects.finishedEvents.first?.disposition == nil)
    #expect(effects.exportCount == 0)
    #expect(!effects.statusTexts.contains("処理は中断されました。次回の起動時に再開できます"))
    let retryFailureMessages = effects.finishedEvents.compactMap(\.message).filter { $0.contains("再試行") }
    #expect(retryFailureMessages.isEmpty)
    #expect(await provider.requests == providerRequestsAfterCompletion)
    #expect(try Data(contentsOf: metadataURL) == metadataBytesAfterCompletion)
    #expect(try Data(contentsOf: eventsURL) == eventBytesAfterCompletion)
}

private final class SelectionAppendFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer { armed = false }
        return armed
    }
}

/// Fails the `pipeline.decisions.replaced` append, the publication point, while the first switch is armed.
private actor SelectionFailingEventWriter: DecisionEventWriting {
    nonisolated let eventsURL: URL
    private let writer: SessionWriter
    private let failure: SelectionAppendFailure

    init(sessionURL: URL, failure: SelectionAppendFailure) throws {
        writer = try SessionWriter(sessionURL: sessionURL)
        eventsURL = sessionURL.appending(path: "events.jsonl")
        self.failure = failure
    }

    func append<Payload: Codable & Sendable>(_ draft: EventDraft<Payload>) async throws -> EventEnvelope<Payload> {
        try await writer.append(draft)
    }

    func appendSelection(_ selection: DecisionRunReplacement, sessionID: UUID) async throws {
        if failure.consume() { throw POSIXError(.EIO) }
        try await writer.appendSelection(selection, sessionID: sessionID)
    }

    func appendFailedRetryCompletion(
        _ draft: EventDraft<ProcessingRunCompletedPayload>
    ) async throws -> EventEnvelope<ProcessingRunCompletedPayload> {
        try await writer.appendFailedRetryCompletion(draft)
    }
}

@Test
func retryAfterAFailedSelectionAppendUsesANewPriorityRunAndKeepsThePublishedSnapshotUntilSuccess() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1], primaryPriorityNumbers: [2])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let failure = SelectionAppendFailure()
    let fixture = try await NativeDecisionFixture(
        texts: ["再試行する本文。"], factory: { decisions }, counter: counter,
        makeDecisionEventWriter: { try SelectionFailingEventWriter(sessionURL: $0, failure: failure) }
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let before = try fixture.stored()
    let pending = before.pendingDecisions.clauses
    #expect(pending.count == 1)
    let previousRows = try fixture.rows()
    let updates = LiveUpdateRecorder()

    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending,
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    let afterFailure = try fixture.stored()
    #expect(afterFailure.state.runs == before.state.runs)
    #expect(afterFailure.pendingDecisions.clauses == pending)
    #expect(await updates.snapshot() == previousRows)
    let failedLog = try SessionRecovery.recoverJSONL(Data(contentsOf: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)).lines
    let unpublished = try #require(try EventLogLine.decode(failedLog).last {
        $0.header.eventType == ClauseEventType.priorityAssigned
    })
    let unpublishedRunID = try unpublished.requiredRunID()
    #expect(unpublishedRunID != before.state.runs.contentPriority)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 1)

    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending,
        onStatus: { _ in }, onUpdate: { rows, _ in await updates.record(rows) }
    )
    let after = try fixture.stored()
    #expect(after.state.runs.contentPriority != before.state.runs.contentPriority)
    #expect(after.state.runs.contentPriority != unpublishedRunID)
    #expect(after.state.runs.segmentation == before.state.runs.segmentation)
    #expect(after.state.runs.asr == before.state.runs.asr)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    let finalRows = try fixture.rows()
    #expect(finalRows.first?.clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await updates.snapshot() == finalRows)
    #expect(await fixture.asr.callCount == 1)
    #expect(await provider.requests == Array(repeating: ["再試行する本文。"], count: 3))
    #expect(await counter.snapshot().pendingPriorityClauseCount == 0)
}

@Test
func nativeRetryRejectsIncompleteLogBeforeSending() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["保留本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let metadata = try #require(try store.load())
    let pending = try fixture.stored().pendingDecisions.clauses
    #expect(pending.count == 1)
    let eventsURL = SessionLayout(sessionURL: fixture.sessionURL).eventsURL
    let handle = try FileHandle(forWritingTo: eventsURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"event_seq\":".utf8))
    try handle.synchronize()
    let corruptedLog = try Data(contentsOf: eventsURL)
    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(await provider.requests == [["保留本文。"]])
    #expect(await counter.snapshot().priorityRequests.sendCount == 1)
    #expect(try Data(contentsOf: eventsURL) == corruptedLog)
    #expect(try store.load() == metadata)
}

@Test
func unpublishedRetryRebuildsACompleteSnapshotEvenWithoutPendingTargetsAndNeverUsesUnpublishedAnswers() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["保存済み本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(result.disposition == .completed)
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try fixture.stored()
    #expect(before.pendingDecisions.pendingTargets.isEmpty)
    let usageBeforeRetry = await counter.snapshot()
    let writer = try SessionWriter(sessionURL: fixture.sessionURL)
    _ = try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: DecisionRunProvenance.boundary(identity: testDecisionIdentity))
    ))
    // A well-shaped assessment of a nonexistent source must not enter the rebuilt snapshot.
    _ = try await writer.append(EventDraft(
        eventType: ClauseEventType.boundaryAssessed, sessionID: fixture.sessionID, processingRunID: "boundary_retry_unpublished",
        payload: try ClauseBoundaryAssessment(
            source: SegmentTextReference(
                segmentationRunID: "missing", segmentID: "missing", asrRunID: "missing", asrEventSeq: 999
            ),
            candidates: [], probabilities: [:], nextHead: nil, continuationProbability: nil,
            fillerRanges: [], request: try DecisionRequestRecord(requestID: "decisionreq_unpublished", inputTokens: 1),
            sourceDecision: .assessed
        )
    ))
    _ = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [],
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let after = try fixture.stored()
    #expect(after.state.runs.clauseBoundary != before.state.runs.clauseBoundary)
    #expect(after.state.runs.contentPriority != before.state.runs.contentPriority)
    #expect(after.pendingDecisions.pendingTargets.isEmpty)
    #expect(try fixture.rows()[0].clauseSlices.map(\.priority) == [.lowPriority])
    #expect(await provider.requests == [["保存済み本文。"]])
    let boundaryRequests = await provider.boundaryRequests
    #expect(boundaryRequests.count == 1)
    let boundaryRequest = try #require(boundaryRequests.first)
    #expect(boundaryRequest.text == "保存済み本文。")
    #expect(boundaryRequest.candidates == [])
    #expect(boundaryRequest.next == nil)
    #expect(boundaryRequest.source.segmentID == "final")
    #expect(boundaryRequest.source.segmentationRunID == before.state.runs.segmentation)
    #expect(boundaryRequest.source.asrRunID == before.state.runs.asr)
    // Terminal boundary F inference and priority run once; retry carries results without sending.
    let usage = await counter.snapshot()
    #expect(usage.sendCount == 2)
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage == usageBeforeRetry)
    #expect(await fixture.asr.callCount == 1)
}

@Test
func nativeRetryWithoutTargetsOrUnpublishedRunFailsAndRetainsPublishedSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["再試行対象のない本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let finalized = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    #expect(finalized.disposition == .completed)
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    #expect(try fixture.stored().pendingDecisions.pendingTargets.isEmpty)
    let lines = try SessionRecovery.recoverJSONL(
        Data(contentsOf: SessionLayout(sessionURL: fixture.sessionURL).eventsURL)
    ).lines
    let hasUnpublishedRun = try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: lines, sessionID: fixture.sessionID)
    #expect(!hasUnpublishedRun)
    let publishedRows = try fixture.rows()

    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()
    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: [], onStatus: { _ in },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let expectedMessage = "発話文の判定を再試行できませんでした: 判定の再試行対象がありません"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}

@Test
func nativeRetryWithoutContentPriorityFailsAndRetainsPublishedSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let provider = NativeClauseProvider(holdPriorityNumber: nil, failedPriorityNumbers: [1])
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let fixture = try await NativeDecisionFixture(texts: ["判定保留中の本文。"], factory: { decisions }, counter: counter)
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { _ in }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    let pending = try fixture.stored().pendingDecisions.clauses
    #expect(pending.count == 1)
    let publishedRows = try fixture.rows()
    let disabledProcessor = NativeSessionProcessor(
        paths: fixture.paths,
        engines: SessionProcessingEngines(
            asr: fixture.asr, finalTranscriptVAD: LiveProcessorFinalVAD()
        ),
        audioHandling: RecordingTestAudioHandling(), contentPriority: .disabled, sleep: { _ in }
    )
    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()

    let result = await disabledProcessor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: [], clauses: pending, onStatus: { _ in },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let expectedMessage = "発話文の判定を再試行できませんでした: 判定エンジンが利用できません"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}

@Test
func nativeRetryCoordinatorInitializationFailurePreservesDeferredEngineStatusAndSnapshot() async throws {
    let counter = DecisionUsageCounter()
    let fixture = try await NativeDecisionFixture(
        texts: ["判定エンジン初期化待ちの本文."], factory: { throw NativeDecisionRetryInitializationFailure() },
        counter: counter
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let statuses = ProcessingStatusRecorder()

    _ = await fixture.processor.processSession(
        sessionID: fixture.sessionID, pacingMode: .normal, shouldPause: { _ in nil }, onPhase: { _ in },
        metadataPolicy: .reject, onStatus: { await statuses.record($0) }, onUpdate: { _, _ in }
    )
    let store = ProcessingMetadataStore(sessionURL: fixture.sessionURL)
    let before = try #require(try store.load())
    let pendingBoundary = try fixture.stored().pendingDecisions.boundarySegments
    #expect(!pendingBoundary.isEmpty)
    let publishedRows = try fixture.rows()
    await statuses.reset()
    let updates = LiveUpdateRecorder()
    let updateStates = ProcessingStateRecorder()

    let result = await fixture.processor.retryContentPrioritySession(
        sessionID: fixture.sessionID, boundarySegments: pendingBoundary, clauses: [],
        onStatus: { await statuses.record($0) },
        onUpdate: { rows, state in
            await updates.record(rows)
            await updateStates.record(state)
        }
    )

    let engineFailure = "判定エンジンを初期化できませんでした: テスト初期化エラー"
    let expectedMessage = "発話文の判定を再試行できませんでした: \(engineFailure)"
    let expectedDeferredStatus = "\(UserFacingStatus.decisionDeferred.text)。\(engineFailure)"
    #expect(result.disposition == .failed)
    #expect(result.message == expectedMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(await statuses.statuses == [.message(expectedDeferredStatus)])
    #expect(try store.load() == before)
    #expect(try fixture.rows() == publishedRows)
    #expect(await updates.snapshot().isEmpty)
    let retryUpdateStates = await updateStates.snapshot()
    #expect(retryUpdateStates.isEmpty)
    #expect(!retryUpdateStates.contains(.complete))
}
