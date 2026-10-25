import Foundation
import MacAmbientJevCore

public protocol SessionProcessingExecuting: Sendable {
    func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult

    func finishLiveTranscription(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        finalSegments: [SegmentReference],
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult

    func cancelLiveTranscription(sessionID: UUID) async
}

extension NativeSessionProcessor: SessionProcessingExecuting {}

public enum SessionProcessingEvent {
    case backlogged
    case held(PendingProcessing)
    case began(PendingProcessing)
    case liveFailed(String)
    case finished(PendingProcessing, SessionProcessingResult?)
    case next
    case willFinishDrain
    case drained
}

@MainActor
public protocol SessionProcessingEffects: AnyObject {
    var processingQueue: SessionProcessingQueue { get set }
    var pausesProcessing: Bool { get }

    func prepareASRModel()
    func awaitIdleRelease() async
    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler
    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler
    func waitForLiveASRDrain(sessionID: UUID) async
    func liveASRFailure(sessionID: UUID) -> String?
    func cleanupLiveASRState(sessionID: UUID)
    func refreshSavedSessions()
    func autoExportIfEnabled(sessionID: UUID) async
    func processingDidChange(_ event: SessionProcessingEvent)
}

@MainActor
public final class SessionProcessingCoordinator {
    private weak var effects: (any SessionProcessingEffects)?
    private let processor: any SessionProcessingExecuting
    private let thermalMonitor: any ThermalMonitoring
    private var task: Task<Void, Never>?

    public init(
        effects: any SessionProcessingEffects,
        processor: any SessionProcessingExecuting,
        thermalMonitor: any ThermalMonitoring
    ) {
        self.effects = effects
        self.processor = processor
        self.thermalMonitor = thermalMonitor
    }

    public var isDraining: Bool { task != nil }

    public func requestPause() {
        task?.cancel()
    }

    func waitUntilIdle() async {
        while let task {
            await task.value
        }
    }

    public func enqueue(_ request: SessionFinalizeRequest) {
        enqueue(request.pending)
    }

