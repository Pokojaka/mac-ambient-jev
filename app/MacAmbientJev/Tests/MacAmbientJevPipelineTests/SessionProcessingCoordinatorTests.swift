import Foundation
import Testing
import Synchronization
@testable import MacAmbientJevPipeline
@testable import MacAmbientJevCore

private final class CoordinatorTestEventLog: Sendable {
    private let storage: Mutex<[String]>

    init() {
        storage = Mutex([])
    }

    func append(_ event: String) {
        storage.withLock { $0.append(event) }
    }

    var events: [String] {
        storage.withLock { $0 }
    }
}

private final class CoordinatorTestThermalMonitor: ThermalMonitoring, Sendable {
    private let pressureStorage: Mutex<ThermalPressure>
    private let changeObservers = TestThermalChangeObservers()

    init(pressure: ThermalPressure) {
        pressureStorage = Mutex(pressure)
    }

    var pressure: ThermalPressure {
        pressureStorage.withLock { $0 }
    }

    @MainActor
    func setPressure(_ pressure: ThermalPressure) {
        let didChange = pressureStorage.withLock { current in
            guard current != pressure else { return false }
            current = pressure
            return true
        }
        if didChange {
            changeObservers.notify()
        }
    }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        changeObservers.observeChanges(onChange)
    }

    var isCritical: Bool { pressure == .critical }
    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }
}

private struct CoordinatorQueueSnapshot {
    let pendingSessionIDs: [UUID]
    let heldSessionIDs: [UUID]
    let modelHeldSessionIDs: [UUID]
    let currentSessionID: UUID?
    let claimedSessionIDs: Set<UUID>

    /// True when no request is both current and in a list, so a queue count sees each request once.
    var countsEachRequestOnce: Bool {
        guard let currentSessionID else { return true }
        return !(pendingSessionIDs + heldSessionIDs + modelHeldSessionIDs).contains(currentSessionID)
    }

    init(snapshot: ProcessingQueueSnapshot) {
        pendingSessionIDs = snapshot.pending.map(\.sessionID)
        heldSessionIDs = snapshot.held.map(\.sessionID)
        modelHeldSessionIDs = snapshot.modelHeld.map(\.sessionID)
        currentSessionID = snapshot.currentSessionID
        claimedSessionIDs = snapshot.claimedSessionIDs
    }
}

@MainActor
private final class CoordinatorEffectsFake: SessionProcessingEffects, SessionRecoveryEffects {
    private(set) var processingQueue: ProcessingQueueSnapshot!
    var modelsReady = true
    var pausesProcessing: Bool
    var recordingSessionID: UUID?
    var recoveryStatusSnapshot = SessionRecoveryStatusSnapshot(processing: nil, transcript: "idle")
    var liveWorkerSessionIDs: Set<UUID> = []
    private let liveFailure: String?
    private let eventLog: CoordinatorTestEventLog
    var onLiveASRDrainWait: (() -> Void)?
    var onRefreshSavedSessions: (() -> Void)?

    private(set) var queueSnapshots: [CoordinatorQueueSnapshot] = []
    private(set) var eventOrder: [String] = []
    private(set) var prepareModelsCount = 0
    private(set) var idleReleaseCount = 0
    private(set) var liveASRDrainWaitCount = 0
    private(set) var liveASRCleanupCount = 0
    private(set) var refreshSavedSessionsCount = 0
    private(set) var exportCount = 0
    private(set) var exportedSessionIDs: [UUID] = []
    private(set) var currentSessionIDsDuringExport: [UUID?] = []
    var onEvent: (@MainActor (SessionProcessingEvent) -> Void)?

    init(
        pausesProcessing: Bool,
        liveFailure: String?,
        eventLog: CoordinatorTestEventLog
    ) {
        self.pausesProcessing = pausesProcessing
        self.liveFailure = liveFailure
        self.eventLog = eventLog
    }

    func prepareModels() {
        prepareModelsCount += 1
    }

    func awaitIdleRelease() async {
        idleReleaseCount += 1
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { _ in }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { _, _ in }
    }

    func processingGenerationDidOpen(sessionID: UUID, generationID: UUID) {}

    func hasLiveProcessingWorker(sessionID: UUID) -> Bool {
        liveWorkerSessionIDs.contains(sessionID)
    }

    var liveASRDrainOutcome = LiveASRDrainOutcome.drained

    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome {
        liveASRDrainWaitCount += 1
        eventLog.append("waitForLiveASRDrain:\(sessionID.uuidString)")
        onLiveASRDrainWait?()
        return liveASRDrainOutcome
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveFailure
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveASRCleanupCount += 1
        eventLog.append("cleanupLiveASRState:\(sessionID.uuidString)")
    }

    func refreshSavedSessions() {
        refreshSavedSessionsCount += 1
        onRefreshSavedSessions?()
    }

    func autoExportIfEnabled(sessionID: UUID) async {
        exportCount += 1
        exportedSessionIDs.append(sessionID)
        currentSessionIDsDuringExport.append(processingQueue.currentSessionID)
        eventLog.append("export:\(sessionID.uuidString)")
    }

    func processingQueueDidChange(_ snapshot: ProcessingQueueSnapshot) {
        processingQueue = snapshot
        queueSnapshots.append(CoordinatorQueueSnapshot(snapshot: snapshot))
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        let description: String
        switch event {
        case .backlogged:
            description = "backlogged"
        case .held(let request):
            description = "held:\(request.sessionID.uuidString)"
        case .heldForModels(let request):
            description = "heldForModels:\(request.sessionID.uuidString)"
        case .began(let request):
            description = "began:\(request.sessionID.uuidString)"
        case .liveFailed(let message):
            description = "liveFailed:\(message)"
        case .finished(let request, let result):
            description = "finished:\(request.sessionID.uuidString):\(result?.disposition.rawValue ?? "none")"
        case .next:
            description = "next"
        case .willFinishDrain:
            description = "willFinishDrain"
        case .drained:
            description = "drained"
        }
        eventOrder.append(description)
        eventLog.append(description)
        onEvent?(event)
    }

    func recoveryDidChange(_ event: SessionRecoveryEvent) {}
}

private enum CoordinatorTestProbeOutcome: CustomTestStringConvertible { case noFailure, failure, readError; var testDescription: String { "\(self)" } }
private struct CoordinatorTestProbeReadError: Error {}

