import Foundation
import Testing
import Synchronization
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevCore

private struct RecordedLiveASRBatch: Sendable, Equatable {
    let segments: [SegmentReference]
    let checkpoint: AudioCheckpoint
}

private enum FakeExecutorError: LocalizedError, Sendable {
    case registration(String)
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .registration(let message), .processing(let message): message
        }
    }
}

private actor OneShotAsyncGate {
    private var entered = false
    private var released = false
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        precondition(!entered, "待機ゲートは一度だけ使用できます")
        entered = true
        let waiters = enteredWaiters
        enteredWaiters = []
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                waitContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        precondition(entered && !released, "待機中のゲートだけを解除できます")
        released = true
        waitContinuation?.resume()
        waitContinuation = nil
    }
}

@MainActor
private final class OneShotAsyncSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        precondition(!signalled, "シグナルは一度だけ通知できます")
        signalled = true
        let pendingWaiters = waiters
        waiters = []
        pendingWaiters.forEach { $0.resume() }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class SharedCoordinatorOrderLog: Sendable {
    private let storage: Mutex<[String]>

    init() {
        storage = Mutex([])
    }

    func append(_ value: String) {
        storage.withLock { $0.append(value) }
    }

    var values: [String] {
        storage.withLock { $0 }
    }
}

private final class CoordinatorSleepLog: Sendable {
    private let storage: Mutex<[Duration]>

    init() {
        storage = Mutex([])
    }

    func append(_ duration: Duration) {
        storage.withLock { $0.append(duration) }
    }

    var durations: [Duration] {
        storage.withLock { $0 }
    }
}

private final class CoordinatorThermalMonitor: ThermalMonitoring, Sendable {
    private let pressureStorage: Mutex<ThermalPressure>

    init(pressure: ThermalPressure) {
        pressureStorage = Mutex(pressure)
    }

    var pressure: ThermalPressure {
        pressureStorage.withLock { $0 }
    }

    func setPressure(_ pressure: ThermalPressure) {
        pressureStorage.withLock { $0 = pressure }
    }

    var isCritical: Bool { pressure == .critical }

    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }
}

private enum RegistrationStep: Sendable {
    case succeed
    case fail(String)
    case suspend(OneShotAsyncGate)
}

private enum ProcessingOutcome: Sendable {
    case succeed
    case fail(String)
}

private enum ProcessingStep: Sendable {
    case succeed
    case fail(String)
    case suspend(OneShotAsyncGate, outcome: ProcessingOutcome)
}

private enum ProcessingCompletion: Sendable, Equatable {
    case succeeded(taskWasCancelled: Bool)
    case failed(String, taskWasCancelled: Bool)
}

