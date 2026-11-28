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
                 .detectingSpeech, .preparingASR, .loadingASR, .asrBacklogged,
                 .classifyingContent, .decisionDeferred:
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

    /// Queued work waits for settings and a configured processor, and stops for good once shutdown begins.
    var pausesProcessing: Bool {
        isShuttingDown || setupStatus != .ready
    }

    /// Finalizing work waits in the queue's model hold until the models are prepared and no recording is active.
    var modelsReady: Bool { modelsPrepared && recording.phase == .idle }

    func awaitIdleRelease() async {
        await idleReleaseTask?.value
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { [weak self] status in
            let text = Self.processorPresentationText(status)
            await MainActor.run { self?.processingStatusDidChange(text, sessionID: sessionID) }
        }
    }

    func processingGenerationDidOpen(sessionID: UUID, generationID: UUID) {
        transcriptDidSelectGeneration(sessionID: sessionID, generationID: generationID)
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

    func waitForLiveASRDrain(sessionID: UUID) async -> LiveASRDrainOutcome {
        await liveCoordinator.waitForDrain(sessionID: sessionID)
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveTranscription.failure(sessionID: sessionID)
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveCoordinator.cleanup(sessionID: sessionID)
    }

    func hasLiveProcessingWorker(sessionID: UUID) -> Bool {
        liveCoordinator.hasWork(sessionID: sessionID)
    }

    func autoExportIfEnabled(sessionID: UUID) async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        guard let settings, settings.automaticExport else { return }
        guard let destination = settings.exportDestinationPath else {
            report(EngineFailures.failure(
                code: .exportFailure, message: "自動書き出しは有効ですが、書き出し先が設定されていません", stage: .exporting,
                sessionID: sessionID, severity: .error, recoveryAction: .replaceSettings
            ))
            return
        }
        do {
            let session = try await readableSession(sessionID)
            guard session.hasActiveTranscript else { return }
            switch session.processingStatus {
            case .complete, .classificationPending:
                _ = try await exportBundle(session, to: URL(fileURLWithPath: destination, isDirectory: true))
            case .notProcessed, .running, .paused, .failed, .corrupted:
                break
            }
        } catch {
            guard !isShuttingDown, !Task.isCancelled else { return }
            let command = EngineFailures.commandError(from: error, fallback: .exportFailure, stage: .exporting, sessionID: sessionID)
            report(command.failure(requestID: nil))
        }
    }

    func processingQueueDidChange(_ snapshot: ProcessingQueueSnapshot) {}

    func processingDidChange(_ event: SessionProcessingEvent) {
        switch event {
        case .backlogged:
            presentation.processingState = .backlogged
            presentation.processingStatusText = "文字起こし処理が待機中です"
        case let .held(item):
            presentation.processingState = .idle
            presentation.processingStatusText = "処理は中断されました。次回の起動時に再開できます"
            if let reason = resourceHoldReason(sessionID: item.sessionID) {
                presentation.processingStatusText = reason.finalizationExplanation
            }
            if item.holdReason == .paused {
                completions.finish(requestID: item.requestID, with: .paused)
            } else if !isShuttingDown, item.kind == .replacement, isResourceHold(item),
                      let error = monitorFailureError(sessionID: item.sessionID) {
                completions.finish(requestID: item.requestID, with: error)
            }
            if item.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .heldForModels(item):
            presentation.processingState = .idle
            presentation.processingStatusText = ModelPreparationStatus.waitingForModelsText
            if item.kind == .replacement,
               let error = modelPreparationError(sessionID: item.sessionID) {
                completions.finish(requestID: item.requestID, with: error)
            }
            if item.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .began(item):
            presentation.processingState = .running
            resourceFinalizingSessionID = item.kind == .decisionRetry ? nil : item.sessionID
            finalizationResourceHoldReason = nil
            if item.kind != .decisionRetry, item.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .liveFailed(message):
            let notice = "ライブ文字起こしは停止しました: \(message)"
            addLiveFailureNotice(notice)
            report(EngineFailures.failure(
                code: .processingFailure, message: notice,
                stage: .asr, sessionID: nil, severity: .warning, recoveryAction: .none
            ))
        case let .finished(item, result):
            finished(item, result: result)
        case .next:
            presentation.processingState = .backlogged
            presentation.processingStatusText = "次の文字起こし処理を開始します"
        case .willFinishDrain:
            if presentation.processingState == .running || presentation.processingState == .backlogged,
               processingQueue.summaries.isEmpty,
               !pausesProcessing {
                presentation.processingState = .complete
            }
        case .drained:
            resourceFinalizingSessionID = nil
            finalizationResourceHoldReason = nil
            releaseIdleResourcesIfIdle()
        }
        stateDidChange()
    }

    private func finished(_ item: ProcessingQueueItemSummary, result: SessionProcessingResult?) {
        processingCompletionEpoch += 1
        resourceFinalizingSessionID = nil
        finalizationResourceHoldReason = nil
        let sessionID = item.sessionID
        recoveryOutstanding.remove(sessionID)
        updateRecoveryStatus()
        savedSessionsAreStale = true
        savedSessionsVersion += 1
        switch result?.disposition {
        case .completed?:
            clearFailures(sessionID: sessionID)
            transcriptEpoch += 1
            if item.kind != .decisionRetry {
                finalPublishedSessionIDs.insert(sessionID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.transcriptDidPublish(sessionID: sessionID)
                }
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
                stage: item.kind == .decisionRetry ? .decisions : .finalization, sessionID: sessionID,
                severity: .error, recoveryAction: item.kind == .decisionRetry ? .retryDecisions : .reprocess
            ))
        case .paused?, nil:
            guard result?.disposition == .paused,
                  let reason = resourceHoldReason(sessionID: sessionID) else { break }
            presentation.processingState = .idle
            presentation.processingStatusText = reason.finalizationExplanation
        }
        if !isShuttingDown,
           result?.disposition == .paused,
           item.kind == .replacement,
           isResourceHold(item),
           let error = monitorFailureError(sessionID: sessionID) {
            completions.finish(requestID: item.requestID, with: error)
        }
        completions.finished(item, result: result, isShutdownCancellation: isShuttingDown)
    }

    private func isResourceHold(_ item: ProcessingQueueItemSummary) -> Bool {
        guard case let .inference(reason)? = item.holdReason else { return false }
        return reason == .resourcePressure || reason == .monitorFailed
    }

    /// The resource reason a held request waits for, if it waits for one.
    private func resourceHoldReason(sessionID: UUID) -> InferenceHoldReason? {
        guard let hold = processingQueue.summaries.first(where: { $0.sessionID == sessionID })?.holdReason,
              case .inference(let reason) = hold,
              reason == .resourcePressure || reason == .monitorFailed else { return nil }
        return reason
    }

    private func processingStatusDidChange(_ text: String, sessionID: UUID) {
        if resourceFinalizingSessionID == sessionID, let reason = finalizationResourceHoldReason {
            // The coordinator's own paused status means the run has already stopped.
            presentation.processingStatusText = text == reason.finalizationExplanation
                ? text : reason.finalizationExplanation + "（実行中の処理の終了待ち）"
        } else {
            presentation.processingStatusText = text
        }
        stateDidChange()
        let stage: EngineStage
        switch text {
        case UserFacingStatus.convertingTimeline.text: stage = .importing
        case UserFacingStatus.detectingSpeech.text: stage = .vad
        case UserFacingStatus.preparingASR.text, UserFacingStatus.loadingASR.text: stage = .loadingModels
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
    /// Unloads the ASR model once the engine is idle; it loads again on next use.
    func releaseIdleResourcesIfIdle() {
        guard isIdle, idleReleaseTask == nil, !isShuttingDown else { return }
        idleReleaseTask = Task { [self] in
            if isIdle {
                if modelPreparationFailure == nil {
                    presentation.preparationPhase = .idle
                    presentation.preparationStatusText = nil
                }
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
        recoveryOutstanding = Set(processingQueue.summaries
            .filter { $0.holdReason == .pending || $0.holdReason == nil }
            .map(\.sessionID))
        savedSessionsAreStale = true
        savedSessionsVersion += 1
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