private actor ScriptedSessionProcessingExecutor: SessionProcessingExecuting {
    private var scriptedResults: [SessionProcessingResult]
    private var recordedOperations: [String] = []
    private var recordedShouldPauseValues: [Bool] = []
    private var recordedPolicies: [SessionFinalizationPolicy] = []
    private let eventLog: CoordinatorTestEventLog
    var retryWaitsForCancellation = false
    private var beforeRetryResult: (@MainActor @Sendable () async -> Void)?
    private(set) var retryCancellationObserved = false

    init(scriptedResults: [SessionProcessingResult], eventLog: CoordinatorTestEventLog) {
        self.scriptedResults = scriptedResults
        self.eventLog = eventLog
    }

    func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: SessionFinalizationPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler,
        onGenerationOpened: @escaping NativeSessionProcessor.GenerationOpenedHandler
    ) async -> SessionProcessingResult {
        recordedPolicies.append(metadataPolicy)
        record("processSession:\(sessionID.uuidString)")
        await beforeGate?()
        // Like the real run, cancellation during the pause check produces a reasonless pause.
        let holdReason: InferenceHoldReason?
        do {
            holdReason = try await shouldPause(.dispatch)
            try Task.checkCancellation()
        } catch is CancellationError {
            record("gateCancelled:\(sessionID.uuidString)")
            return .paused(
                metrics: nil, retained: .nothing, message: "処理を中断しました", reason: nil,
                replacementGeneration: .notOpened
            )
        } catch {
            preconditionFailure("一時停止の判定が想定外のエラーを返しました: \(error)")
        }
        recordedShouldPauseValues.append(holdReason != nil)
        let result = nextResult()
        return await applyingPauseReason(to: result, holdReason: holdReason, onStatus: onStatus)
    }

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        record("retryContentPriority:\(sessionID.uuidString)")
        if retryWaitsForCancellation {
            // Only cancellation ends the wait; the test's `.timeLimit` guards against a hang.
            do {
                while true { try await Task.sleep(nanoseconds: 60_000_000_000) }
            } catch is CancellationError {
                // The coordinator cancellation is the behavior under test.
            } catch {
                preconditionFailure("予期しない retry 待機エラー: \(error)")
            }
        }
        retryCancellationObserved = Task.isCancelled
        await beforeRetryResult?()
        return nextResult()
    }

    func makeRetryWaitForCancellation() {
        retryWaitsForCancellation = true
    }

    func setBeforeRetryResult(_ callback: (@MainActor @Sendable () async -> Void)?) {
        beforeRetryResult = callback
    }

    private var beforeGate: (@MainActor @Sendable () -> Void)?
    func setBeforeGate(_ callback: @escaping @MainActor @Sendable () -> Void) { beforeGate = callback }

    /// What the durable-failure probe finds; settable from the synchronous live-drain hook.
    nonisolated let probeOutcome = Mutex(CoordinatorTestProbeOutcome.noFailure)
    private var beforeProbeResult: (@MainActor @Sendable () -> Void)?
    func setBeforeProbeResult(_ callback: @escaping @MainActor @Sendable () -> Void) { beforeProbeResult = callback }
    /// Reads the log state first and returns it after the hook, as a real read that completes before news arrives.
    func hasUnresolvedASRFailure(sessionID: UUID) async throws -> Bool {
        let outcome = probeOutcome.withLock { $0 }
        await beforeProbeResult?()
        switch outcome {
        case .noFailure: return false
        case .failure: return true
        case .readError: throw CoordinatorTestProbeReadError()
        }
    }

    private var duringLiveCancellation: (@MainActor @Sendable () -> Void)?
    func setDuringLiveCancellation(_ callback: @escaping @MainActor @Sendable () -> Void) {
        duringLiveCancellation = callback
    }
    func cancelLiveTranscription(sessionID: UUID) async {
        record("cancelLiveTranscription:\(sessionID.uuidString)")
        await duringLiveCancellation?()
    }

    func operations() -> [String] { recordedOperations }
    func shouldPauseValues() -> [Bool] { recordedShouldPauseValues }
    func policies() -> [SessionFinalizationPolicy] { recordedPolicies }

    private func record(_ operation: String) {
        recordedOperations.append(operation)
        eventLog.append(operation)
    }

    private func applyingPauseReason(
        to result: SessionProcessingResult,
        holdReason: InferenceHoldReason?,
        onStatus: NativeSessionProcessor.StatusHandler
    ) async -> SessionProcessingResult {
        guard result.disposition == .paused, let holdReason else { return result }
        guard let retainedTranscript = result.retainedTranscript else {
            preconditionFailure("一時停止結果に保持する transcript がありません")
        }
        await onStatus(.paused(holdReason))
        return .paused(
            metrics: result.metrics,
            retained: retainedTranscript,
            message: holdReason.finalizationExplanation,
            replacementGeneration: result.replacementGeneration
        )
    }

    private func nextResult() -> SessionProcessingResult {
        guard !scriptedResults.isEmpty else {
            preconditionFailure("処理結果のスクリプトが尽きました")
        }
        return scriptedResults.removeFirst()
    }
}

private func makeCoordinatorTestPauseResult() -> SessionProcessingResult {
    SessionProcessingResult(
        disposition: .paused,
        metrics: nil,
        message: "処理を一時停止しました",
        noSpeech: false,
        retainedTranscript: .nothing,
        replacementGeneration: .notOpened
    )
}

private func makeCoordinatorTestCompletedResult() -> SessionProcessingResult {
    .completed(metrics: nil, noSpeech: false, replacementGeneration: .notOpened)
}

private func makeCoordinatorTestFailedResult() -> SessionProcessingResult {
    .failed(
        message: "確定処理に失敗しました", metrics: nil, retained: nil, replacementGeneration: .notOpened
    )
}

private enum RetryTerminalOutcome: CaseIterable, CustomTestStringConvertible {
    case failed
    case completed

    var testDescription: String { String(describing: self) }
}

private enum RetryLatePause: CaseIterable, CustomTestStringConvertible {
    case cancellation
    case processingPause
    case both

    var testDescription: String { String(describing: self) }
}

private func makeRecoveryCandidate(
    sessionID: UUID,
    action: RecoverableProcessingAction
) -> RecoverableSession {
    let manifest = SessionManifest(
        sessionID: sessionID,
        createdAt: Date(timeIntervalSince1970: 0),
        source: .imported(originalFilename: "fixture.wav")
    )
    return RecoverableSession(
        manifest: manifest,
        sessionURL: URL(fileURLWithPath: "/recovery/\(sessionID.uuidString)"),
        generationID: nil,
        action: action
    )
}