private actor FakeLiveTranscriptionExecutor: LiveTranscriptionExecuting {
    private let startRunID: String
    private let orderLog: SharedCoordinatorOrderLog
    private var registrationScript: [RegistrationStep]
    private var processingScript: [ProcessingStep]
    private var registeredBatches: [[SegmentReference]] = []
    private var processedBatches: [RecordedLiveASRBatch] = []
    private var processingCompletions: [ProcessingCompletion] = []
    private var completionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var startCount = 0
    private var cancellationCount = 0

    init(
        startRunID: String,
        registrationScript: [RegistrationStep],
        processingScript: [ProcessingStep],
        orderLog: SharedCoordinatorOrderLog
    ) {
        self.startRunID = startRunID
        self.registrationScript = registrationScript
        self.processingScript = processingScript
        self.orderLog = orderLog
    }

    func startLiveTranscription(
        sessionID: UUID,
        segmentationRunID: String,
        sampleRate: Double
    ) async throws -> String {
        _ = sessionID
        _ = segmentationRunID
        _ = sampleRate
        startCount += 1
        return startRunID
    }

    func registerLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference]
    ) async throws -> LiveASRProgress {
        _ = sessionID
        guard !registrationScript.isEmpty else {
            preconditionFailure("ライブ区間登録の結果スクリプトが尽きました")
        }
        let step = registrationScript.removeFirst()
        registeredBatches.append(segments)
        orderLog.append("register")

        switch step {
        case .succeed:
            return Self.emptyProgress()
        case .fail(let message):
            throw FakeExecutorError.registration(message)
        case .suspend(let gate):
            await gate.wait()
            return Self.emptyProgress()
        }
    }

    func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onStatus: NativeSessionProcessor.StatusHandler?,
        onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress {
        _ = sessionID
        _ = onStatus
        _ = onUpdate
        guard !processingScript.isEmpty else {
            preconditionFailure("ライブ文字起こしの結果スクリプトが尽きました")
        }
        let step = processingScript.removeFirst()
        processedBatches.append(RecordedLiveASRBatch(segments: segments, checkpoint: checkpoint))
        orderLog.append("process")

        switch step {
        case .succeed:
            recordCompletion(.succeeded(taskWasCancelled: Task.isCancelled))
            return Self.emptyProgress()
        case .fail(let message):
            recordCompletion(.failed(message, taskWasCancelled: Task.isCancelled))
            throw FakeExecutorError.processing(message)
        case .suspend(let gate, let outcome):
            await gate.wait()
            switch outcome {
            case .succeed:
                recordCompletion(.succeeded(taskWasCancelled: Task.isCancelled))
                return Self.emptyProgress()
            case .fail(let message):
                recordCompletion(.failed(message, taskWasCancelled: Task.isCancelled))
                throw FakeExecutorError.processing(message)
            }
        }
    }

    func cancelLiveTranscription(sessionID: UUID) async {
        _ = sessionID
        cancellationCount += 1
    }

    func registrations() -> [[SegmentReference]] { registeredBatches }
    func processingRecords() -> [RecordedLiveASRBatch] { processedBatches }
    func processingResults() -> [ProcessingCompletion] { processingCompletions }

    func waitForCompletions(_ count: Int) async {
        guard processingCompletions.count < count else { return }
        await withCheckedContinuation { completionWaiters.append((count, $0)) }
    }

    private func recordCompletion(_ completion: ProcessingCompletion) {
        processingCompletions.append(completion)
        let ready = completionWaiters.filter { $0.count <= processingCompletions.count }
        completionWaiters.removeAll { $0.count <= processingCompletions.count }
        ready.forEach { $0.continuation.resume() }
    }
    func startCalls() -> Int { startCount }
    func cancellationCalls() -> Int { cancellationCount }

    private static func emptyProgress() -> LiveASRProgress {
        LiveASRProgress(
            materializedSegments: [],
            completedCount: 0,
            failedCount: 0,
            pendingCount: 0
        )
    }
}

private actor FakeLiveVAD: LiveVADProcessing {
    nonisolated let segmentationRunID: String
    private var processScript: [LiveVADProgress]
    private var finishScript: [LiveVADProgress]
    private var processCalls = 0
    private var finishCalls = 0

    init(
        segmentationRunID: String,
        processScript: [LiveVADProgress],
        finishScript: [LiveVADProgress]
    ) {
        self.segmentationRunID = segmentationRunID
        self.processScript = processScript
        self.finishScript = finishScript
    }

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        _ = checkpoint
        guard !processScript.isEmpty else {
            preconditionFailure("VAD ポーリング結果のスクリプトが尽きました")
        }
        processCalls += 1
        return processScript.removeFirst()
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        _ = checkpoint
        guard !finishScript.isEmpty else {
            preconditionFailure("VAD 完了結果のスクリプトが尽きました")
        }
        finishCalls += 1
        return finishScript.removeFirst()
    }

    func callCounts() -> (process: Int, finish: Int) {
        (processCalls, finishCalls)
    }
}

@MainActor
private final class FakeLiveTranscriptionEffects: LiveTranscriptionEffects {
    var recordingSessionID: UUID?
    private let checkpoint: AudioCheckpoint
    private let orderLog: SharedCoordinatorOrderLog
    private let stopsRecordingOnVADEnqueue: Bool
    private var idleReleaseGate: OneShotAsyncGate?
    private(set) var events: [LiveTranscriptionEvent] = []
    private(set) var committedCheckpoints: [AudioCheckpoint] = []
    private var eventWaiters: [(LiveTranscriptionEvent, CheckedContinuation<Void, Never>)] = []

