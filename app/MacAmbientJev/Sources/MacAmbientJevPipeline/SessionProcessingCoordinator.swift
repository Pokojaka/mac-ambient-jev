import Foundation
import MacAmbientJevCore

public protocol SessionProcessingExecuting: Sendable {
    func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: SessionFinalizationPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler,
        onGenerationOpened: @escaping NativeSessionProcessor.GenerationOpenedHandler
    ) async -> SessionProcessingResult

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult

    func cancelLiveTranscription(sessionID: UUID) async

    /// True when the session's generation holds a durable ASR failure that processing reports as failed.
    func hasUnresolvedASRFailure(sessionID: UUID) async throws -> Bool
}

extension NativeSessionProcessor: SessionProcessingExecuting {}

public enum SessionProcessingEvent {
    case backlogged
    case held(ProcessingQueueItemSummary)
    case heldForModels(ProcessingQueueItemSummary)
    case began(ProcessingQueueItemSummary)
    case liveFailed(String)
    case finished(ProcessingQueueItemSummary, SessionProcessingResult?)
    case next
    case willFinishDrain
    case drained
}

@MainActor
public protocol SessionProcessingEffects: AnyObject {
    var pausesProcessing: Bool { get }

    /// True once the models are fetched, verified and loaded.
    var modelsReady: Bool { get }
    /// Starts fetching, verifying and loading the models unless that is running or has failed.
    func prepareModels()
    func awaitIdleRelease() async
    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler
    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler
    func processingGenerationDidOpen(sessionID: UUID, generationID: UUID)
    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome
    func liveASRFailure(sessionID: UUID) -> String?
    func cleanupLiveASRState(sessionID: UUID)
    var recordingSessionID: UUID? { get }
    func hasLiveProcessingWorker(sessionID: UUID) -> Bool
    func refreshSavedSessions()
    func autoExportIfEnabled(sessionID: UUID) async
    func processingQueueDidChange(_ snapshot: ProcessingQueueSnapshot)
    func processingDidChange(_ event: SessionProcessingEvent)
}

public enum SessionProcessingAdmissionError: Error, LocalizedError, Equatable {
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let message): message
        }
    }
}

@MainActor
public final class SessionProcessingCoordinator {
    private weak var effects: (any SessionProcessingEffects)?
    private let processor: any SessionProcessingExecuting
    private var queue = SessionProcessingQueue() {
        didSet { effects?.processingQueueDidChange(queue.snapshot) }
    }
    private let thermalMonitor: any ThermalMonitoring
    private let resourceHolds: InferenceResourceHolds?
    private var resourceObservation: (any InferenceResourceObservation)?
    private var thermalObservation: (any ThermalStateObservation)?
    private var activeResourceHoldReason: InferenceHoldReason?
    private var resourceRecoveryEnabled = true
    /// The current request's live worker reported a durable failure while the request was being decided.
    private var liveFailureDuringAttempt: UUID?
    private var task: Task<Void, Never>?

    public init(
        effects: any SessionProcessingEffects,
        processor: any SessionProcessingExecuting,
        thermalMonitor: any ThermalMonitoring,
        resourceHolds: InferenceResourceHolds?
    ) {
        self.effects = effects
        self.processor = processor
        self.thermalMonitor = thermalMonitor
        self.resourceHolds = resourceHolds
        thermalObservation = thermalMonitor.observeChanges { [weak self] in
            self?.inferenceConditionsDidChange()
        }
        if let resourceHolds {
            resourceObservation = resourceHolds.monitor.observeChanges { [weak self] in
                self?.inferenceConditionsDidChange()
            }
            inferenceConditionsDidChange()
        }
        effects.processingQueueDidChange(queue.snapshot)
    }

    public var isDraining: Bool { task != nil }
    public var queueSnapshot: ProcessingQueueSnapshot { queue.snapshot }

    public func requestPause() {
        resourceRecoveryEnabled = false
        task?.cancel()
    }

    public func beginStorageMaintenance() {
        queue.beginStorageMaintenance()
    }

    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    /// Claims the stopped session until finalization is synchronously enqueued.
    func claimStopHandoff(sessionID: UUID) {
        guard queue.claimReprocessing(sessionID) else {
            preconditionFailure("stopping session already has a processing admission claim")
        }
    }

