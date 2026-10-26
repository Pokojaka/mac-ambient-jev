import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevPipeline

private final class FinishOrderLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ event: String) { storage.withLock { $0.append(event) } }
    var events: [String] { storage.withLock { $0 } }
}
@MainActor
private final class PollStartedSignal {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        precondition(!started, "Polling sleep starts once")
        started = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
    func wait() async {
        if started { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }
}
private struct FinishTestError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
private enum CaptureStopPlan: Sendable {
    case succeed(AudioCaptureStopResult)
    case fail(String)
}
private enum VADFinishPlan: Sendable {
    case succeed(LiveVADProgress)
    case cancelled
}

@MainActor
private final class RecordingFinishEffectsFake: RecordingFinishEffects, LiveTranscriptionEffects, SessionProcessingEffects {
    var processingQueue = SessionProcessingQueue() {
        didSet {
            guard processingQueue.pending.count > oldValue.pending.count,
                  let request = processingQueue.pending.last else { return }
            switch request {
            case .finishLive(_, let checkpoint):
                orderLog.append("enqueue.finishLive:\(checkpoint.committedFrames)")
            case .finalize(_, let policy):
                precondition(policy == .reject, "Recording finish finalization must reject unreadable metadata")
                orderLog.append("enqueue.finalize.reject")
            case .retryContentPriority:
                preconditionFailure("Unexpected retry request")
            }
        }
    }
    let pausesProcessing = true
    private let sessionID: UUID
    var recordingSessionID: UUID? { sessionID }
    private let state: LiveTranscriptionState
    private let stopPlan: CaptureStopPlan
    private let orderLog: FinishOrderLog
    private(set) var outcomes: [RecordingFinishOutcome] = []
    private(set) var pendingSegmentsAtFinish: [Int] = []
    private(set) var stoppedDropoutCounts: [UInt64] = []
    private(set) var refreshCount = 0
    private(set) var idleReleaseCount = 0
    init(state: LiveTranscriptionState, sessionID: UUID, stopPlan: CaptureStopPlan, orderLog: FinishOrderLog) {
        self.state = state; self.sessionID = sessionID
        self.stopPlan = stopPlan; self.orderLog = orderLog
    }
    func stopCapture() async throws -> AudioCaptureStopResult {
        orderLog.append("capture.stop")
        switch stopPlan {
        case .succeed(let result): return result
        case .fail(let message): throw FinishTestError(message: message)
        }
    }
    func captureStopped(dropoutCount: UInt64) {
        stoppedDropoutCounts.append(dropoutCount)
        orderLog.append("capture.stopped:\(dropoutCount)")
    }
    func recordingDidFinish(_ outcome: RecordingFinishOutcome) {
        outcomes.append(outcome)
        pendingSegmentsAtFinish.append(state.pendingSegmentCount(sessionID: sessionID))
        switch outcome {
        case .saved: orderLog.append("finish.saved")
        case .failed: orderLog.append("finish.failed")
        }
    }
    func refreshSavedSessions() {
        refreshCount += 1
        orderLog.append("refresh")
    }
    func releaseIdleResourcesIfIdle() {
        idleReleaseCount += 1
        orderLog.append("releaseIdle")
    }
    func isCurrentRecording(_ sessionID: UUID) -> Bool { self.sessionID == sessionID }
    func committedLiveCheckpoint() async throws -> AudioCheckpoint {
        preconditionFailure("Polling is cancelled before requesting a checkpoint")
    }
    func awaitIdleRelease() async {
        preconditionFailure("No live queue drain is expected in a recording-finish test")
    }
    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler { preconditionFailure("Unexpected live processing status handler") }
    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler { preconditionFailure("Unexpected live processing update handler") }
    func liveDidChange(_ event: LiveTranscriptionEvent) {
        guard case .started = event else {
            preconditionFailure("Unexpected live-transcription event: \(event)")
        }
        orderLog.append("live.started")
    }
    func prepareASRModel() { preconditionFailure("Paused processing must not prepare an ASR model") }
    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        preconditionFailure("Paused processing must not request a status handler")
    }
    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        preconditionFailure("Paused processing must not request an update handler")
    }
    func waitForLiveASRDrain(sessionID: UUID) async { preconditionFailure("Paused processing must not drain") }
    func liveASRFailure(sessionID: UUID) -> String? { preconditionFailure("Paused processing must not inspect ASR state") }
    func cleanupLiveASRState(sessionID: UUID) { preconditionFailure("Paused processing must not clean up ASR state") }
    func autoExportIfEnabled(sessionID: UUID) async { preconditionFailure("Paused processing must not export") }
    func processingDidChange(_ event: SessionProcessingEvent) { preconditionFailure("Paused processing must not change state") }
}
private actor FinishTestExecutor: LiveTranscriptionExecuting, SessionProcessingExecuting {
    private let state: LiveTranscriptionState
    private let sessionID: UUID
    private let orderLog: FinishOrderLog
    private var startCount = 0
    private var cancelCount = 0
    init(state: LiveTranscriptionState, sessionID: UUID, orderLog: FinishOrderLog) {
        self.state = state
        self.sessionID = sessionID
        self.orderLog = orderLog
    }
    func startLiveTranscription(sessionID: UUID, segmentationRunID: String, sampleRate: Double) async throws -> String {
        _ = (sessionID, segmentationRunID, sampleRate)
        startCount += 1
        orderLog.append("live.start")
        return "finish-test-asr-run"
    }
    func registerLiveSegments(sessionID: UUID, segments: [SegmentReference]) async throws -> LiveASRProgress {
        _ = (sessionID, segments)
        preconditionFailure("VAD finish emits no live segments in these tests")
    }
    func processLiveSegments(
        sessionID: UUID, segments: [SegmentReference], checkpoint: AudioCheckpoint,
        onStatus: NativeSessionProcessor.StatusHandler?, onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress {
        _ = (sessionID, segments, checkpoint, onStatus, onUpdate)
        preconditionFailure("Unexpected live model work")
    }
    func cancelLiveTranscription(sessionID: UUID) async {
        _ = sessionID
        cancelCount += 1
        let state = self.state
        let id = self.sessionID
        let (queueWasClean, vadWasReset) = await MainActor.run {
            (
                state.pendingSegmentCount(sessionID: id) == 0 && state.failure(sessionID: id) == nil,
                state.vadFailureText == nil && state.vadSegmentCount == 0
            )
        }
        let vadStatus = vadWasReset ? "vad-reset" : "vad-retained"
        orderLog.append("live.cancel.\(queueWasClean ? "queue-clean" : "queue-dirty").\(vadStatus)")
    }
    func processSession(
        sessionID: UUID, pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck, onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy, onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        _ = (sessionID, pacingMode, shouldPause, onPhase, metadataPolicy, onStatus, onUpdate)
        preconditionFailure("Paused queue must retain finalization without model work")
    }
    func finishLiveTranscription(
        sessionID: UUID, checkpoint: AudioCheckpoint, finalSegments: [SegmentReference], pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck, onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        onStatus: @escaping NativeSessionProcessor.StatusHandler, onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        _ = (sessionID, checkpoint, finalSegments, pacingMode, shouldPause, onPhase, onStatus, onUpdate)
        preconditionFailure("Paused queue must retain finalization without model work")
    }
    func retryContentPrioritySession(
        sessionID: UUID, boundarySegments: [SegmentTextReference], clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler, onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        _ = (sessionID, boundarySegments, clauses, onStatus, onUpdate)
        preconditionFailure("Unexpected content-priority retry")
    }
    func counts() -> (starts: Int, cancellations: Int) { (startCount, cancelCount) }
}
private actor FinishTestVAD: LiveVADProcessing {
    nonisolated let segmentationRunID = "finish-test-segmentation"
    private let plan: VADFinishPlan
    private let orderLog: FinishOrderLog
    private var finishCheckpoints: [AudioCheckpoint] = []
    init(plan: VADFinishPlan, orderLog: FinishOrderLog) {
        self.plan = plan
        self.orderLog = orderLog
    }
    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        _ = checkpoint
        preconditionFailure("VAD polling is cancelled before processing")
    }
    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        finishCheckpoints.append(checkpoint)
        orderLog.append("vad.finish:\(checkpoint.committedFrames)")
        switch plan {
        case .succeed(let progress): return progress
        case .cancelled: throw CancellationError()
        }
    }
    func finishedCheckpoints() -> [AudioCheckpoint] { finishCheckpoints }
}
private struct NominalFinishThermalMonitor: ThermalMonitoring, Sendable {
    var isCritical: Bool { false }
    var liveASRDecision: LiveASRThermalDecision { .processNow }
    @MainActor
    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any ThermalStateObservation {
        _ = onChange
        return NominalFinishThermalObservation()
    }
}
private final class NominalFinishThermalObservation: ThermalStateObservation {}