    init(
        recordingSessionID: UUID?,
        checkpoint: AudioCheckpoint,
        orderLog: SharedCoordinatorOrderLog,
        stopsRecordingOnVADEnqueue: Bool
    ) {
        self.recordingSessionID = recordingSessionID
        self.checkpoint = checkpoint
        self.orderLog = orderLog
        self.stopsRecordingOnVADEnqueue = stopsRecordingOnVADEnqueue
    }

    func isCurrentRecording(_ sessionID: UUID) -> Bool {
        recordingSessionID == sessionID
    }

    func committedLiveCheckpoint() async throws -> AudioCheckpoint {
        committedCheckpoints.append(checkpoint)
        return checkpoint
    }

    func suspendNextDrainAtIdleRelease(using gate: OneShotAsyncGate) {
        precondition(idleReleaseGate == nil, "アイドル解放ゲートは一つだけ設定できます")
        idleReleaseGate = gate
    }

    func awaitIdleRelease() async {
        guard let gate = idleReleaseGate else { return }
        idleReleaseGate = nil
        await gate.wait()
    }

    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        _ = sessionID
        return { _ in }
    }

    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        _ = sessionID
        return { _, _ in }
    }

    func liveDidChange(_ event: LiveTranscriptionEvent) {
        events.append(event)
        switch event {
        case .vadProgress:
            orderLog.append("vadProgress")
        case .vadSegmentsEnqueued:
            orderLog.append("vadSegmentsEnqueued")
            if stopsRecordingOnVADEnqueue {
                recordingSessionID = nil
            }
        case .started:
            orderLog.append("started")
        case .startFailed, .registrationFailed, .recognitionFailed, .thermal, .vadFailed:
            orderLog.append("otherEvent")
        }

        var remaining: [(LiveTranscriptionEvent, CheckedContinuation<Void, Never>)] = []
        for (expectedEvent, continuation) in eventWaiters {
            if expectedEvent == event {
                continuation.resume()
            } else {
                remaining.append((expectedEvent, continuation))
            }
        }
        eventWaiters = remaining
    }

    func waitForEvent(_ event: LiveTranscriptionEvent) async {
        if events.contains(event) { return }
        await withCheckedContinuation { continuation in
            eventWaiters.append((event, continuation))
        }
    }
}

private func makeCheckpoint(_ committedFrames: Int64) -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: committedFrames,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: [],
        chunkFrameCounts: [],
        gapEvents: []
    )
}

private func makeSegment(_ segmentID: String, at startFrame: Int64) -> SegmentReference {
    SegmentReference(
        segmentationRunID: "seg_coordinator_test",
        segmentID: segmentID,
        startFrame: startFrame,
        endFrame: startFrame + 1
    )
}

@MainActor
@Test
func criticalLiveDrainWaitsWithoutDequeueThenResumesFIFOUsingLatestCheckpoint() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(200)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_critical_test",
        registrationScript: [.succeed, .succeed],
        processingScript: [.succeed, .succeed],
        orderLog: orderLog
    )
    let thermal = CoordinatorThermalMonitor(pressure: .critical)
    let sleepGate = OneShotAsyncGate()
    let sleepLog = CoordinatorSleepLog()
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: thermal,
        sleep: { duration in
            sleepLog.append(duration)
            await sleepGate.wait()
        }
    )
    let firstBatch = [makeSegment("seg_critical_1", at: 0)]
    let secondBatch = [makeSegment("seg_critical_2", at: 1)]

    await coordinator.enqueue(
        sessionID: sessionID,
        segments: firstBatch,
        checkpoint: makeCheckpoint(100)
    )
    await coordinator.enqueue(
        sessionID: sessionID,
        segments: secondBatch,
        checkpoint: checkpoint
    )
    await sleepGate.waitUntilEntered()

    #expect(await processor.processingRecords().isEmpty)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 2)
    #expect(!coordinator.isASRIdle)
    #expect(sleepLog.durations == [.milliseconds(LiveTranscriptionCadence.thermalRecheckIntervalMilliseconds)])
    #expect(effects.events.contains { event in
        if case .thermal(let eventSessionID, _) = event {
            return eventSessionID == sessionID
        }
        return false
    })

    thermal.setPressure(.fair)
    await sleepGate.release()
    await coordinator.waitForDrain(sessionID: sessionID)

    let records = await processor.processingRecords()
    #expect(records.map { $0.segments } == [firstBatch, secondBatch])
    #expect(records.map { $0.checkpoint } == [checkpoint, checkpoint])
    #expect(coordinator.isASRIdle)
}

