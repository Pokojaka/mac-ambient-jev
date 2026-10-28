import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

// MARK: SessionProcessingEffects

extension EngineApplicationCore: SessionProcessingEffects {
    nonisolated static func processorPresentationText(_ status: NativeSessionProcessor.Status) -> String {
        switch status {
        case let .message(text):
            return text
        case let .activity(activity):
            switch activity {
            case .finalizationPausedForHeat, .liveTranscriptionThermalSuspended:
                preconditionFailure("Windows engine cannot present a thermal processor status")
            case .idle, .checkingMicrophone, .startingRecording, .importingAudio, .convertingTimeline,
                 .detectingSpeech, .preparingASR, .loadingASR, .asrBacklogged, .preparingDiarization,
                 .diarizing, .classifyingContent, .decisionDeferred:
                return activity.text
            }
        case let .paused(reason):
            switch reason {
            case .thermal:
                preconditionFailure("Windows engine cannot present a thermal processor status")
            case .resourcePressure, .monitorFailed:
                return reason.finalizationExplanation
            }
        }
    }

    /// Queued work waits for settings and prepared models, and stops for good once shutdown begins.
    var pausesProcessing: Bool {
        isShuttingDown || setupStatus != .ready
    }

    /// Models load on first use, so there is nothing to warm up when work is queued.
    func prepareASRModel() {}