@MainActor
@Test
func criticalThermalHoldResumesInFIFOOrder() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .critical)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [
            makeCoordinatorTestCompletedResult(),
            makeCoordinatorTestCompletedResult(),
            makeCoordinatorTestCompletedResult()
        ],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor,
        resourceHolds: nil
    )
    let firstSessionID = UUID()
    let secondSessionID = UUID()
    let retrySessionID = UUID()

    try coordinator.enqueueReprocess(sessionID: firstSessionID)
    try coordinator.enqueueReprocess(sessionID: secondSessionID)
    coordinator.enqueue(.retryContentPriority(sessionID: retrySessionID, boundarySegments: [], clauses: []))

    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.held.map(\.sessionID) == [firstSessionID, secondSessionID])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.inference(.thermal), .inference(.thermal)])
    #expect(effects.processingQueue.claimedSessionIDs == Set([firstSessionID, secondSessionID]))
    #expect(await processor.operations() == ["retryContentPriority:\(retrySessionID.uuidString)"])
    #expect(effects.exportCount == 0)
    #expect(effects.queueSnapshots.contains {
        $0.heldSessionIDs == [firstSessionID, secondSessionID]
            && $0.claimedSessionIDs == Set([firstSessionID, secondSessionID])
    })
    #expect(effects.queueSnapshots.contains {
        $0.pendingSessionIDs.contains(firstSessionID)
            && $0.claimedSessionIDs == Set([firstSessionID, secondSessionID])
    })

    thermalMonitor.setPressure(.fair)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "retryContentPriority:\(retrySessionID.uuidString)",
        "processSession:\(firstSessionID.uuidString)",
        "processSession:\(secondSessionID.uuidString)"
    ])
    #expect(await processor.shouldPauseValues() == [false, false])
    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(!coordinator.isDraining)
    #expect(effects.exportedSessionIDs == [firstSessionID, secondSessionID])
}

@MainActor
@Test
func pauseRetainsClaimAndCompletionReleasesIt() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestPauseResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor,
        resourceHolds: nil
    )
    let sessionID = UUID()

    try coordinator.enqueueReprocess(sessionID: sessionID)
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.paused])
    #expect(effects.processingQueue.claimedSessionIDs == [sessionID])

    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.exportCount == 1)
    #expect(effects.exportedSessionIDs == [sessionID])
    #expect(effects.currentSessionIDsDuringExport == [sessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(await processor.operations() == [
        "processSession:\(sessionID.uuidString)",
        "processSession:\(sessionID.uuidString)"
    ])

    let heldIndex = try #require(effects.eventOrder.firstIndex(of: "held:\(sessionID.uuidString)"))
    let finishedIndex = try #require(effects.eventOrder.firstIndex(of: "finished:\(sessionID.uuidString):paused"))
    #expect(heldIndex < finishedIndex)
}

/// A pause that cancels drain A at fair keeps A held across unrelated drain B and a thermal change that ends,
/// until the explicit resume.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aCancelledDrainStaysHeldUntilTheExplicitResume() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let first = UUID(), second = UUID()
    effects.onLiveASRDrainWait = { coordinator.requestPause(); effects.onLiveASRDrainWait = nil }

    coordinator.enqueue(.finalize(sessionID: first, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.sessionID) == [first])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.paused])

    coordinator.enqueue(.finalize(sessionID: second, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    thermal.setPressure(.critical)
    thermal.setPressure(.fair)
    await coordinator.waitUntilIdle()

    let pausedFirst = "cancelLiveTranscription:\(first.uuidString)"
    #expect(await processor.operations() == [pausedFirst, "processSession:\(second.uuidString)"])
    #expect(effects.processingQueue.held.map(\.sessionID) == [first])
    #expect(effects.processingQueue.pending.isEmpty)

    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(await processor.operations() == [
        pausedFirst, "processSession:\(second.uuidString)", "processSession:\(first.uuidString)"
    ])
    #expect(effects.processingQueue.held.isEmpty)
}

/// A pause that cancels the drain while the critical dequeue probe reads the log holds the request as paused,
/// not as thermal: a later drain at fair does not resume it before the explicit resume.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aPauseDuringTheCriticalDequeueProbeHoldsAsPaused() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .critical)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let first = UUID(), second = UUID()
    // Only the first probe pauses; the second request's post-drain probe at fair must not.
    await processor.setBeforeProbeResult { coordinator.requestPause() }

    coordinator.enqueue(.finalize(sessionID: first, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.sessionID) == [first])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.paused])

    await processor.setBeforeProbeResult {}
    thermal.setPressure(.fair)
    coordinator.enqueue(.finalize(sessionID: second, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(await processor.operations() == ["processSession:\(second.uuidString)"])
    #expect(effects.processingQueue.held.map(\.sessionID) == [first])

    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(await processor.operations() == [
        "processSession:\(second.uuidString)", "processSession:\(first.uuidString)"
    ])
    #expect(effects.processingQueue.held.isEmpty)
}

/// Cooling while another request runs moves the thermally held finalization to the front of `pending`,
/// so it runs before work that was enqueued after it was held.
@MainActor
@Test(.timeLimit(.minutes(10)))
func coolingDuringAnotherRequestRunsTheHeldFinalizationBeforeTheBacklog() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .critical)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [
            makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()
        ],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let held = UUID(), current = UUID(), later = UUID()

    coordinator.enqueue(.finalize(sessionID: held, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.holdReason) == [.inference(.thermal)])

    await processor.setBeforeRetryResult {
        coordinator.enqueue(.finalize(sessionID: later, metadataPolicy: .reject))
        thermal.setPressure(.fair)
    }
    coordinator.enqueue(.retryContentPriority(sessionID: current, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "retryContentPriority:\(current.uuidString)",
        "processSession:\(held.uuidString)",
        "processSession:\(later.uuidString)"
    ])
    #expect(effects.exportedSessionIDs == [held, later])
    #expect(effects.processingQueue.held.isEmpty)
}

/// A pause that cancels the drain while the dispatch gate paces at serious ends the attempt through the gate:
/// the result is a reasonless pause, no scripted result is used, and the request waits for the explicit resume.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aPauseDuringTheDispatchGateHoldsAsPausedWithoutAResult() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .serious)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let sessionID = UUID()
    await processor.setBeforeGate { coordinator.requestPause() }

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)", "gateCancelled:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.paused])
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
    #expect(effects.exportCount == 0)

    await processor.setBeforeGate {}
    thermal.setPressure(.fair)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(effects.exportedSessionIDs == [sessionID])
    #expect(effects.processingQueue.held.isEmpty)
}