@MainActor
@Test
func seriousLiveDrainWaitsOnceFor750Milliseconds() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(300)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_serious_test",
        registrationScript: [.succeed],
        processingScript: [.succeed],
        orderLog: orderLog
    )
    let thermal = CoordinatorThermalMonitor(pressure: .serious)
    let sleepGate = OneShotAsyncGate()
    let sleepLog = CoordinatorSleepLog()
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: thermal,
        sleep: { duration in
            sleepLog.append(duration)
            await sleepGate.wait()
        }
    )
    let batch = [makeSegment("seg_serious_1", at: 0)]

    await coordinator.enqueue(sessionID: sessionID, segments: batch, checkpoint: checkpoint)
    await sleepGate.waitUntilEntered()

    #expect(sleepLog.durations == [.milliseconds(750)])
    #expect(await processor.processingRecords().isEmpty)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 1)

    await sleepGate.release()
    await coordinator.waitForDrain(sessionID: sessionID)

    #expect(await processor.processingRecords() == [RecordedLiveASRBatch(segments: batch, checkpoint: checkpoint)])
    #expect(sleepLog.durations == [.milliseconds(750)])
    #expect(coordinator.isASRIdle)
}

@MainActor
@Test
func failureDuringRegistrationDoesNotResurrectDroppedBacklog() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    state.begin(sessionID: sessionID)
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(400)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let registrationGate = OneShotAsyncGate()
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_registration_race_test",
        registrationScript: [.suspend(registrationGate)],
        processingScript: [],
        orderLog: orderLog
    )
    let thermal = CoordinatorThermalMonitor(pressure: .nominal)
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: thermal,
        sleep: { _ in preconditionFailure("登録競合テストで待機してはいけません") }
    )
    let enqueue = Task {
        await coordinator.enqueue(
            sessionID: sessionID,
            segments: [makeSegment("seg_registration_race", at: 0)],
            checkpoint: checkpoint
        )
    }

    await registrationGate.waitUntilEntered()
    state.recordFailure(sessionID: sessionID, message: "先行する ASR 失敗", discardQueued: true)
    await registrationGate.release()
    await enqueue.value

    #expect(state.failure(sessionID: sessionID) == "先行する ASR 失敗")
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
    #expect(state.pendingSegmentCount(sessionID: sessionID) == 0)
    #expect(await processor.processingRecords().isEmpty)
    #expect(await processor.registrations() == [[makeSegment("seg_registration_race", at: 0)]])
    #expect(!coordinator.isDraining(sessionID: sessionID))
    #expect(coordinator.isASRIdle)

    let retainedSessionID = UUID()
    let retainedState = LiveTranscriptionState()
    let retainedBatch = [makeSegment("seg_retained_backlog", at: 10)]
    retainedState.enqueue(
        sessionID: retainedSessionID,
        segments: retainedBatch,
        checkpoint: makeCheckpoint(500)
    )
    let retainedOrderLog = SharedCoordinatorOrderLog()
    let retainedEffects = FakeLiveTranscriptionEffects(
        recordingSessionID: retainedSessionID,
        checkpoint: makeCheckpoint(600),
        orderLog: retainedOrderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let retainedProcessor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_registration_failure_test",
        registrationScript: [.fail("登録の永続化に失敗")],
        processingScript: [],
        orderLog: retainedOrderLog
    )
    let retainedCoordinator = LiveTranscriptionCoordinator(
        state: retainedState,
        effects: retainedEffects,
        processor: retainedProcessor,
        thermalMonitor: CoordinatorThermalMonitor(pressure: .nominal),
        sleep: { _ in preconditionFailure("登録失敗テストで待機してはいけません") }
    )

    await retainedCoordinator.enqueue(
        sessionID: retainedSessionID,
        segments: [makeSegment("seg_failed_registration", at: 20)],
        checkpoint: makeCheckpoint(600)
    )

    #expect(retainedState.failure(sessionID: retainedSessionID) == "登録の永続化に失敗")
    #expect(retainedState.queuedBatchCount(sessionID: retainedSessionID) == 1)
    #expect(retainedState.pendingSegmentCount(sessionID: retainedSessionID) == 1)
    #expect(!retainedCoordinator.isASRIdle)
    #expect(!retainedCoordinator.isDraining(sessionID: retainedSessionID))

    retainedCoordinator.cleanup(sessionID: retainedSessionID)

    #expect(retainedState.failure(sessionID: retainedSessionID) == nil)
    #expect(retainedState.queuedBatchCount(sessionID: retainedSessionID) == 0)
    #expect(retainedCoordinator.isASRIdle)
}

