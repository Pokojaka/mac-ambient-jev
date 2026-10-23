import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

// MARK: SessionProcessingEffects

extension EngineApplicationCore: SessionProcessingEffects {
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
        { [weak self] text in
            await MainActor.run { self?.processingStatusDidChange(text, sessionID: sessionID) }
        }
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self else { return }
                self.transcriptDidUpdate(sessionID: sessionID, segments: segments)
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
        case .backlogged, .next, .willFinishDrain:
            break
        case let .held(request):
            if request.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .began(request):
            if request.finalizesTranscript, request.sessionID == watchedSessionID { watchedSessionIsFinal = false }
        case let .liveFailed(message):
            report(EngineFailures.failure(
                code: .processingFailure, message: "ライブ文字起こしは停止しました。録音全体を確定処理します: \(message)",
                stage: .asr, sessionID: nil, severity: .warning, recoveryAction: .none
            ))
        case let .finished(request, result):
            finished(request, result: result)
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
            report(EngineFailures.failure(
                code: .processingFailure, message: result?.message ?? "処理に失敗しました",
                stage: request.finalizesTranscript ? .finalization : .decisions, sessionID: sessionID,
                severity: .error, recoveryAction: request.finalizesTranscript ? .reprocess : .retryDecisions
            ))
        case .paused?, nil:
            break
        }
        completions.finished(request, result: result)
    }

    private func processingStatusDidChange(_ text: String, sessionID: UUID) {
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
    /// Nothing uses the models: no recording, live transcription, queued, held or running processing.
    var isIdleForRelease: Bool {
        recording.phase == .idle && isProcessingIdle
    }

    /// Unloads the ASR and diarization models once the engine is idle; they load again on next use.
    func releaseIdleResourcesIfIdle() {
        guard isIdleForRelease, idleReleaseTask == nil, !isShuttingDown else { return }
        idleReleaseTask = Task { [self] in
            if isIdleForRelease { await gateway.releaseIdleResources() }
            idleReleaseTask = nil
        }
    }
}

// MARK: Startup recovery

extension EngineApplicationCore {
    var recoveryStatusSnapshot: SessionRecoveryStatusSnapshot {
        SessionRecoveryStatusSnapshot(processing: nil, transcript: "")
    }

    func recoveryDidChange(_ event: SessionRecoveryEvent) {
        switch event {
        case .maintenanceStarted, .maintenanceFinished, .recovering, .retryEmpty:
            break
        case let .reportedFailures(scanFailures, maintenanceFailures, _):
            for failure in scanFailures {
                report(EngineFailures.failure(
                    code: .filesystem, message: "復旧できないセッションがあります: \(failure.message)", stage: .recovery,
                    sessionID: nil, severity: .error, recoveryAction: .inspectSession,
                    details: [EngineFailures.detail(
                        domain: "recovery", code: "scan", message: failure.message, path: failure.sessionURL.path
                    )]
                ))
            }
            for (sessionID, message) in maintenanceFailures.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                report(EngineFailures.failure(
                    code: .filesystem, message: "保存済み録音の音声を整理できませんでした: \(message)", stage: .maintenance,
                    sessionID: sessionID, severity: .error, recoveryAction: .inspectSession
                ))
            }
        case let .failed(reason):
            scanFailed = true
            report(EngineFailures.failure(
                code: .filesystem, message: "未完了セッションを復旧できませんでした: \(reason)", stage: .recovery,
                sessionID: nil, severity: .error, recoveryAction: .restart
            ))
        case let .retryFailed(reason):
            report(EngineFailures.failure(
                code: .filesystem, message: "保留中の判定を確認できませんでした: \(reason)", stage: .decisions,
                sessionID: nil, severity: .error, recoveryAction: .retry
            ))
        }
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
    }
}