@MainActor
@Test
func failedFinalizationReleasesClaimWithoutExport() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor,
        resourceHolds: nil
    )
    let sessionID = UUID()

    try coordinator.enqueueReprocess(sessionID: sessionID)
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
}

@MainActor
@Test
func completedFinishLiveRefreshesSavedSessions() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(
        pausesProcessing: false,
        liveFailure: nil,
        eventLog: eventLog
    )
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    coordinator.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.refreshSavedSessionsCount == 1)
}

@MainActor
@Test
func pausedFinishLiveResumesAsStoredFinalization() async throws {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let failureMessage = "ライブ文字起こしに失敗しました"
    let effects = CoordinatorEffectsFake(
        pausesProcessing: false,
        liveFailure: failureMessage,
        eventLog: eventLog
    )
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestPauseResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor,
        resourceHolds: nil
    )
    let sessionID = UUID()
    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.liveASRDrainWaitCount == 1)
    #expect(effects.liveASRCleanupCount == 1)
    #expect(effects.refreshSavedSessionsCount == 1)
    #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])
    if let heldEntry = effects.processingQueue.held.first {
        #expect(heldEntry.sessionID == sessionID)
        #expect(heldEntry.kind == .finalization)
    } else {
        #expect(Bool(false), "一時停止したライブ処理がキューに保持されていません")
    }

    let eventsBeforeResume = eventLog.events
    let waitIndex = try #require(eventsBeforeResume.firstIndex(of: "waitForLiveASRDrain:\(sessionID.uuidString)"))
    let finishIndex = try #require(eventsBeforeResume.firstIndex(of: "processSession:\(sessionID.uuidString)"))
    #expect(waitIndex < finishIndex)

    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "processSession:\(sessionID.uuidString)",
        "processSession:\(sessionID.uuidString)"
    ])
    #expect(effects.liveASRDrainWaitCount == 2)
    #expect(effects.liveASRCleanupCount == 2)
    #expect(effects.exportedSessionIDs == [sessionID])
}

@MainActor
@Test(.timeLimit(.minutes(10)))
func cancelledRetryIsHeldAndFollowingRequestIsNotDequeued() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestPauseResult()],
        eventLog: eventLog
    )
    await processor.makeRetryWaitForCancellation()
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let firstSessionID = UUID()
    let nextSessionID = UUID()
    coordinator.enqueue(.retryContentPriority(sessionID: firstSessionID, boundarySegments: [], clauses: []))
    coordinator.enqueue(.retryContentPriority(sessionID: nextSessionID, boundarySegments: [], clauses: []))

    let retryStarted = "retryContentPriority:\(firstSessionID.uuidString)"
    while !eventLog.events.contains(retryStarted) {
        await Task.yield()
    }
    coordinator.requestPause()
    await coordinator.waitUntilIdle()

    #expect(await processor.retryCancellationObserved)
    #expect(await processor.operations() == [retryStarted])
    #expect(effects.processingQueue.held.map(\.sessionID) == [firstSessionID])
    #expect(effects.processingQueue.pending.map(\.sessionID) == [nextSessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.eventOrder.contains("finished:\(firstSessionID.uuidString):paused"))
    #expect(effects.exportCount == 0)
}

@MainActor
@Test
func pausedRetryIsHeldWithoutCallingExecutor() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()
    effects.onEvent = { event in
        if case .began = event {
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations().isEmpty)
    #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
}