@MainActor
@Test
func pollingDeliversMicProgressBeforeASREnqueueAndStopOwnsPolling() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(700)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: true
    )
    let segment = makeSegment("seg_vad_poll", at: 0)
    let micLevel = MicLevelWindow(
        startSeconds: 0,
        endSeconds: 0.25,
        speechSeconds: 0.25,
        speechMeanSquare: 0.04,
        speechPeak: 0.5,
        inputPeak: 0.6,
        clippedFraction: 0
    )
    let progress = LiveVADProgress(
        emittedSegments: [segment],
        totalSegmentCount: 7,
        committedFrames: checkpoint.committedFrames,
        micSpeechLevels: [micLevel]
    )
    let finishProgress = LiveVADProgress(
        emittedSegments: [],
        totalSegmentCount: 7,
        committedFrames: checkpoint.committedFrames,
        micSpeechLevels: []
    )
    let vad = FakeLiveVAD(
        segmentationRunID: "seg_coordinator_test",
        processScript: [progress],
        finishScript: [finishProgress]
    )
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_vad_poll_test",
        registrationScript: [.succeed],
        processingScript: [.succeed],
        orderLog: orderLog
    )
    let pollGate = OneShotAsyncGate()
    let sleepLog = CoordinatorSleepLog()
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorThermalMonitor(pressure: .nominal),
        sleep: { duration in
            sleepLog.append(duration)
            await pollGate.wait()
        }
    )

    await coordinator.startVAD(sessionID: sessionID, session: vad, checkpoint: checkpoint)
    await pollGate.waitUntilEntered()
    #expect(await processor.startCalls() == 1)
    #expect(sleepLog.durations == [.milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)])

    await pollGate.release()
    await effects.waitForEvent(.vadSegmentsEnqueued(sessionID, 7))
    #expect(effects.recordingSessionID == nil)
    #expect(progress.emittedSegments.count == 1)
    #expect(effects.events.contains(.vadProgress(sessionID, progress)))
    #expect(effects.events.contains(.vadSegmentsEnqueued(sessionID, 7)))
    #expect(effects.committedCheckpoints == [checkpoint])

    await coordinator.stopVADPolling()
    await coordinator.waitForDrain(sessionID: sessionID)
    #expect(state.vadSegmentCount == 7)
    #expect(await vad.callCounts().process == 1)
    #expect(sleepLog.durations == [.milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)])
    let progressPosition = try #require(orderLog.values.firstIndex(of: "vadProgress"))
    let registrationPosition = try #require(orderLog.values.firstIndex(of: "register"))
    #expect(progressPosition < registrationPosition)
    #expect(await processor.registrations() == [[segment]])

    await coordinator.finishVAD(sessionID: sessionID, checkpoint: checkpoint)
    #expect(await vad.callCounts().finish == 1)
    #expect(state.vadSegmentCount == 7)

    state.vadFailureText = "一時的な VAD 状態"
    coordinator.resetVAD()
    #expect(state.vadSegmentCount == 0)
    #expect(state.vadFailureText == nil)
    #expect(sleepLog.durations == [.milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)])
}