    func releaseStopHandoff(sessionID: UUID) {
        queue.releaseReprocessing(sessionID)
    }

    /// Admits and enqueues a replacement without an await between the busy check and queue insertion.
    @discardableResult
    public func enqueueReprocess(sessionID: UUID) throws -> UUID {
        let effects = requiredEffects
        if effects.recordingSessionID == sessionID {
            throw SessionProcessingAdmissionError.busy("このセッションは録音中のため再処理できません")
        }
        if queue.isMaintainingStorage {
            throw SessionProcessingAdmissionError.busy("起動時の保存データの整理中は再処理できません")
        }
        if queue.containsProcessing(sessionID) {
            throw SessionProcessingAdmissionError.busy("このセッションは処理待ち・保留中または実行中のため再処理できません")
        }
        if effects.hasLiveProcessingWorker(sessionID: sessionID) {
            throw SessionProcessingAdmissionError.busy("このセッションのライブ文字起こし処理中は再処理できません")
        }
        guard let requestID = queue.enqueueAdmittedReplacement(sessionID: sessionID) else {
            throw SessionProcessingAdmissionError.busy("このセッションの再処理はすでに開始されています")
        }
        scheduleEnqueuedRequest(finalizesTranscript: true)
        return requestID
    }

    public func enqueue(_ request: SessionFinalizeRequest) {
        enqueue(request.pending)
    }

    public func enqueue(_ request: PendingProcessing) {
        guard !request.isReplacement else {
            preconditionFailure("replacement requests must enter through reprocess admission")
        }
        enqueueAdmittedRequest(request)
    }

    private func enqueueAdmittedRequest(_ request: PendingProcessing) {
        guard !request.isReplacement else {
            preconditionFailure("replacement requests must enter through reprocess admission")
        }
        queue.enqueueOrdinary(request)
        scheduleEnqueuedRequest(finalizesTranscript: request.finalizesTranscript)
    }

    private func scheduleEnqueuedRequest(finalizesTranscript: Bool) {
        let effects = requiredEffects
        let holdReason = currentHoldReason
        if !effects.pausesProcessing,
           finalizesTranscript,
           holdReason == nil || holdReason == .thermal {
            effects.prepareModels()
        }

        guard !effects.pausesProcessing, !queue.isMaintainingStorage else { return }
        if task != nil {
            effects.processingDidChange(.backlogged)
            return
        }
        startDrainIfIdle()
    }