@MainActor
@Test
func retryFailureIsForwardedUnchangedWithoutExport() async throws {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let failureMessage = "発話文の判定を再試行できませんでした: テスト判定エラー"
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [
            .failed(
                message: failureMessage, metrics: nil, retained: .finalized, replacementGeneration: .notOpened
            )
        ],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    var finishedResult: SessionProcessingResult?
    effects.onEvent = { event in
        if case .finished(_, let result) = event {
            finishedResult = result
        }
    }
    let sessionID = UUID()

    coordinator.enqueue(.retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    let result = try #require(finishedResult)
    #expect(result.disposition == .failed)
    #expect(result.message == failureMessage)
    #expect(result.metrics == nil)
    #expect(result.retainedTranscript == .finalized)
    #expect(!result.noSpeech)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
}

@MainActor
@Test
func postRetryPauseDoesNotHoldOrReplaceFailure() async throws {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let failureMessage = "発話文の判定を再試行できませんでした: テスト判定エラー"
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [
            .failed(
                message: failureMessage, metrics: nil, retained: .finalized, replacementGeneration: .notOpened
            )
        ],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    effects.onRefreshSavedSessions = { effects.pausesProcessing = true }
    var finishedResult: SessionProcessingResult?
    effects.onEvent = { event in
        if case .finished(_, let result) = event {
            finishedResult = result
        }
    }
    let sessionID = UUID()

    coordinator.enqueue(.retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    let result = try #require(finishedResult)
    #expect(effects.pausesProcessing)
    #expect(result.disposition == .failed)
    #expect(result.message == failureMessage)
    #expect(result.retainedTranscript == .finalized)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
}

@MainActor
@Test(arguments: RetryTerminalOutcome.allCases, RetryLatePause.allCases)
private func terminalRetryOutcomeWinsOverLatePause(
    _ outcome: RetryTerminalOutcome,
    _ latePause: RetryLatePause
) async throws {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let failureMessage = "発話文の判定を再試行できませんでした: テスト判定エラー"
    let scriptedResult: SessionProcessingResult
    switch outcome {
    case .failed:
        scriptedResult = .failed(
                message: failureMessage, metrics: nil, retained: .finalized, replacementGeneration: .notOpened
            )
    case .completed:
        scriptedResult = makeCoordinatorTestCompletedResult()
    }
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [scriptedResult],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()
    var finishedEventObserved = false
    var finishedResult: SessionProcessingResult?
    effects.onEvent = { event in
        if case .finished(_, let result) = event {
            finishedEventObserved = true
            finishedResult = result
        }
    }
    await processor.setBeforeRetryResult {
        eventLog.append("beforeRetryResult")
        switch latePause {
        case .cancellation:
            coordinator.requestPause()
        case .processingPause:
            effects.pausesProcessing = true
        case .both:
            effects.pausesProcessing = true
            coordinator.requestPause()
        }
    }

    coordinator.enqueue(.retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    #expect(eventLog.events.contains("beforeRetryResult"))
    #expect(finishedEventObserved)
    switch outcome {
    case .failed:
        let result = try #require(finishedResult)
        #expect(result.disposition == scriptedResult.disposition)
        #expect(result.message == failureMessage)
    case .completed:
        #expect(scriptedResult.disposition == .completed)
        #expect(finishedResult == nil)
    }
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)

    effects.pausesProcessing = false
    if effects.processingQueue.held.isEmpty && effects.processingQueue.pending.isEmpty {
        coordinator.resumeHeldProcessing()
    }
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["retryContentPriority:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.processingQueue.pending.isEmpty)
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
}

@MainActor
@Test
func pauseOnFinishedNotificationSkipsAutoExport() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()
    effects.onEvent = { event in
        if case .finished = event {
            effects.pausesProcessing = true
        }
    }

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):completed"))
    #expect(effects.exportCount == 0)
    #expect(effects.exportedSessionIDs.isEmpty)
    #expect(effects.eventOrder.suffix(2) == ["willFinishDrain", "drained"])
}

@MainActor
@Test
func recoveryFilteringExcludesRecordingMaintenanceFailuresPendingAndPublishedRetries() throws {
    let finalizeID = UUID()
    let recordingID = UUID()
    let recoverDecisionID = UUID()
    let maintenanceFailureID = UUID()
    let interruptedMaintenanceID = UUID()
    let pendingID = UUID()
    let publishedRetryID = UUID()
    let boundarySegments = [try SegmentTextReference(
        segmentationRunID: "segmentation_run",
        segmentID: "segment_0001",
        asrRunID: "asr_run",
        asrEventSeq: 1
    )]
    let clauses = [try ClauseReference(boundaryRunID: "boundary_run", clauseID: "clause_0001")]
    let candidates = [
        makeRecoveryCandidate(sessionID: finalizeID, action: .finalize),
        makeRecoveryCandidate(sessionID: recordingID, action: .finalize),
        makeRecoveryCandidate(
            sessionID: recoverDecisionID,
            action: .recoverDecisionRun(boundarySegments: boundarySegments, clauses: clauses)
        ),
        makeRecoveryCandidate(sessionID: maintenanceFailureID, action: .finalize),
        makeRecoveryCandidate(sessionID: interruptedMaintenanceID, action: .finalize),
        makeRecoveryCandidate(sessionID: pendingID, action: .finalize),
        makeRecoveryCandidate(
            sessionID: publishedRetryID,
            action: .retryContentPriority(boundarySegments: boundarySegments, clauses: clauses)
        )
    ]
    let requests = SessionProcessingCoordinator.recoveryRequests(
        candidates: candidates,
        recordingSessionID: recordingID,
        maintenanceFailures: [
            maintenanceFailureID: .failed("保存領域の保守に失敗しました"),
            interruptedMaintenanceID: .interruptedByShutdown("終了時に保守が中断されました")
        ],
        occupiedSessionIDs: [pendingID]
    )

    #expect(requests.map(\.sessionID) == [finalizeID, recoverDecisionID])
    #expect(!requests.contains { $0.sessionID == maintenanceFailureID })
    #expect(!requests.contains { $0.sessionID == interruptedMaintenanceID })
    if case .finalize(_, let sessionID, let metadataPolicy) = requests[0] {
        #expect(sessionID == finalizeID)
        #expect(metadataPolicy == .reject)
    } else {
        #expect(Bool(false), "復旧候補は確定処理へ変換されます")
    }
    if case .retryContentPriority(_, let sessionID, let mappedBoundarySegments, let mappedClauses) = requests[1] {
        #expect(sessionID == recoverDecisionID)
        #expect(mappedBoundarySegments == boundarySegments)
        #expect(mappedClauses == clauses)
    } else {
        #expect(Bool(false), "未公開の判定 run は優先度再処理へ変換されます")
    }
}

@MainActor
@Test
func processingCompletionPublishesBeforeTaskReleaseThenAllowsIdleRelease() async {
    let thermalMonitor = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: thermalMonitor,
        resourceHolds: nil
    )
    var drainingObservations: [Bool] = []
    effects.onEvent = { event in
        switch event {
        case .willFinishDrain, .drained:
            drainingObservations.append(coordinator.isDraining)
        case .backlogged, .held, .heldForModels, .began, .liveFailed, .finished, .next:
            break
        }
    }
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(drainingObservations == [true, false])
    #expect(effects.eventOrder.suffix(2) == ["willFinishDrain", "drained"])
}

@MainActor
@Test
func retainedFinalizeRequestRunsExactlyOneFinalization() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()

    coordinator.enqueue(SessionFinalizeRequest(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
    #expect(effects.exportedSessionIDs == [sessionID])
}

@MainActor
@Test
func inferenceResourcePressureWhileStoppingHoldsTheFinalizationAndReplaysIt() async throws {
    let monitor = TestInferenceResourceMonitor(.healthy), eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.onLiveASRDrainWait = { monitor.setSignal(.pressure); effects.onLiveASRDrainWait = nil }
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: InferenceResourceHolds(
            monitor: monitor, release: { eventLog.append("resourceRelease") })
    )
    let sessionID = UUID()
    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
    let held = try #require(effects.processingQueue.held.first)
    #expect(held.holdReason == .inference(.resourcePressure))
    #expect(held.sessionID == sessionID && held.kind == .finalization)
    #expect(effects.liveASRCleanupCount == 1 && effects.exportCount == 0)

    monitor.setSignal(.healthy)
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "cancelLiveTranscription:\(sessionID.uuidString)", "processSession:\(sessionID.uuidString)"
    ])
    #expect(effects.exportCount == 1)
}