@MainActor
@Test
func cleanupAllowsInFlightProcessingToSucceedWithoutCancellation() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(800)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let processingGate = OneShotAsyncGate()
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_cleanup_success_test",
        registrationScript: [.succeed],
        processingScript: [.suspend(processingGate, outcome: .succeed)],
        orderLog: orderLog
    )
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorThermalMonitor(pressure: .nominal),
        sleep: { _ in preconditionFailure("成功処理テストで待機してはいけません") }
    )
    let batch = [makeSegment("seg_cleanup_success", at: 0)]

    await coordinator.enqueue(sessionID: sessionID, segments: batch, checkpoint: checkpoint)
    await processingGate.waitUntilEntered()

    let waiterStarted = OneShotAsyncSignal()
    let drainWaiter = Task { @MainActor in
        waiterStarted.signal()
        await coordinator.waitForDrain(sessionID: sessionID)
    }
    await waiterStarted.wait()
    coordinator.cleanup(sessionID: sessionID)

    #expect(!coordinator.isDraining(sessionID: sessionID))
    #expect(state.failure(sessionID: sessionID) == nil)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
    #expect(!(await processor.processingRecords()).isEmpty)
    #expect(coordinator.isASRIdle)

    await processingGate.release()
    await drainWaiter.value

    #expect(await processor.processingRecords() == [
        RecordedLiveASRBatch(segments: batch, checkpoint: checkpoint)
    ])
    #expect(await processor.processingResults() == [.succeeded(taskWasCancelled: false)])
    #expect(state.failure(sessionID: sessionID) == nil)
    #expect(!effects.events.contains { event in
        if case .recognitionFailed(let eventSessionID, _) = event {
            return eventSessionID == sessionID
        }
        return false
    })
}

@MainActor
@Test
func cleanupSuppressesFailureFromInFlightProcessing() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(900)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let processingGate = OneShotAsyncGate()
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_cleanup_failure_test",
        registrationScript: [.succeed],
        processingScript: [.suspend(processingGate, outcome: .fail("遅れて到着した認識失敗"))],
        orderLog: orderLog
    )
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorThermalMonitor(pressure: .nominal),
        sleep: { _ in preconditionFailure("失敗処理テストで待機してはいけません") }
    )
    let batch = [makeSegment("seg_cleanup_failure", at: 0)]

    await coordinator.enqueue(sessionID: sessionID, segments: batch, checkpoint: checkpoint)
    await processingGate.waitUntilEntered()

    let waiterStarted = OneShotAsyncSignal()
    let drainWaiter = Task { @MainActor in
        waiterStarted.signal()
        await coordinator.waitForDrain(sessionID: sessionID)
    }
    await waiterStarted.wait()
    coordinator.cleanup(sessionID: sessionID)

    await processingGate.release()
    await drainWaiter.value

    #expect(await processor.processingRecords() == [
        RecordedLiveASRBatch(segments: batch, checkpoint: checkpoint)
    ])
    #expect(await processor.processingResults() == [
        .failed("遅れて到着した認識失敗", taskWasCancelled: false)
    ])
    #expect(state.failure(sessionID: sessionID) == nil)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
    #expect(!effects.events.contains { event in
        if case .recognitionFailed(let eventSessionID, _) = event {
            return eventSessionID == sessionID
        }
        return false
    })
}