@MainActor
private struct RecordingFinishFixture {
    let state: LiveTranscriptionState
    let effects: RecordingFinishEffectsFake
    let executor: FinishTestExecutor
    let vad: FinishTestVAD
    let coordinator: LiveTranscriptionCoordinator
    let processing: SessionProcessingCoordinator
    let orderLog: FinishOrderLog
    private let pollStarted: PollStartedSignal
    private let sessionID: UUID
    private let checkpoint: AudioCheckpoint
    init(sessionID: UUID, checkpoint: AudioCheckpoint, stopPlan: CaptureStopPlan, vadPlan: VADFinishPlan) {
        self.sessionID = sessionID
        self.checkpoint = checkpoint
        let state = LiveTranscriptionState(), orderLog = FinishOrderLog()
        state.begin(sessionID: sessionID)
        let effects = RecordingFinishEffectsFake(state: state, sessionID: sessionID, stopPlan: stopPlan, orderLog: orderLog)
        let executor = FinishTestExecutor(state: state, sessionID: sessionID, orderLog: orderLog)
        let vad = FinishTestVAD(plan: vadPlan, orderLog: orderLog)
        let pollStarted = PollStartedSignal(), thermal = NominalFinishThermalMonitor()
        self.state = state; self.effects = effects; self.executor = executor
        self.vad = vad; self.orderLog = orderLog; self.pollStarted = pollStarted
        coordinator = LiveTranscriptionCoordinator(state: state, effects: effects, processor: executor, thermalMonitor: thermal) { _ in
            orderLog.append("poll.entered")
            pollStarted.signal()
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch { orderLog.append("poll.cancelled"); throw error }
        }
        processing = SessionProcessingCoordinator(effects: effects, processor: executor, thermalMonitor: thermal)
    }
    func startVAD() async {
        await coordinator.startVAD(sessionID: sessionID, session: vad, checkpoint: checkpoint)
        await pollStarted.wait()
    }
    func finish(failureMessage: String?) async {
        await coordinator.finishRecording(sessionID: sessionID, failureMessage: failureMessage,
                                          processing: processing, effects: effects)
    }
}
private func makeCheckpoint(_ frames: Int64) -> AudioCheckpoint {
    AudioCheckpoint(committedFrames: frames, sampleRate: 16_000, channelCount: 1,
                    sampleFormat: .float32LE, chunkFiles: [], chunkFrameCounts: [], gapEvents: [])
}
private func makeStopResult(
    checkpoint: AudioCheckpoint,
    dropouts: UInt64,
    writerFailure: String?,
    releaseFailure: String?
) -> AudioCaptureStopResult {
    AudioCaptureStopResult(checkpoint: checkpoint, didOverflow: false, dropoutCount: dropouts,
                           gapCount: 0, totalGapFrames: 0, sleepAssertionHeld: false,
                           writerFailure: writerFailure, systemAudioReleaseFailure: releaseFailure)
}
private func makeProgress(count: Int, segments: [SegmentReference]) -> LiveVADProgress {
    LiveVADProgress(emittedSegments: segments, totalSegmentCount: count, committedFrames: 0, micSpeechLevels: [])
}
private func makeSegment(_ id: String) -> SegmentReference {
    SegmentReference(segmentationRunID: "finish-test-segmentation", segmentID: id, startFrame: 0, endFrame: 1)
}