@MainActor
@Test(arguments: [InferenceResourceSignal.pressure, .monitorFailed("QueryMemoryResourceNotification failed (Win32 1234)")], [false, true])
func inferenceResourceFinalizationPausesAndReplaysWholeAttempt(
    _ signal: InferenceResourceSignal, _ recoverBeforeReturn: Bool
) async throws {
    let monitor = TestInferenceResourceMonitor(.healthy), eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects,
        processor: processor,
        thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: InferenceResourceHolds(
            monitor: monitor, release: { eventLog.append("resourceRelease") })
    )
    let sessionID = UUID()
    try coordinator.enqueueReprocess(sessionID: sessionID)
    let operation = "processSession:\(sessionID.uuidString)"
    var beganCount = 0
    var heldReason: ProcessingRequestHold?
    var pausedMessage: String?
    effects.onEvent = { event in
        switch event {
        case .began: beganCount += 1
            if beganCount == 1 { monitor.setSignal(signal) }
        case .held(let item):
            heldReason = item.holdReason
            if recoverBeforeReturn { monitor.setSignal(.healthy) }
        case .finished(_, let result) where result?.disposition == .paused: pausedMessage = result?.message
        default: break
        }
    }

    await coordinator.waitUntilIdle()
    #expect(heldReason == signal.holdReason.map(ProcessingRequestHold.inference) && pausedMessage == signal.holdReason?.finalizationExplanation)
    if !recoverBeforeReturn {
        #expect(effects.processingQueue.claimedSessionIDs == Set([sessionID]) && effects.exportCount == 0)
        monitor.setSignal(.healthy)
        await coordinator.waitUntilIdle()
    }

    // The pressure that arrived before processing started holds the request without processing it.
    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)", operation])
    #expect(await processor.shouldPauseValues() == [false])
    #expect(effects.processingQueue.held.isEmpty && effects.processingQueue.claimedSessionIDs.isEmpty)
    #expect(effects.exportCount == 1 && effects.exportedSessionIDs == [sessionID])
    #expect(eventLog.events.filter { $0 == "resourceRelease" }.count == 1)
    let releaseIndex = try #require(eventLog.events.firstIndex(of: "resourceRelease"))
    let secondBeganIndex = try #require(eventLog.events.enumerated()
        .filter { $0.element == "began:\(sessionID.uuidString)" }.dropFirst().first?.offset)
    #expect(releaseIndex < secondBeganIndex)
}

@MainActor
@Test
func modelHoldKeepsFIFOOrderAndClaimsUntilTheModelsAreReady() async throws {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.modelsReady = false
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [
            makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()
        ],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .nominal),
        resourceHolds: nil
    )
    let first = UUID(), second = UUID(), retry = UUID()
    try coordinator.enqueueReprocess(sessionID: first)
    try coordinator.enqueueReprocess(sessionID: second)
    coordinator.enqueue(.retryContentPriority(sessionID: retry, boundarySegments: [], clauses: []))
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.modelHeld.map(\.sessionID) == [first, second])
    #expect(effects.processingQueue.claimedSessionIDs == Set([first, second]))
    #expect(effects.processingQueue.sessionIDs.isSuperset(of: [first, second]))
    let released = ["cancelLiveTranscription:\(first.uuidString)", "cancelLiveTranscription:\(second.uuidString)"]
    #expect(await processor.operations() == released + ["retryContentPriority:\(retry.uuidString)"])

    coordinator.resumeModelHeldProcessing()
    #expect(effects.processingQueue.modelHeld.count == 2)

    effects.modelsReady = true
    coordinator.resumeModelHeldProcessing()
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == released + [
        "retryContentPriority:\(retry.uuidString)",
        "processSession:\(first.uuidString)",
        "processSession:\(second.uuidString)"
    ])
    #expect(effects.processingQueue.modelHeld.isEmpty)
    #expect(effects.processingQueue.claimedSessionIDs.isEmpty)
}

@MainActor
@Test
func liveFinalizationHeldForModelsReleasesTheLiveWorker() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.modelsReady = false
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .nominal),
        resourceHolds: nil
    )
    let sessionID = UUID()
    var sessionIDsDuringWait: [Set<UUID>] = []
    effects.onLiveASRDrainWait = { sessionIDsDuringWait.append(effects.processingQueue.sessionIDs) }

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(sessionIDsDuringWait == [[sessionID]])
    #expect(effects.processingQueue.currentSessionID == nil)
    #expect(effects.processingQueue.modelHeld.count == 1)
    #expect(effects.processingQueue.modelHeld[0].kind == .finalization)
    #expect(effects.processingQueue.modelHeld[0].sessionID == sessionID)
    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
    #expect(effects.liveASRCleanupCount == 1)
    // Waiting for the models is not an outcome, so a caller waiting on the request keeps waiting.
    #expect(effects.eventOrder.contains("heldForModels:\(sessionID.uuidString)"))
    #expect(!effects.eventOrder.contains { $0.hasPrefix("finished:") })
    #expect(effects.queueSnapshots.allSatisfy { $0.countsEachRequestOnce })
    #expect(effects.refreshSavedSessionsCount == 1)

    effects.modelsReady = true
    coordinator.resumeModelHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(await processor.operations().last == "processSession:\(sessionID.uuidString)")
    #expect(effects.eventOrder.filter { $0.hasPrefix("finished:") } == ["finished:\(sessionID.uuidString):completed"])
}

@MainActor
@Test
func modelsReadyDuringLiveWorkerCleanupRunTheHeldFinalization() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.modelsReady = false
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .nominal),
        resourceHolds: nil
    )
    await processor.setDuringLiveCancellation {
        effects.modelsReady = true
        coordinator.resumeModelHeldProcessing()
    }
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == [
        "cancelLiveTranscription:\(sessionID.uuidString)", "processSession:\(sessionID.uuidString)"
    ])
    #expect(effects.processingQueue.modelHeld.isEmpty && effects.processingQueue.pending.isEmpty)
    #expect(effects.exportedSessionIDs == [sessionID])
}

@MainActor
@Test
func pauseDuringLiveDrainSkipsProcessingAndHoldsTheFinalization() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.onLiveASRDrainWait = { effects.pausesProcessing = true }
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
    #expect(effects.liveASRCleanupCount == 1)
    #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
}

@MainActor
@Test
func durableASRFailureIsProcessedInsteadOfHeldForModels() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.modelsReady = false
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog
    )
    processor.probeOutcome.withLock { $0 = .failure }
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.isEmpty && effects.processingQueue.modelHeld.isEmpty)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
}

/// Critical thermal holds a finalization at dequeue unless the log shows a durable failure; an unreadable log is unknown.
@MainActor
@Test(arguments: [CoordinatorTestProbeOutcome.failure, .readError])
private func criticalThermalHoldsOnlyWhenNoDurableFailureIsKnown(probe: CoordinatorTestProbeOutcome) async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog
    )
    processor.probeOutcome.withLock { $0 = probe }
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .critical),
        resourceHolds: nil
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.queueSnapshots.allSatisfy { $0.countsEachRequestOnce })
    switch probe {
    case .failure:
        #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
        #expect(effects.processingQueue.held.isEmpty)
        #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
    case .readError, .noFailure:
        #expect(await processor.operations().isEmpty)
        #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])
    }
}