@MainActor
@Test
func cleanupOldDrainCannotReplaceStateOrRemoveNewSameSessionDrain() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let oldCheckpoint = makeCheckpoint(1_000)
    let firstNewCheckpoint = makeCheckpoint(1_100)
    let latestNewCheckpoint = makeCheckpoint(1_200)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: latestNewCheckpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let oldProcessingGate = OneShotAsyncGate()
    let newDrainGate = OneShotAsyncGate()
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_cleanup_replacement_test",
        registrationScript: [.succeed, .succeed, .succeed],
        processingScript: [
            .suspend(oldProcessingGate, outcome: .fail("古いドレインの認識失敗")),
            .succeed,
            .succeed
        ],
        orderLog: orderLog
    )
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorThermalMonitor(pressure: .nominal),
        sleep: { _ in preconditionFailure("同一セッションの排他テストで待機してはいけません") }
    )
    let oldBatch = [makeSegment("seg_cleanup_old", at: 0)]
    let firstNewBatch = [makeSegment("seg_cleanup_new_first", at: 10)]
    let secondNewBatch = [makeSegment("seg_cleanup_new_second", at: 20)]

    await coordinator.enqueue(sessionID: sessionID, segments: oldBatch, checkpoint: oldCheckpoint)
    await oldProcessingGate.waitUntilEntered()

    let waiterStarted = OneShotAsyncSignal()
    let oldDrainWaiter = Task { @MainActor in
        waiterStarted.signal()
        await coordinator.waitForDrain(sessionID: sessionID)
    }
    await waiterStarted.wait()
    coordinator.cleanup(sessionID: sessionID)
    effects.suspendNextDrainAtIdleRelease(using: newDrainGate)

    await coordinator.enqueue(
        sessionID: sessionID,
        segments: firstNewBatch,
        checkpoint: firstNewCheckpoint
    )
    await newDrainGate.waitUntilEntered()
    await coordinator.enqueue(
        sessionID: sessionID,
        segments: secondNewBatch,
        checkpoint: latestNewCheckpoint
    )

    #expect(coordinator.isDraining(sessionID: sessionID))
    #expect(state.queuedBatchCount(sessionID: sessionID) == 2)
    #expect(state.queuedSegments(sessionID: sessionID) == firstNewBatch + secondNewBatch)
    #expect(state.latestCheckpoint(sessionID: sessionID) == latestNewCheckpoint)
    #expect(state.failure(sessionID: sessionID) == nil)

    await oldProcessingGate.release()
    // The old and new drains both resume inside the reentrant fake; wait for the old one to finish so completion order is fixed.
    await processor.waitForCompletions(1)
    await newDrainGate.release()
    await oldDrainWaiter.value

    #expect(await processor.processingRecords() == [
        RecordedLiveASRBatch(segments: oldBatch, checkpoint: oldCheckpoint),
        RecordedLiveASRBatch(segments: firstNewBatch, checkpoint: latestNewCheckpoint),
        RecordedLiveASRBatch(segments: secondNewBatch, checkpoint: latestNewCheckpoint)
    ])
    #expect(await processor.processingResults() == [
        .failed("古いドレインの認識失敗", taskWasCancelled: false),
        .succeeded(taskWasCancelled: false),
        .succeeded(taskWasCancelled: false)
    ])
    #expect(state.failure(sessionID: sessionID) == nil)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
    #expect(state.latestCheckpoint(sessionID: sessionID) == latestNewCheckpoint)
    #expect(!coordinator.isDraining(sessionID: sessionID))
    #expect(!effects.events.contains { event in
        if case .recognitionFailed(let eventSessionID, _) = event {
            return eventSessionID == sessionID
        }
        return false
    })
}

/// Five-second utterance cadence; no capture, model load, or audio-file allocation.
@MainActor
@Test("Measure live backlog at 10-minute, 1-hour and 4-hour event equivalents", .enabled(if: ProcessInfo.processInfo.environment["LIVE_ASR_BACKLOG_MEASUREMENT"] == "1"))
func measureLatestCheckpointRetentionDuringThermalStall() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    let orderLog = SharedCoordinatorOrderLog()
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: makeCheckpoint(0),
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_backlog_measurement",
        registrationScript: Array(repeating: .succeed, count: 2_880),
        processingScript: [],
        orderLog: orderLog
    )
    let thermal = CoordinatorThermalMonitor(pressure: .critical)
    let thermalGate = OneShotAsyncGate()
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: thermal,
        sleep: { _ in await thermalGate.wait() }
    )
    var chunkFiles: [String] = []
    var chunkFrameCounts: [Int] = []

    for index in 0..<2_880 {
        chunkFiles.append("audio-\(index).caf")
        chunkFrameCounts.append(80_000)
        let checkpoint = AudioCheckpoint(
            committedFrames: Int64(index + 1) * 80_000,
            sampleRate: 16_000,
            channelCount: 1,
            sampleFormat: .float32LE,
            chunkFiles: chunkFiles,
            chunkFrameCounts: chunkFrameCounts,
            gapEvents: []
        )
        await coordinator.enqueue(
            sessionID: sessionID,
            segments: [SegmentReference(
                segmentationRunID: "growth",
                segmentID: "row_\(index)",
                startFrame: Int64(index) * 80_000,
                endFrame: Int64(index + 1) * 80_000
            )],
            checkpoint: checkpoint
        )

        let count = index + 1
        if [120, 720, 2_880].contains(count) {
            let batches = state.queuedBatchCount(sessionID: sessionID)
            let retained = state.pendingSegmentCount(sessionID: sessionID)
            let checkpoints = [try #require(
                state.latestCheckpoint(sessionID: sessionID)
            )]
            let retainedChunks = checkpoints.reduce(0) { $0 + $1.chunkFiles.count }
            #expect(batches == count)
            #expect(retained == count)
            #expect(checkpoints.count == 1)
            #expect(checkpoints[0] == checkpoint)
            #expect(checkpoints[0].chunkFiles.count == count)
            print("LIVE_ASR backlog equivalent_seconds=\(count * 5) batches=\(batches) retained_segment_refs=\(retained) retained_checkpoints=\(checkpoints.count) retained_chunk_entries=\(retainedChunks) latest_chunk_entries=\(checkpoint.chunkFiles.count)")
        }
    }

    await thermalGate.waitUntilEntered()
    let waiterStarted = OneShotAsyncSignal()
    let drainWaiter = Task { @MainActor in
        waiterStarted.signal()
        await coordinator.waitForDrain(sessionID: sessionID)
    }
    await waiterStarted.wait()
    coordinator.cleanup(sessionID: sessionID)
    thermal.setPressure(.fair)
    await thermalGate.release()
    await drainWaiter.value

    #expect(await processor.processingRecords().isEmpty)
    #expect(coordinator.isASRIdle)
    #expect(state.latestCheckpoint(sessionID: sessionID) == nil)
}