    public func startDrainIfIdle() {
        let effects = requiredEffects
        guard task == nil,
              !effects.pausesProcessing,
              !queue.isMaintainingStorage else {
            return
        }
        resourceRecoveryEnabled = true
        task = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    /// Thermal or resource conditions changed. The current attempt latches a resource hold; inference holds
    /// that have ended move to the front of `pending` at once, even while a request runs, so older work is not
    /// left behind the backlog. A running drain picks them up next; paused work stays held.
    private func inferenceConditionsDidChange() {
        if queue.currentSessionID != nil {
            _ = holdReasonForAttempt()
        }
        if resourceRecoveryEnabled {
            resumeEndedInferenceHolds()
        }
    }

    private var currentHoldReason: InferenceHoldReason? {
        resourceHolds?.monitor.signal.holdReason
            ?? (thermalMonitor.liveASRDecision == .suspendUntilCooled ? .thermal : nil)
    }

    private func holdReasonForAttempt() -> InferenceHoldReason? {
        let reason = currentHoldReason
        if let reason, reason != .thermal {
            activeResourceHoldReason = reason
        }
        return activeResourceHoldReason ?? reason
    }

    /// Holds a request that did not finish: for `inferenceReason`, or as `.paused` when it is nil.
    /// Cancellation and the app's pause are read here, right before the hold is published, and win:
    /// such a request waits for the explicit resume whatever inference condition also applied.
    /// The request must already have left `current`, so a queue count sees it once.
    private func hold(_ request: PendingProcessing, for inferenceReason: InferenceHoldReason?) {
        let effects = requiredEffects
        let monitorFailed: Bool
        if let resourceHolds, case .monitorFailed = resourceHolds.monitor.signal {
            monitorFailed = true
        } else {
            monitorFailed = false
        }
        let publishedInferenceReason: InferenceHoldReason?
        if monitorFailed && (inferenceReason == .resourcePressure || inferenceReason == .monitorFailed) {
            publishedInferenceReason = .monitorFailed
        } else {
            publishedInferenceReason = inferenceReason
        }
        let reason: ProcessingHoldReason = if Task.isCancelled || effects.pausesProcessing {
            .paused
        } else {
            publishedInferenceReason.map(ProcessingHoldReason.inference) ?? .paused
        }
        queue.hold(request, reason: reason)
        effects.processingDidChange(.held(queue.summary(
            for: request, holdReason: queue.completionHold(for: request.requestID)
        )))
        // A live failure reported while the request was decided would otherwise find it in no list.
        if liveFailureDuringAttempt == request.sessionID {
            liveFailureDuringAttempt = nil
            queue.wakeHeldFinalization(sessionID: request.sessionID)
        }
        // An inference hold can end while the request moves from current to held, before any observer
        // could see it held; then nothing would change again, so resume at once.
        if case .inference = reason, !Task.isCancelled, currentHoldReason == nil {
            resumeEndedInferenceHolds()
        }
    }

    /// A live worker reported a durable ASR failure: a thermally held finalization is decided again,
    /// because processing persists the failure without inference. While the request is being decided,
    /// the report is latched and applied when it is held.
    public func liveWorkerDidFail(sessionID: UUID) {
        let effects = requiredEffects
        if queue.currentSessionID == sessionID {
            liveFailureDuringAttempt = sessionID
            return
        }
        guard !effects.pausesProcessing,
              queue.wakeHeldFinalization(sessionID: sessionID) else { return }
        startDrainIfIdle()
    }

    /// The explicit resume: releases paused work and every inference hold whose condition has ended.
    public func resumeHeldProcessing() {
        resumeHeld(releasesPauses: true)
    }

    /// Moves only the inference holds whose condition has ended; paused work waits for the explicit resume.
    private func resumeEndedInferenceHolds() {
        resumeHeld(releasesPauses: false)
    }

    private func resumeHeld(releasesPauses: Bool) {
        let effects = requiredEffects
        guard queue.resumeHeld(
            activeInferenceHold: currentHoldReason, releasesPauses: releasesPauses,
            pausesProcessing: effects.pausesProcessing
        ) else {
            return
        }
        effects.prepareModels()
        startDrainIfIdle()
    }

    private func holdForModels(_ request: PendingProcessing) {
        let effects = requiredEffects
        queue.holdForModels(request)
        effects.processingDidChange(.heldForModels(queue.summary(
            for: request, holdReason: .models
        )))
    }

    /// Called when the models become ready. The held work runs in its original order.
    public func resumeModelHeldProcessing() {
        let effects = requiredEffects
        guard queue.resumeModelHeld(
            modelsReady: effects.modelsReady,
            pausesProcessing: effects.pausesProcessing
        ) else {
            return
        }
        startDrainIfIdle()
    }

    public static func recoveryRequests(
        candidates: [RecoverableSession],
        recordingSessionID: UUID?,
        maintenanceFailures: [UUID: SessionMaintenanceIssue],
        occupiedSessionIDs: Set<UUID>
    ) -> [PendingProcessing] {
        candidates
            .filter { $0.manifest.sessionID != recordingSessionID }
            .filter { maintenanceFailures[$0.manifest.sessionID] == nil }
            .filter { !occupiedSessionIDs.contains($0.manifest.sessionID) }
            .compactMap { candidate in
                SessionRecoveryPlan(candidate.action)
                    .launchRecoveryRequest(sessionID: candidate.manifest.sessionID)
            }
    }

    public func recoverPendingSessions(
        effects recoveryEffects: any SessionRecoveryEffects,
        scan: @MainActor () throws -> SessionRecoveryScan,
        maintain: @Sendable (
            [SessionMaintenanceCandidate],
            @Sendable (Int) async -> Void
        ) async -> [UUID: SessionMaintenanceIssue]
    ) async {
        queue.beginStorageMaintenance()
        var recoveryClaims: Set<UUID> = []
        do {
            let recoveryScan = try scan()
            let maintenance = recoveryScan.maintenance.filter {
                $0.sessionID != recoveryEffects.recordingSessionID
            }
            recoveryClaims = Set(recoveryScan.candidates.map { $0.manifest.sessionID })
                .union(maintenance.map(\.sessionID))
            queue.claimRecovery(recoveryClaims)

            let previousStatus = recoveryEffects.recoveryStatusSnapshot
            let maintenanceCount = maintenance.count
            let effects = recoveryEffects
            let maintenanceFailures = await maintain(maintenance) { _ in
                await MainActor.run {
                    effects.recoveryDidChange(.maintenanceStarted(maintenanceCount))
                }
            }

            // Re-scan before admitting recovery: a generation changed since the initial scan invalidates its plan.
            let reconciledScan = try scan()
            let reconciledByID = Dictionary(
                uniqueKeysWithValues: reconciledScan.candidates.map { ($0.manifest.sessionID, $0) }
            )
            let unchangedCandidates = recoveryScan.candidates.filter { scanned in
                guard let current = reconciledByID[scanned.manifest.sessionID] else { return false }
                return scanned.generationID == current.generationID && scanned.action == current.action
            }
            var occupiedSessionIDs = Set(unchangedCandidates.compactMap { candidate -> UUID? in
                let sessionID = candidate.manifest.sessionID
                return queue.containsQueuedWork(sessionID)
                    || requiredEffects.hasLiveProcessingWorker(sessionID: sessionID)
                    ? sessionID : nil
            })
            if let recordingSessionID = recoveryEffects.recordingSessionID {
                occupiedSessionIDs.insert(recordingSessionID)
            }
            let recoveries = Self.recoveryRequests(
                candidates: unchangedCandidates,
                recordingSessionID: recoveryEffects.recordingSessionID,
                maintenanceFailures: maintenanceFailures,
                occupiedSessionIDs: occupiedSessionIDs
            )
            if !recoveries.isEmpty {
                recoveryEffects.recoveryDidChange(.recovering(recoveries.count))
            }
            for recovery in recoveries {
                enqueue(recovery)
            }

            if !maintenance.isEmpty {
                recoveryEffects.recoveryDidChange(
                    .maintenanceFinished(count: maintenance.count, previous: previousStatus)
                )
            }
            // Recovery requests are already queued while the maintenance gate remains closed.
            let compactedSessions = maintenance.filter {
                $0.maintenance == .compactRecording && maintenanceFailures[$0.sessionID] == nil
            }
            if !compactedSessions.isEmpty {
                // Auto-export re-reads the stale catalog before resolving each compacted source.
                requiredEffects.refreshSavedSessions()
            }
            for item in compactedSessions {
                guard !Task.isCancelled else { break }
                await requiredEffects.autoExportIfEnabled(sessionID: item.sessionID)
            }

            queue.releaseRecovery(recoveryClaims)
            recoveryClaims = []
            queue.endStorageMaintenance()
            if !queue.pending.isEmpty {
                startDrainIfIdle()
            }

            if !reconciledScan.failures.isEmpty || !maintenanceFailures.isEmpty {
                recoveryEffects.recoveryDidChange(
                    .reportedFailures(
                        scanFailures: reconciledScan.failures,
                        maintenanceFailures: maintenanceFailures,
                        hasRecoveries: !recoveries.isEmpty
                    )
                )
            }
        } catch {
            queue.releaseRecovery(recoveryClaims)
            queue.endStorageMaintenance()
            recoveryEffects.recoveryDidChange(.failed(error.localizedDescription))
            if !queue.pending.isEmpty {
                startDrainIfIdle()
            }
        }
    }

    public func retryDeferredDecisions(
        effects recoveryEffects: any SessionRecoveryEffects,
        scan: @MainActor () throws -> SessionRecoveryScan
    ) async {
        do {
            let candidates = try scan().candidates
            let requests = candidates.compactMap {
                SessionRecoveryPlan($0.action).decisionRetryRequest(sessionID: $0.manifest.sessionID)
            }
            for request in requests {
                enqueue(request)
            }
            if requests.isEmpty {
                recoveryEffects.recoveryDidChange(.retryEmpty)
            }
        } catch {
            recoveryEffects.recoveryDidChange(.retryFailed(error.localizedDescription))
        }
    }

    private func hasUnresolvedASRFailure(sessionID: UUID) async -> Bool {
        do {
            return try await processor.hasUnresolvedASRFailure(sessionID: sessionID)
        } catch {
            // Unknown is not a failure: the holds decide, and processing re-reads the log
            // and repairs a torn tail or reports the read error.
            return false
        }
    }

    /// The stored side of the shared per-segment gate: serious paces, critical pauses.
    private func pauseReasonBeforeSegment(at point: InferenceGatePoint) async throws -> InferenceHoldReason? {
        let thermal = try await thermalMonitor.inferenceGate(at: point, sleep: { try await Task.sleep(for: $0) })
        return holdReasonForAttempt() ?? thermal
    }

    private func discardLiveWorker(sessionID: UUID) async {
        await processor.cancelLiveTranscription(sessionID: sessionID)
        requiredEffects.cleanupLiveASRState(sessionID: sessionID)
    }

    private func releaseHeldResources() async {
        guard let resourceHolds else {
            preconditionFailure("リソース監視中の一時停止に解放処理が設定されていません")
        }
        await resourceHolds.release()
    }

    private var requiredEffects: any SessionProcessingEffects {
        guard let effects else {
            preconditionFailure("セッション処理の効果提供元が解放されています")
        }
        return effects
    }

    private func drainProcessingQueue() async {
        let effects = requiredEffects
        await effects.awaitIdleRelease()
        while !effects.pausesProcessing,
              !Task.isCancelled,
              let request = queue.dequeue() {
            activeResourceHoldReason = nil
            liveFailureDuringAttempt = nil
            let requestSessionID = request.sessionID
            var begun = false
            // Thermal holds at dequeue and keeps the live worker: a drain that waits for cooling would block the queue.
            // A durable ASR failure is the exception: processing persists it as failed without inference. The request
            // is current while the probe awaits, so a queue count sees it once.
            if request.finalizesTranscript, currentHoldReason == .thermal {
                queue.begin(request)
                begun = true
                var knownFailure = false
                if case .finalize(_, let sessionID, let policy) = request,
                   !policy.isReplacement || policy.replacementGeneration != .notOpened {
                    knownFailure = await hasUnresolvedASRFailure(sessionID: sessionID)
                }
                if !knownFailure, currentHoldReason == .thermal {
                    queue.completeCurrent()
                    hold(request, for: .thermal)
                    continue
                }
            }
            if !begun { queue.begin(request) }
            effects.processingDidChange(.began(queue.summary(for: request, holdReason: nil)))

            let statusHandler = effects.processingStatusHandler(sessionID: requestSessionID)
            let updateHandler = effects.processingUpdateHandler(sessionID: requestSessionID)
            let shouldPause: NativeSessionProcessor.PauseCheck = { [self] point in
                try await pauseReasonBeforeSegment(at: point)
            }

            var finalization: SessionProcessingResult?
            var isCurrent = true
            switch request {
            case .finalize(_, let sessionID, let metadataPolicy):
                // Stop is a drain: a recording's live worker is finished in place, any other input is reopened.
                let drainOutcome = await effects.waitForLiveASRDrain(sessionID: sessionID)
                if let failure = effects.liveASRFailure(sessionID: sessionID) {
                    effects.processingDidChange(.liveFailed(failure))
                }
                // Admission is decided once, here, after the drain. A durable ASR failure comes first:
                // processing persists it and reports failed, so no hold hides it.
                var knownFailure = false
                if !metadataPolicy.isReplacement || metadataPolicy.replacementGeneration != .notOpened {
                    knownFailure = await hasUnresolvedASRFailure(sessionID: sessionID)
                }
                // The hold inputs are read after the probe, so pressure that arrived during it counts.
                // A held request moves from current to its hold list in one step before the worker cleanup
                // awaits: a readiness or resume callback during the cleanup finds it there, and it is never
                // counted twice.
                let resourceReason = holdReasonForAttempt().flatMap { $0 == .thermal ? nil : $0 }
                let stopped = Task.isCancelled || effects.pausesProcessing
                // Heat that rose after dequeue parks the request with its live worker, which waits for cooling.
                let keepsWorker = drainOutcome == .suspendedForCooling && resourceReason == nil && !stopped
                if !knownFailure, resourceReason == nil, !stopped, !keepsWorker, !effects.modelsReady {
                    // Waiting for the models is not an outcome: the request finishes when it really runs.
                    queue.completeCurrent()
                    holdForModels(request)
                    await discardLiveWorker(sessionID: sessionID)
                    effects.refreshSavedSessions()
                    continue
                }
                if !knownFailure, stopped || resourceReason != nil || keepsWorker {
                    queue.completeCurrent()
                    isCurrent = false
                    // A pause wins: it waits for the explicit resume even while an inference hold applies too.
                    let reason = stopped ? nil : keepsWorker ? InferenceHoldReason.thermal : resourceReason
                    hold(request, for: reason)
                    finalization = SessionProcessingResult(
                        disposition: .paused, metrics: nil, message: reason?.finalizationExplanation,
                        noSpeech: false, replacementGeneration: metadataPolicy.replacementGeneration
                    )
                    if let reason { await statusHandler(.paused(reason)) }
                    if !keepsWorker { await discardLiveWorker(sessionID: sessionID) }
                } else {
                    let result = await processor.processSession(
                        sessionID: sessionID,
                        pacingMode: .normal,
                        shouldPause: shouldPause,
                        onPhase: { _ in },
                        metadataPolicy: metadataPolicy,
                        onStatus: statusHandler,
                        onUpdate: updateHandler,
                        onGenerationOpened: { generationID in
                            effects.processingGenerationDidOpen(
                                sessionID: sessionID, generationID: generationID
                            )
                        }
                    )
                    effects.cleanupLiveASRState(sessionID: sessionID)
                    if result.disposition == .paused {
                        queue.completeCurrent()
                        isCurrent = false
                        hold(request, for: result.pauseReason)
                    } else {
                        queue.releaseReprocessing(sessionID)
                    }
                    finalization = result
                }
                effects.refreshSavedSessions()
            case .retryContentPriority(_, let sessionID, let boundarySegments, let clauses):
                if Task.isCancelled || effects.pausesProcessing {
                    queue.completeCurrent()
                    isCurrent = false
                    hold(request, for: nil)
                    finalization = SessionProcessingResult(
                        disposition: .paused,
                        metrics: nil,
                        message: nil,
                        noSpeech: false,
                        replacementGeneration: .notOpened
                    )
                } else {
                    let result = await processor.retryContentPrioritySession(
                        sessionID: sessionID,
                        boundarySegments: boundarySegments,
                        clauses: clauses,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                    switch result.disposition {
                    case .failed:
                        // Durable terminal retry outcomes win over a late pause or cancellation.
                        finalization = result
                    case .completed:
                        // A successful retry has no finalization, so it cannot trigger auto-export.
                        finalization = nil
                    case .paused:
                        queue.completeCurrent()
                        isCurrent = false
                        hold(request, for: result.pauseReason)
                        finalization = result
                    }
                    effects.refreshSavedSessions()
                }
            }

            if request.finalizesTranscript, finalization?.disposition == .paused,
               let reason = holdReasonForAttempt(), reason != .thermal {
                await releaseHeldResources()
                queue.resourceCleanupDidFinish(requestID: request.requestID)
            }

            effects.processingDidChange(.finished(queue.summary(
                for: request, holdReason: queue.completionHold(for: request.requestID)
            ), finalization))
            if !queue.pending.isEmpty {
                effects.processingDidChange(.next)
            }
            if finalization?.disposition == .completed,
               !Task.isCancelled,
               !effects.pausesProcessing {
                await effects.autoExportIfEnabled(sessionID: requestSessionID)
            }
            if isCurrent { queue.completeCurrent(terminal: true) }
        }

        effects.processingDidChange(.willFinishDrain)
        task = nil
        effects.processingDidChange(.drained)
        if !Task.isCancelled,
           !effects.pausesProcessing,
           currentHoldReason == nil,
           !queue.held.isEmpty {
            resumeEndedInferenceHolds()
        }
    }
}