@MainActor
private func makeFixture(
    sessionID: UUID,
    checkpoint: AudioCheckpoint,
    stopPlan: CaptureStopPlan,
    vadPlan: VADFinishPlan
) -> RecordingFinishFixture {
    RecordingFinishFixture(sessionID: sessionID, checkpoint: checkpoint, stopPlan: stopPlan, vadPlan: vadPlan)
}

@MainActor
private func expectQueuedFinishLive(
    _ effects: RecordingFinishEffectsFake, sessionID: UUID, checkpoint: AudioCheckpoint
) throws {
    guard case .finishLive(let queuedID, let queuedCheckpoint) = try #require(effects.processingQueue.pending.first) else {
        #expect(Bool(false), "Saved recording must enqueue finishLive")
        return
    }
    #expect(queuedID == sessionID)
    #expect(queuedCheckpoint == checkpoint)
}

@MainActor
private func expectQueuedFinalize(_ effects: RecordingFinishEffectsFake, sessionID: UUID) throws {
    guard case .finalize(let queuedID, let policy) = try #require(effects.processingQueue.pending.first) else {
        #expect(Bool(false), "Recording failure must enqueue rejected-metadata finalization")
        return
    }
    #expect(queuedID == sessionID)
    #expect(policy == .reject)
}

@MainActor
@Test
func successfulFinishCancelsPollingBeforeVADAndQueuesExactCheckpoint() async throws {
    let sessionID = UUID()
    let checkpoint = makeCheckpoint(32_000)
    let result = makeStopResult(checkpoint: checkpoint, dropouts: 13, writerFailure: nil, releaseFailure: nil)
    let fixture = makeFixture(
        sessionID: sessionID,
        checkpoint: checkpoint,
        stopPlan: .succeed(result),
        vadPlan: .succeed(makeProgress(count: 4, segments: []))
    )
    await fixture.startVAD()
    await fixture.finish(failureMessage: nil)
    #expect(fixture.effects.outcomes == [.saved(
        result: result, failureMessage: nil, vadFailureText: nil, vadSegmentCount: 4
    )])
    #expect(fixture.effects.stoppedDropoutCounts == [13])
    #expect(await fixture.vad.finishedCheckpoints() == [checkpoint])
    #expect(await fixture.executor.counts().starts == 1)
    #expect(await fixture.executor.counts().cancellations == 0)
    #expect(fixture.effects.refreshCount == 0)
    #expect(fixture.effects.idleReleaseCount == 0)
    #expect(fixture.state.vadSegmentCount == 0)
    #expect(fixture.state.vadFailureText == nil)
    #expect(fixture.orderLog.events == [
        "live.started", "live.start", "poll.entered", "capture.stop", "poll.cancelled",
        "capture.stopped:13", "vad.finish:32000", "finish.saved", "enqueue.finishLive:32000"
    ])
    try expectQueuedFinishLive(fixture.effects, sessionID: sessionID, checkpoint: checkpoint)
}