    func awaitIdleRelease() async {
        await idleReleaseTask?.value
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { [weak self] status in
            let text = Self.processorPresentationText(status)
            await MainActor.run { self?.processingStatusDidChange(text, sessionID: sessionID) }
        }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self else { return }
                self.transcriptDidUpdate(sessionID: sessionID, segments: segments)
                self.presentation.processingState = state
                self.stateDidChange()
                self.reportProgress(sessionID: sessionID, stage: .asr, completedUnits: segments.count)
                if case let .partialFailure(message) = state {
                    self.report(EngineFailures.failure(
                        code: .processingFailure, message: message, stage: .finalization, sessionID: sessionID,
                        severity: .warning, recoveryAction: .reprocess
                    ))
                }
            }
        }
    }

    func waitForLiveASRDrain(sessionID: UUID) async {
        await liveCoordinator.waitForDrain(sessionID: sessionID)
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveTranscription.failure(sessionID: sessionID)
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveCoordinator.cleanup(sessionID: sessionID)
    }

    func autoExportIfEnabled(sessionID: UUID) async {
        guard !pausesProcessing, !Task.isCancelled else { return }
        guard let settings, settings.automaticExport else { return }
        guard let destination = settings.exportDestinationPath else {
            report(EngineFailures.failure(
                code: .exportFailure, message: "自動書き出しは有効ですが、書き出し先が設定されていません", stage: .exporting,
                sessionID: sessionID, severity: .error, recoveryAction: .replaceSettings
            ))
            return
        }
        do {
            let session = try readableSession(sessionID)
            guard session.hasActiveTranscript else { return }
            switch session.processingStatus {
            case .complete, .classificationPending:
                _ = try await exportBundle(session, to: URL(fileURLWithPath: destination, isDirectory: true))
            case .notProcessed, .running, .paused, .failed, .corrupted:
                break
            }
        } catch {
            guard !pausesProcessing, !Task.isCancelled else { return }
            let command = EngineFailures.commandError(from: error, fallback: .exportFailure, stage: .exporting, sessionID: sessionID)
            report(command.failure(requestID: nil))
        }
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        switch event {
        case .backlogged:
            presentation.processingState = .backlogged
            presentation.processingStatusText = "文字起こし処理が待機中です"
        case let .held(request):
            presentation.processingState = .idle
            presentation.processingStatusText = "処理は中断されました。次回の起動時に再開できます"
            if request.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .began(request):
            presentation.processingState = .running
            if request.finalizesTranscript, request.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .liveFailed(message):
            let notice = "ライブ文字起こしは停止しました。録音全体を確定処理します: \(message)"
            addLiveFailureNotice(notice)
            report(EngineFailures.failure(
                code: .processingFailure, message: notice,
                stage: .asr, sessionID: nil, severity: .warning, recoveryAction: .none
            ))
        case let .finished(request, result):
            finished(request, result: result)
        case .next:
            presentation.processingState = .backlogged
            presentation.processingStatusText = "次の文字起こし処理を開始します"
        case .willFinishDrain:
            if presentation.processingState == .running || presentation.processingState == .backlogged,
               processingQueue.held.isEmpty,
               processingQueue.pending.isEmpty,
               !pausesProcessing {
                presentation.processingState = .complete
            }
        case .drained:
            releaseIdleResourcesIfIdle()
        }
        stateDidChange()
    }

    private func finished(_ request: PendingProcessing, result: SessionProcessingResult?) {
        let sessionID = request.sessionID
        recoveryOutstanding.remove(sessionID)
        updateRecoveryStatus()
        savedSessionsAreStale = true
        switch result?.disposition {
        case .completed?:
            clearFailures(sessionID: sessionID)
            if request.finalizesTranscript {
                transcriptDidPublish(sessionID: sessionID)
                if sessionID == watchedSessionID { watchedSessionIsFinal = true }
            }
        case .failed?:
            guard let result else {
                preconditionFailure("Failed processing result is missing")
            }
            guard let message = result.message, !message.isEmpty else {
                preconditionFailure("Failed processing result message is missing or empty")
            }
            presentation.processingState = .partialFailure(message)
            if presentation.processingStatusText?.contains(message) != true {
                presentation.processingStatusText = message
            }
            report(EngineFailures.failure(
                code: .processingFailure, message: message,
                stage: request.finalizesTranscript ? .finalization : .decisions, sessionID: sessionID,
                severity: .error, recoveryAction: request.finalizesTranscript ? .reprocess : .retryDecisions
            ))
        case .paused?, nil:
            break
        }
        completions.finished(request, result: result)
    }

    private func processingStatusDidChange(_ text: String, sessionID: UUID) {
        presentation.processingStatusText = text
        stateDidChange()
        let stage: EngineStage
        switch text {
        case UserFacingStatus.convertingTimeline.text: stage = .importing
        case UserFacingStatus.detectingSpeech.text: stage = .vad
        case UserFacingStatus.preparingASR.text, UserFacingStatus.loadingASR.text: stage = .loadingModels
        case UserFacingStatus.preparingDiarization.text, UserFacingStatus.diarizing.text: stage = .diarization
        case UserFacingStatus.classifyingContent.text, UserFacingStatus.decisionDeferred.text: stage = .decisions
        default: stage = .finalization
        }
        reportProgress(sessionID: sessionID, stage: stage, completedUnits: 0)
    }

    func reportProgress(sessionID: UUID, stage: EngineStage, completedUnits: Int) {
        guard eventsEnabled else { return }
        do {
            try events.progress(
                EngineProgressPayload(
                    stage: stage, completedUnits: UInt64(completedUnits), totalUnits: nil,
                    sessionID: EngineFailures.wireID(sessionID)
                ),
                requestID: nil
            )
        } catch {
            EngineLog.write("progress not sent: \(error)")
        }
    }
}

// MARK: Idle release

extension EngineApplicationCore {
    /// Unloads the ASR and diarization models once the engine is idle; they load again on next use.
    func releaseIdleResourcesIfIdle() {
        guard isIdle, idleReleaseTask == nil, !isShuttingDown else { return }
        idleReleaseTask = Task { [self] in
            if isIdle {
                presentation.preparationPhase = .idle
                presentation.preparationStatusText = nil
                stateDidChange()
                await gateway.releaseIdleResources()
            }
            idleReleaseTask = nil
        }
    }
}

// MARK: Startup recovery

extension EngineApplicationCore {
    var recoveryStatusSnapshot: SessionRecoveryStatusSnapshot {
        SessionRecoveryStatusSnapshot(processing: presentation.recoveryStatusText, transcript: "")
    }