    public func enqueue(_ request: PendingProcessing) {
        let effects = requiredEffects
        if !effects.pausesProcessing, request.finalizesTranscript {
            effects.prepareASRModel()
        }

        effects.processingQueue.enqueue(request)
        guard !effects.pausesProcessing, !effects.processingQueue.isMaintainingStorage else { return }

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
              !effects.processingQueue.isMaintainingStorage else {
            return
        }
        task = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    private func holdForHeat(_ request: PendingProcessing) {
        let effects = requiredEffects
        effects.processingQueue.holdForHeat(request)
        effects.processingDidChange(.held(request))
    }

    public func resumeThermallyHeldProcessing() {
        let effects = requiredEffects
        guard effects.processingQueue.resumeHeld(
            isCritical: thermalMonitor.isCritical,
            pausesProcessing: effects.pausesProcessing
        ) else {
            return
        }
        effects.prepareASRModel()
        startDrainIfIdle()
    }

    public static func recoveryRequests(
        candidates: [RecoverableSession],
        recordingSessionID: UUID?,
        maintenanceFailures: [UUID: SessionMaintenanceIssue],
        pending: [PendingProcessing]
    ) -> [PendingProcessing] {
        candidates
            .filter { $0.manifest.sessionID != recordingSessionID }
            .filter { maintenanceFailures[$0.manifest.sessionID] == nil }
            .filter { candidate in
                !pending.contains { $0.sessionID == candidate.manifest.sessionID }
            }
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
        requiredEffects.processingQueue.beginStorageMaintenance()
        do {
            let recoveryScan = try scan()
            let maintenance = recoveryScan.maintenance.filter {
                $0.sessionID != recoveryEffects.recordingSessionID
            }
            let previousStatus = recoveryEffects.recoveryStatusSnapshot
            let maintenanceCount = maintenance.count
            let effects = recoveryEffects
            let maintenanceFailures = await maintain(maintenance) { _ in
                await MainActor.run {
                    effects.recoveryDidChange(.maintenanceStarted(maintenanceCount))
                }
            }
            requiredEffects.processingQueue.endStorageMaintenance()
            if !maintenance.isEmpty {
                recoveryEffects.recoveryDidChange(
                    .maintenanceFinished(count: maintenance.count, previous: previousStatus)
                )
            }

            let recoveries = Self.recoveryRequests(
                candidates: recoveryScan.candidates,
                recordingSessionID: recoveryEffects.recordingSessionID,
                maintenanceFailures: maintenanceFailures,
                pending: requiredEffects.processingQueue.pending
            )
            if !recoveries.isEmpty {
                recoveryEffects.recoveryDidChange(.recovering(recoveries.count))
            }
            for recovery in recoveries {
                enqueue(recovery)
            }
            if !requiredEffects.processingQueue.pending.isEmpty {
                startDrainIfIdle()
            }

            if !recoveryScan.failures.isEmpty || !maintenanceFailures.isEmpty {
                recoveryEffects.recoveryDidChange(
                    .reportedFailures(
                        scanFailures: recoveryScan.failures,
                        maintenanceFailures: maintenanceFailures,
                        hasRecoveries: !recoveries.isEmpty
                    )
                )
            }
        } catch {
            requiredEffects.processingQueue.endStorageMaintenance()
            recoveryEffects.recoveryDidChange(.failed(error.localizedDescription))
            if !requiredEffects.processingQueue.pending.isEmpty {
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
              let request = effects.processingQueue.dequeue() {
            if request.finalizesTranscript, thermalMonitor.isCritical {
                holdForHeat(request)
                continue
            }

            let requestSessionID = request.sessionID
            effects.processingQueue.begin(request)
            effects.processingDidChange(.began(request))

            let statusHandler = effects.processingStatusHandler(sessionID: requestSessionID)
            let updateHandler = effects.processingUpdateHandler(sessionID: requestSessionID)
            let shouldPause: NativeSessionProcessor.PauseCheck = { [thermalMonitor] in
                thermalMonitor.isCritical
            }

            let finalization: SessionProcessingResult?
            switch request {
            case .finalize(let sessionID, let metadataPolicy):
                let result = await processor.processSession(
                    sessionID: sessionID,
                    pacingMode: .normal,
                    shouldPause: shouldPause,
                    onPhase: { _ in },
                    metadataPolicy: metadataPolicy,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
                if result.disposition == .paused {
                    holdForHeat(request)
                } else {
                    effects.processingQueue.releaseReprocessing(sessionID)
                }
                effects.refreshSavedSessions()
                finalization = result
            case .finishLive(let sessionID, let checkpoint):
                await effects.waitForLiveASRDrain(sessionID: sessionID)

                if Task.isCancelled || effects.pausesProcessing {
                    await processor.cancelLiveTranscription(sessionID: sessionID)
                    effects.cleanupLiveASRState(sessionID: sessionID)
                    holdForHeat(.finalize(
                        sessionID: sessionID,
                        metadataPolicy: .reject
                    ))
                    finalization = SessionProcessingResult(
                        disposition: .paused,
                        metrics: nil,
                        message: nil,
                        noSpeech: false,
                        retainedTranscript: nil
                    )
                } else {
                    if let failure = effects.liveASRFailure(sessionID: sessionID) {
                        await processor.cancelLiveTranscription(sessionID: sessionID)
                        effects.processingDidChange(.liveFailed(failure))
                    }
                    let result = await processor.finishLiveTranscription(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        finalSegments: [],
                        pacingMode: .normal,
                        shouldPause: shouldPause,
                        onPhase: { _ in },
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                    effects.cleanupLiveASRState(sessionID: sessionID)
                    if result.disposition == .paused {
                        holdForHeat(.finalize(
                            sessionID: sessionID,
                            metadataPolicy: .reject
                        ))
                    }
                    finalization = result
                }
            case .retryContentPriority(let sessionID, let boundarySegments, let clauses):
                if Task.isCancelled || effects.pausesProcessing {
                    holdForHeat(request)
                    finalization = SessionProcessingResult(
                        disposition: .paused,
                        metrics: nil,
                        message: nil,
                        noSpeech: false,
                        retainedTranscript: nil
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
                        holdForHeat(request)
                        finalization = result
                    }
                    effects.refreshSavedSessions()
                }
            }

            effects.processingDidChange(.finished(request, finalization))
            if !effects.processingQueue.pending.isEmpty {
                effects.processingDidChange(.next)
            }
            if finalization?.disposition == .completed,
               !Task.isCancelled,
               !effects.pausesProcessing {
                await effects.autoExportIfEnabled(sessionID: requestSessionID)
            }
            effects.processingQueue.completeCurrent()
        }

        effects.processingDidChange(.willFinishDrain)
        task = nil
        effects.processingDidChange(.drained)
    }
}