@MainActor
@Test
func writerFailureKeepsDurablePrefixAndOrdersCleanupBeforeRejectFinalization() async throws {
    let checkpoint = makeCheckpoint(48_000)
    for (writerFailure, releaseFailure, expectedFailure) in [
        ("writer failed", "release failed", "writer failed。release failed"),
        ("same failure", "same failure", "same failure")
    ] {
        let sessionID = UUID()
        let result = makeStopResult(checkpoint: checkpoint, dropouts: 7,
                                    writerFailure: writerFailure, releaseFailure: releaseFailure)
        let fixture = makeFixture(
            sessionID: sessionID,
            checkpoint: checkpoint,
            stopPlan: .succeed(result),
            vadPlan: .succeed(makeProgress(count: 4, segments: []))
        )
        await fixture.startVAD()
        fixture.state.enqueue(sessionID: sessionID, segments: [makeSegment("queued")], checkpoint: checkpoint)
        fixture.state.vadFailureText = "stale VAD failure"
        fixture.state.vadSegmentCount = 9
        await fixture.finish(failureMessage: "incoming failure must be ignored")
        #expect(result.checkpoint == checkpoint)
        #expect(fixture.effects.outcomes == [.failed(expectedFailure)])
        #expect(fixture.effects.stoppedDropoutCounts == [7])
        #expect(fixture.effects.pendingSegmentsAtFinish == [0])
        #expect(fixture.effects.refreshCount == 1)
        #expect(await fixture.vad.finishedCheckpoints().isEmpty)
        #expect(await fixture.executor.counts().cancellations == 1)
        #expect(fixture.orderLog.events == [
            "live.started", "live.start", "poll.entered", "capture.stop", "poll.cancelled",
            "capture.stopped:7", "live.cancel.queue-clean.vad-reset", "finish.failed",
            "enqueue.finalize.reject", "refresh"
        ])
        try expectQueuedFinalize(fixture.effects, sessionID: sessionID)
    }
}