@MainActor
@Test("critical heat holds the live queue without recognizing, and cooling resumes it")
func criticalHeatSuspendsLiveRecognitionUntilCooled() async throws {
    let sessionID = UUID()
    let state = LiveTranscriptionState()
    state.begin(sessionID: sessionID)
    let orderLog = SharedCoordinatorOrderLog()
    let checkpoint = makeCheckpoint(16_000)
    let effects = FakeLiveTranscriptionEffects(
        recordingSessionID: sessionID,
        checkpoint: checkpoint,
        orderLog: orderLog,
        stopsRecordingOnVADEnqueue: false
    )
    let missingSessionMessage = NativeSessionProcessorError.liveASRSessionNotStarted.localizedDescription
    let processor = FakeLiveTranscriptionExecutor(
        startRunID: "asr_thermal_failure_test",
        registrationScript: [],
        processingScript: [.fail(missingSessionMessage)],
        orderLog: orderLog
    )
    let thermal = CoordinatorThermalMonitor(pressure: .critical)
    let sleepGate = OneShotAsyncGate()
    let coordinator = LiveTranscriptionCoordinator(
        state: state,
        effects: effects,
        processor: processor,
        thermalMonitor: thermal,
        sleep: { _ in await sleepGate.wait() }
    )
    let segments = [
        SegmentReference(
            segmentationRunID: "seg",
            segmentID: "seg_000001",
            startFrame: 0,
            endFrame: 8_000
        ),
        SegmentReference(
            segmentationRunID: "seg",
            segmentID: "seg_000002",
            startFrame: 8_000,
            endFrame: 16_000
        )
    ]
    state.enqueue(sessionID: sessionID, segments: [segments[0]], checkpoint: checkpoint)
    state.enqueue(sessionID: sessionID, segments: [segments[1]], checkpoint: checkpoint)
    coordinator.startDrainIfIdle(sessionID: sessionID)
    await sleepGate.waitUntilEntered()

    #expect(state.queuedBatchCount(sessionID: sessionID) == 2)
    #expect(state.failure(sessionID: sessionID) == nil)
    #expect(await processor.processingRecords().isEmpty)
    #expect(await processor.registrations().isEmpty)
    #expect(effects.events.contains(
        .thermal(sessionID, UserFacingStatus.liveTranscriptionThermalSuspended.text)
    ))

    thermal.setPressure(.fair)
    await sleepGate.release()
    await coordinator.waitForDrain(sessionID: sessionID)

    #expect(state.failure(sessionID: sessionID) == missingSessionMessage)
    #expect(state.queuedBatchCount(sessionID: sessionID) == 0)
    #expect(effects.events.contains(.recognitionFailed(sessionID, missingSessionMessage)))
}