    func recoveryDidChange(_ event: SessionRecoveryEvent) {
        switch event {
        case let .maintenanceStarted(count):
            presentation.recoveryStatusText = SessionRecoveryEvent.maintenanceStatusText(count: count)
        case let .maintenanceFinished(count, previous):
            let text = SessionRecoveryEvent.maintenanceStatusText(count: count)
            if presentation.recoveryStatusText == text {
                presentation.recoveryStatusText = previous.processing
            }
        case let .recovering(count):
            presentation.recoveryStatusText = "未完了の文字起こしを復旧しています（\(count)件）"
        case let .reportedFailures(scanFailures, maintenanceFailures, hasRecoveries):
            let failureReport = SessionRecoveryFailureReport(
                scanFailures: scanFailures,
                maintenanceFailures: maintenanceFailures,
                hasRecoveries: hasRecoveries
            )
            guard !failureReport.message.isEmpty else {
                preconditionFailure("Reported recovery failures must include at least one issue")
            }
            if failureReport.marksPartialFailure {
                presentation.processingState = .partialFailure(failureReport.message)
            }
            presentation.recoveryStatusText = failureReport.message

            for failure in scanFailures {
                report(EngineFailures.failure(
                    code: .filesystem, message: "復旧できないセッションがあります: \(failure.message)", stage: .recovery,
                    sessionID: nil, severity: .error, recoveryAction: .inspectSession,
                    details: [EngineFailures.detail(
                        domain: "recovery", code: "scan", message: failure.message, path: failure.sessionURL.path
                    )]
                ))
            }
            for (sessionID, issue) in maintenanceFailures.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let failure: EngineFailure
                switch issue {
                case .failed:
                    failure = EngineFailures.failure(
                        code: .filesystem, message: "保存済み録音の音声を整理できませんでした: \(issue.message)", stage: .maintenance,
                        sessionID: sessionID, severity: .error, recoveryAction: .inspectSession
                    )
                case .interruptedByShutdown:
                    failure = EngineFailures.failure(
                        code: .cancelled,
                        message: issue.message,
                        stage: .maintenance, sessionID: sessionID, severity: .warning, recoveryAction: .restart
                    )
                }
                report(failure)
            }
        case let .failed(reason):
            scanFailed = true
            presentation.processingState = .partialFailure(reason)
            presentation.recoveryStatusText = "未完了セッションを復旧できませんでした: \(reason)"
            report(EngineFailures.failure(
                code: .filesystem, message: "未完了セッションを復旧できませんでした: \(reason)", stage: .recovery,
                sessionID: nil, severity: .error, recoveryAction: .restart
            ))
        case .retryEmpty:
            preconditionFailure("Windows engine does not retry deferred decisions through recovery events")
        case .retryFailed:
            preconditionFailure("Windows engine does not retry deferred decisions through recovery events")
        }
        stateDidChange()
    }

    func runStartupRecovery() async {
        let sessionsRoot = paths.sessionsRoot
        await processingCoordinator.recoverPendingSessions(
            effects: self,
            scan: { try SessionRecoveryScanner(sessionsRoot: sessionsRoot).pendingSessions() },
            maintain: { items, willMaintain in
                await SessionStorageMaintainer.maintain(items, willMaintain: willMaintain)
            }
        )
        recoveryOutstanding = Set(processingQueue.pending.map(\.sessionID))
            .union(processingQueue.currentSessionID.map { [$0] } ?? [])
        savedSessionsAreStale = true
        updateRecoveryStatus()
        stateDidChange()
    }

    func updateRecoveryStatus() {
        guard startupTask != nil else { return }
        if scanFailed {
            recoveryStatus = .failed
        } else if processingQueue.isMaintainingStorage {
            recoveryStatus = .running
        } else if recoveryOutstanding.isEmpty {
            recoveryStatus = .completed
        } else {
            recoveryStatus = setupStatus == .ready ? .running : .pending
        }
        if recoveryStatus == .completed,
           presentation.recoveryStatusText?.hasPrefix("未完了の文字起こしを復旧しています（") == true {
            presentation.recoveryStatusText = nil
        }
    }
}