@MainActor
@Test
func cancelledVADFinishDiscardsLiveQueueBeforeFullFinalization() async throws {
    let sessionID = UUID()
    let checkpoint = makeCheckpoint(64_000)
    let result = makeStopResult(checkpoint: checkpoint, dropouts: 2, writerFailure: nil, releaseFailure: nil)
    let fixture = makeFixture(
        sessionID: sessionID,
        checkpoint: checkpoint,
        stopPlan: .succeed(result),
        vadPlan: .cancelled
    )
    await fixture.startVAD()
    fixture.state.enqueue(sessionID: sessionID, segments: [makeSegment("discarded")], checkpoint: checkpoint)
    fixture.state.vadSegmentCount = 11
    await fixture.finish(failureMessage: nil)
    let outcome = try #require(fixture.effects.outcomes.first)
    if case .saved(let savedResult, let failureMessage, let vadFailure, let segmentCount) = outcome {
        #expect(savedResult == result)
        #expect(failureMessage == nil)
        #expect(vadFailure != nil)
        #expect(segmentCount == 11)
    } else {
        #expect(Bool(false), "A cancelled VAD finish still represents a saved recording")
    }
    #expect(fixture.effects.outcomes.count == 1)
    #expect(fixture.effects.pendingSegmentsAtFinish == [1])
    #expect(await fixture.vad.finishedCheckpoints() == [checkpoint])
    #expect(fixture.effects.processingQueue.pending.count == 1)
    #expect(await fixture.executor.counts().cancellations == 1)
    #expect(fixture.effects.refreshCount == 0)
    #expect(fixture.orderLog.events == [
        "live.started", "live.start", "poll.entered", "capture.stop", "poll.cancelled",
        "capture.stopped:2", "vad.finish:64000", "finish.saved",
        "live.cancel.queue-clean.vad-retained", "enqueue.finalize.reject"
    ])
    #expect(fixture.state.pendingSegmentCount(sessionID: sessionID) == 0)
    #expect(fixture.state.vadFailureText == nil)
    #expect(fixture.state.vadSegmentCount == 0)
    try expectQueuedFinalize(fixture.effects, sessionID: sessionID)
}