/// Stop is admitted at fair; heat rises before the live worker's next segment, so the worker waits for cooling.
/// The request is parked with its worker, and the queue still evaluates the next request.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aLiveWorkerWaitingForCoolingParksTheFinalizationAndFreesTheQueue() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .fair)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let first = UUID(), second = UUID()
    effects.liveASRDrainOutcome = .suspendedForCooling
    var heatsOnce = true
    effects.onLiveASRDrainWait = {
        if heatsOnce { heatsOnce = false; thermal.setPressure(.critical) }
    }

    coordinator.enqueue(.finalize(sessionID: first, metadataPolicy: .reject))
    coordinator.enqueue(.finalize(sessionID: second, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.held.map(\.sessionID) == [first, second])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.inference(.thermal), .inference(.thermal)])
    #expect(effects.processingQueue.currentSessionID == nil)
    // The first request keeps its live worker; the second never reached its own.
    #expect(await processor.operations().isEmpty)
    #expect(effects.liveASRCleanupCount == 0)
    #expect(effects.queueSnapshots.allSatisfy { $0.countsEachRequestOnce })

    effects.liveASRDrainOutcome = .drained
    thermal.setPressure(.fair)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(await processor.operations() == ["processSession:\(first.uuidString)", "processSession:\(second.uuidString)"])
}

/// A pause that was decided while heat lasted is not lost when heat ended before the request was held.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aPauseThatCooledBeforeTheHoldResumesAtOnce() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let pausedByHeat = SessionProcessingResult.paused(
        metrics: nil, retained: .nothing, message: "発熱のため一時停止", reason: .thermal,
        replacementGeneration: .notOpened
    )
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [pausedByHeat, makeCoordinatorTestCompletedResult()], eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)", "processSession:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.exportedSessionIDs == [sessionID])
    #expect(effects.queueSnapshots.allSatisfy { $0.countsEachRequestOnce })
}

/// A live worker's durable failure decides a thermally held finalization again: it ends failed without inference.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aDurableFailureWhileThermallyHeldEndsTheRequestFailed() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .critical),
        resourceHolds: nil
    )
    let sessionID = UUID()
    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.sessionID) == [sessionID])

    processor.probeOutcome.withLock { $0 = .failure }
    coordinator.liveWorkerDidFail(sessionID: UUID())
    #expect(effects.processingQueue.held.count == 1)
    coordinator.liveWorkerDidFail(sessionID: sessionID)
    await coordinator.waitUntilIdle()

    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
}

/// Under critical thermal the probe reads "no failure"; the live worker's failure arrives after that read and
/// before the hold. The latched report wakes the request, the next probe sees the failure, and it ends failed.
@MainActor
@Test(.timeLimit(.minutes(10)))
func aLiveFailureBetweenTheProbeReadAndTheHoldIsNotLost() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog)
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .critical),
        resourceHolds: nil
    )
    let sessionID = UUID()
    await processor.setBeforeProbeResult {
        let isNew = processor.probeOutcome.withLock { outcome in
            defer { outcome = .failure }
            return outcome == .noFailure
        }
        if isNew { coordinator.liveWorkerDidFail(sessionID: sessionID) }
    }

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
}

/// The stored drain waits before each segment under serious thermal, like the live worker.
@MainActor
@Test(.timeLimit(.minutes(10)))
func seriousThermalPacesTheStoredDrain() async {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult()], eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .serious),
        resourceHolds: nil
    )
    let clock = ContinuousClock()

    let elapsed = await clock.measure {
        coordinator.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
        await coordinator.waitUntilIdle()
    }

    #expect(elapsed >= .milliseconds(750))
    #expect(await processor.shouldPauseValues() == [false])
}

/// Memory pressure is active at admission or arrives during the drain; the live call fails durably meanwhile.
@MainActor
@Test(arguments: [true, false])
func aLiveASRFailureDuringTheWaitBeatsAResourceHold(pressureAtAdmission: Bool) async {
    let monitor = TestInferenceResourceMonitor(pressureAtAdmission ? .pressure : .healthy)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog)
    effects.onLiveASRDrainWait = {
        monitor.setSignal(.pressure)
        processor.probeOutcome.withLock { $0 = .failure }
    }
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: InferenceResourceHolds(monitor: monitor, release: { eventLog.append("resourceRelease") })
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.isEmpty)
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
}

/// A probe read error is not a failure: holds apply, and with none processing runs once and reports it.
@MainActor
@Test(arguments: [true, false])
func aProbeReadErrorLeavesTheDecisionToTheHolds(underPressure: Bool) async {
    let monitor = TestInferenceResourceMonitor(underPressure ? .pressure : .healthy)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestFailedResult()], eventLog: eventLog)
    processor.probeOutcome.withLock { $0 = .readError }
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: InferenceResourceHolds(monitor: monitor, release: { eventLog.append("resourceRelease") })
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    if underPressure {
        #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
        #expect(effects.processingQueue.held.map(\.holdReason) == [.inference(.resourcePressure)])
        #expect(effects.queueSnapshots.allSatisfy { $0.countsEachRequestOnce })
    } else {
        #expect(await processor.operations() == ["processSession:\(sessionID.uuidString)"])
        #expect(effects.processingQueue.held.isEmpty)
        #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):failed"))
    }
}

@MainActor
@Test
func pressureArrivingDuringTheProbeHoldsTheFinalization() async {
    let monitor = TestInferenceResourceMonitor(.healthy), eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let processor = ScriptedSessionProcessingExecutor(scriptedResults: [], eventLog: eventLog)
    await processor.setBeforeProbeResult { monitor.setSignal(.pressure) }
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: InferenceResourceHolds(monitor: monitor, release: { eventLog.append("resourceRelease") })
    )
    let sessionID = UUID()

    coordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()

    #expect(await processor.operations() == ["cancelLiveTranscription:\(sessionID.uuidString)"])
    #expect(effects.processingQueue.held.map(\.holdReason) == [.inference(.resourcePressure)])
    #expect(effects.eventOrder.contains("finished:\(sessionID.uuidString):paused"))
}