@MainActor
@Test
func captureStopFailureCleansUpAndReleasesIdleResourcesWithConditionalRefresh() async throws {
    let checkpoint = makeCheckpoint(80_000)
    for incoming in [String?.none, "incoming stop failure"] {
        let sessionID = UUID()
        let fixture = makeFixture(
            sessionID: sessionID,
            checkpoint: checkpoint,
            stopPlan: .fail("capture stop failed"),
            vadPlan: .succeed(makeProgress(count: 4, segments: []))
        )
        await fixture.startVAD()
        fixture.state.enqueue(sessionID: sessionID, segments: [makeSegment("discarded")], checkpoint: checkpoint)
        fixture.state.vadSegmentCount = 5
        await fixture.finish(failureMessage: incoming)
        let expectedMessage = incoming.map { "\($0)。capture stop failed" } ?? "capture stop failed"
        #expect(fixture.effects.outcomes == [.failed(expectedMessage)])
        #expect(fixture.effects.pendingSegmentsAtFinish == [0])
        #expect(fixture.effects.stoppedDropoutCounts.isEmpty)
        #expect(fixture.effects.refreshCount == (incoming == nil ? 0 : 1))
        #expect(fixture.effects.idleReleaseCount == 1)
        #expect(fixture.effects.processingQueue.pending.isEmpty)
        #expect(await fixture.vad.finishedCheckpoints().isEmpty)
        #expect(await fixture.executor.counts().cancellations == 1)
        var expectedEvents = [
            "live.started", "live.start", "poll.entered", "capture.stop", "poll.cancelled",
            "live.cancel.queue-clean.vad-reset", "finish.failed"
        ]
        if incoming != nil { expectedEvents.append("refresh") }
        expectedEvents.append("releaseIdle")
        #expect(fixture.orderLog.events == expectedEvents)
    }
}

@MainActor
@Test
func savedReleaseFailureIsDeduplicatedAndRefreshDependsOnIncomingFailure() async throws {
    let checkpoint = makeCheckpoint(96_000)
    let cases: [(String?, String, String, Int)] = [
        ("tap release failed", "tap release failed", "tap release failed", 1),
        (nil, "tap release failed", "tap release failed", 0)
    ]
    for (incoming, releaseFailure, expectedMessage, expectedRefreshCount) in cases {
        let sessionID = UUID()
        let result = makeStopResult(checkpoint: checkpoint, dropouts: 4, writerFailure: nil, releaseFailure: releaseFailure)
        let fixture = makeFixture(
            sessionID: sessionID,
            checkpoint: checkpoint,
            stopPlan: .succeed(result),
            vadPlan: .succeed(makeProgress(count: 4, segments: []))
        )
        await fixture.finish(failureMessage: incoming)
        #expect(fixture.effects.outcomes == [.saved(
            result: result, failureMessage: expectedMessage, vadFailureText: nil, vadSegmentCount: 0
        )])
        #expect(fixture.effects.stoppedDropoutCounts == [4])
        #expect(fixture.effects.refreshCount == expectedRefreshCount)
        #expect(fixture.effects.idleReleaseCount == 0)
        #expect(await fixture.executor.counts().cancellations == 0)
        var expectedEvents = ["capture.stop", "capture.stopped:4", "finish.saved", "enqueue.finishLive:96000"]
        if incoming != nil { expectedEvents.append("refresh") }
        #expect(fixture.orderLog.events == expectedEvents)
        try expectQueuedFinishLive(fixture.effects, sessionID: sessionID, checkpoint: checkpoint)
    }
}

@MainActor
@Test
func prefailedLiveASRStillQueuesFinishLiveForProcessingCoordinator() async throws {
    let sessionID = UUID()
    let checkpoint = makeCheckpoint(112_000)
    let result = makeStopResult(checkpoint: checkpoint, dropouts: 0, writerFailure: nil, releaseFailure: nil)
    let fixture = makeFixture(
        sessionID: sessionID,
        checkpoint: checkpoint,
        stopPlan: .succeed(result),
        vadPlan: .succeed(makeProgress(count: 4, segments: []))
    )
    fixture.state.recordFailure(sessionID: sessionID, message: "live ASR failed", discardQueued: true)
    await fixture.startVAD()
    await fixture.finish(failureMessage: nil)
    #expect(fixture.effects.outcomes == [.saved(
        result: result, failureMessage: nil, vadFailureText: nil, vadSegmentCount: 4
    )])
    #expect(fixture.state.failure(sessionID: sessionID) == "live ASR failed")
    #expect(await fixture.executor.counts().cancellations == 0)
    #expect(fixture.orderLog.events == [
        "live.started", "live.start", "poll.entered", "capture.stop", "poll.cancelled",
        "capture.stopped:0", "vad.finish:112000", "finish.saved", "enqueue.finishLive:112000"
    ])
    try expectQueuedFinishLive(fixture.effects, sessionID: sessionID, checkpoint: checkpoint)
}