@MainActor
@Test
func modelHoldAndThermalHoldResumeOnlyWhenBothAllow() async {
    let thermal = CoordinatorTestThermalMonitor(pressure: .critical)
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    effects.modelsReady = false
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [makeCoordinatorTestCompletedResult(), makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(effects: effects, processor: processor, thermalMonitor: thermal, resourceHolds: nil)
    let first = UUID(), second = UUID()

    coordinator.enqueue(.finalize(sessionID: first, metadataPolicy: .reject))
    coordinator.enqueue(.finalize(sessionID: second, metadataPolicy: .reject))
    await coordinator.waitUntilIdle()
    // Thermal holds at dequeue, before the models are checked, and keeps the live workers.
    #expect(effects.processingQueue.held.map(\.sessionID) == [first, second])
    #expect(await processor.operations().isEmpty)

    thermal.setPressure(.fair)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.modelHeld.map(\.sessionID) == [first, second])
    let released = ["cancelLiveTranscription:\(first.uuidString)", "cancelLiveTranscription:\(second.uuidString)"]
    #expect(await processor.operations() == released)

    thermal.setPressure(.critical)
    effects.modelsReady = true
    coordinator.resumeModelHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(effects.processingQueue.held.map(\.sessionID) == [first, second])
    #expect(effects.processingQueue.modelHeld.isEmpty)
    #expect(await processor.operations() == released)

    thermal.setPressure(.fair)
    coordinator.resumeHeldProcessing()
    await coordinator.waitUntilIdle()
    #expect(await processor.operations() == released + [
        "processSession:\(first.uuidString)", "processSession:\(second.uuidString)"
    ])
}

private enum ReprocessBusyWork: CaseIterable, CustomTestStringConvertible, Equatable {
    case pending, held, modelHeld, current, recoveryClaim, recording, liveWorker, maintenance

    var testDescription: String {
        switch self {
        case .pending: "pending"
        case .held: "held"
        case .modelHeld: "model-held"
        case .current: "current"
        case .recoveryClaim: "recovery claim"
        case .recording: "recording"
        case .liveWorker: "live worker"
        case .maintenance: "maintenance"
        }
    }
}

@MainActor
@Test(arguments: ReprocessBusyWork.allCases)
private func reprocessRefusesEveryOccupiedSession(_ work: ReprocessBusyWork) async throws {
    let eventLog = CoordinatorTestEventLog()
    let effects = CoordinatorEffectsFake(pausesProcessing: false, liveFailure: nil, eventLog: eventLog)
    let sessionID = UUID()
    let request = PendingProcessing.finalize(sessionID: sessionID, metadataPolicy: .reject)
    let processor = ScriptedSessionProcessingExecutor(
        scriptedResults: [work == .held ? makeCoordinatorTestPauseResult() : makeCoordinatorTestCompletedResult()],
        eventLog: eventLog
    )
    let coordinator = SessionProcessingCoordinator(
        effects: effects, processor: processor, thermalMonitor: CoordinatorTestThermalMonitor(pressure: .fair),
        resourceHolds: nil
    )
    var admissionResult: Result<UUID, SessionProcessingAdmissionError>?
    var countDuringAdmission: (Int, Int)?
    var recoveryClaimDuringAdmission: Bool?
    let attemptAdmission = {
        let countBefore = effects.processingQueue.summaries.count
        let wasRecoveryClaimed = effects.processingQueue.recoveryClaimedSessionIDs.contains(sessionID)
        do {
            admissionResult = .success(try coordinator.enqueueReprocess(sessionID: sessionID))
        } catch let error as SessionProcessingAdmissionError {
            admissionResult = .failure(error)
        } catch {
            Issue.record("Unexpected reprocess admission error: \(error)")
        }
        countDuringAdmission = (countBefore, effects.processingQueue.summaries.count)
        recoveryClaimDuringAdmission = wasRecoveryClaimed
    }

    switch work {
    case .pending:
        effects.pausesProcessing = true
        coordinator.enqueue(request)
    case .held:
        coordinator.enqueue(request)
        await coordinator.waitUntilIdle()
    case .modelHeld:
        effects.modelsReady = false
        coordinator.enqueue(request)
        await coordinator.waitUntilIdle()
    case .current:
        effects.onLiveASRDrainWait = attemptAdmission
        coordinator.enqueue(request)
        await coordinator.waitUntilIdle()
    case .recoveryClaim:
        effects.onLiveASRDrainWait = attemptAdmission
        let maintenance = SessionMaintenanceCandidate(
            sessionID: sessionID,
            sessionURL: URL(fileURLWithPath: "/recovery"),
            maintenance: .removeTransients
        )
        await coordinator.recoverPendingSessions(
            effects: effects,
            scan: { SessionRecoveryScan(candidates: [], maintenance: [maintenance], failures: []) },
            maintain: { _, _ in
                await MainActor.run { effects.onLiveASRDrainWait?() }
                return [:]
            }
        )
    case .recording:
        effects.recordingSessionID = sessionID
    case .liveWorker:
        effects.liveWorkerSessionIDs.insert(sessionID)
    case .maintenance:
        coordinator.beginStorageMaintenance()
    }

    let snapshot = effects.processingQueue!
    if work != .current && work != .recoveryClaim {
        let countBefore = snapshot.summaries.count
        let recoveryClaimBefore = snapshot.recoveryClaimedSessionIDs.contains(sessionID)
        do {
            admissionResult = .success(try coordinator.enqueueReprocess(sessionID: sessionID))
        } catch let error as SessionProcessingAdmissionError {
            admissionResult = .failure(error)
        }
        countDuringAdmission = (countBefore, effects.processingQueue.summaries.count)
        recoveryClaimDuringAdmission = recoveryClaimBefore
    }

    if case .failure(.busy) = admissionResult {} else {
        Issue.record("Occupied session admission must fail with busy")
    }
    #expect(countDuringAdmission?.0 == countDuringAdmission?.1)
    #expect(recoveryClaimDuringAdmission == (work == .recoveryClaim))
    #expect(effects.processingQueue.containsQueuedWork(sessionID) == (work == .pending || work == .held || work == .modelHeld))
    #expect(effects.processingQueue.recoveryClaimedSessionIDs.isEmpty)
    #expect(effects.recordingSessionID == (work == .recording ? sessionID : nil))
    #expect(effects.liveWorkerSessionIDs.contains(sessionID) == (work == .liveWorker))
    #expect(effects.processingQueue.isMaintainingStorage == (work == .maintenance))
    #expect(!effects.processingQueue.claimedSessionIDs.contains(sessionID))
    #expect(await processor.policies().count == ((work == .held || work == .current) ? 1 : 0))
}
