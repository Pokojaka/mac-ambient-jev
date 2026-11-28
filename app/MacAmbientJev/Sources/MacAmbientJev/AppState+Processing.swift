import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevPipeline
import MacAmbientJevRuntime
import UniformTypeIdentifiers

extension AppState: SessionProcessingEffects, SessionRecoveryEffects {
    var recoveryStatusSnapshot: SessionRecoveryStatusSnapshot {
        SessionRecoveryStatusSnapshot(
            processing: processingStatusText,
            transcript: transcriptViewModel.statusText
        )
    }

    func recoveryDidChange(_ event: SessionRecoveryEvent) {
        switch event {
        case .maintenanceStarted(let count):
            let text = SessionRecoveryEvent.maintenanceStatusText(count: count)
            processingStatusText = text
            transcriptViewModel.setStatus(text)
        case .maintenanceFinished(let count, let previous):
            let text = SessionRecoveryEvent.maintenanceStatusText(count: count)
            if processingStatusText == text {
                processingStatusText = previous.processing
            }
            if transcriptViewModel.statusText == text {
                transcriptViewModel.setStatus(previous.transcript)
            }
        case .recovering(let count):
            processingStatusText = "未完了の文字起こしを復旧しています（\(count)件）"
            transcriptViewModel.setStatus("未完了の文字起こしを復旧しています")
        case .reportedFailures(let scanFailures, let maintenanceFailures, let hasRecoveries):
            let failureReport = SessionRecoveryFailureReport(
                scanFailures: scanFailures,
                maintenanceFailures: maintenanceFailures,
                hasRecoveries: hasRecoveries
            )
            if failureReport.marksPartialFailure {
                processingState = .partialFailure(failureReport.message)
            }
            processingStatusText = failureReport.message
        case .failed(let reason):
            processingState = .partialFailure(reason)
            processingStatusText = "未完了セッションを復旧できませんでした: \(reason)"
            transcriptViewModel.setStatus("未完了セッションを復旧できませんでした")
        case .retryEmpty:
            processingStatusText = "再試行が必要な判定はありません"
            transcriptViewModel.setStatus("再試行が必要な判定はありません")
        case .retryFailed(let reason):
            processingStatusText = "保留中の判定を確認できませんでした: \(reason)"
            transcriptViewModel.setStatus("保留中の判定を確認できませんでした")
        }
    }

    func reprocess(sessionID: UUID) async {
        guard recordingPhase == .idle else {
            reportReprocessingError("録音中または録音・読み込み処理中は再処理できません")
            return
        }
        let queueSnapshot = processingQueue
        guard !queueSnapshot.isMaintainingStorage else {
            reportReprocessingError("起動時の保存データの整理中は再処理できません")
            return
        }
        if queuedFinalizationSessionIDs.contains(sessionID) {
            let message = queueSnapshot.containsProcessing(sessionID)
                ? "このセッションは処理待ち・保留中または実行中のため再処理できません"
                : "このセッションのライブ文字起こし処理中は再処理できません"
            reportReprocessingError(message)
            return
        }
        guard let session = readableSavedSession(sessionID) else {
            reportReprocessingError("保存済みセッションを読み取れないため再処理できません")
            return
        }
        guard session.audioSource != nil else {
            reportReprocessingError("保存済み音声がないため再処理できません")
            return
        }

        selectSavedSession(sessionID: sessionID)
        do {
            try processingCoordinator.enqueueReprocess(sessionID: sessionID)
        } catch {
            reportReprocessingError(error.localizedDescription)
        }
    }

    private func reportReprocessingError(_ message: String) {
        processingState = .partialFailure(message)
        processingStatusText = message
        transcriptViewModel.setStatus(message)
    }

    func prepareModels() {
        modelPreparer.ensurePrepared(after: idleReleaseTask)
    }

    /// The Settings button: starts a run, and after a failure it is the only way to start another.
    func retryModelPreparation() {
        modelPreparer.retry(after: idleReleaseTask)
    }

    var modelsReady: Bool { modelPreparer.status.phase == .ready }

    var modelPhase: ModelPreparationStatus.Phase { modelPreparer.status.phase }

    func awaitModelPreparation() async {
        await modelPreparer.runTask?.value
    }

    func modelPreparationDidChange(_ status: ModelPreparationStatus) {
        modelPreparation = status
        switch status.phase {
        case .ready:
            processingCoordinator.resumeModelHeldProcessing()
        case .failed:
            if let held = processingQueue.summaries.first(where: { $0.holdReason == .models }) {
                showWaitingForModels(sessionID: held.sessionID)
            }
        case .downloading, .loading:
            if let held = processingQueue.summaries.first(where: { $0.holdReason == .models }),
               processingStatusText != status.waitingText {
                showWaitingForModels(sessionID: held.sessionID)
            }
        case .idle:
            break
        }
    }

    func showWaitingForModels(sessionID: UUID) {
        let text = modelPreparation.waitingText
        processingState = .backlogged
        processingStatusText = text
        if displayedSessionID == sessionID {
            transcriptViewModel.setStatus(text)
        }
    }

    /// True when nothing uses the models: no recording, live transcription, queued, held, or running processing,
    /// and no model preparation. A download keeps running across recordings and thermal holds.
    var isIdleForRelease: Bool {
        recordingPhase == .idle
            && processingQueue.summaries.isEmpty
            && !processingCoordinator.isDraining
            && processingQueue.currentSessionID == nil
            && processingQueue.claimedSessionIDs.isEmpty
            && liveCoordinator.isASRIdle
            && !modelPreparer.isRunning
    }

    /// Releases ASR sessions once the app is idle. Model loads, live recognition,
    /// and finalization wait for a release in progress; the engines load their models again when next used.
    func releaseIdleResourcesIfIdle() {
        guard isIdleForRelease, idleReleaseTask == nil else { return }
        idleReleaseTask = Task { [weak self] in
            guard let self else { return }
            if isIdleForRelease {
                modelPreparer.didUnload()
                await sessionProcessor.releaseIdleResources()
            }
            idleReleaseTask = nil
        }
    }

    func importAudioFile() async {
        guard recordingPhase == .idle else { return }

        let panel = NSOpenPanel()
        panel.title = "文字起こしする音声ファイルを選択"
        panel.prompt = "読み込む"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        recording.beginImport()
        setCaptureStatus(UserFacingStatus.importingAudio.text, tone: .neutral)

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let retained = try RetainedSessionImporter(paths: .trustedApplication(paths), timeZone: .current)
                .importRetainedSession(audioURL: sourceURL)

            recording.finish()
            showNewSession(retained.sessionID)
            setCaptureStatus(
                "「\(sourceURL.lastPathComponent)」を読み込みました",
                tone: .neutral
            )
            processingCoordinator.enqueue(retained.finalize)
        } catch {
            var message = "音声ファイルを読み込めませんでした: \(error.localizedDescription)"
            if let sessionURL = (error as? RetainedImportError)?.createdSession?.sessionURL {
                do {
                    try SessionFileAccess.removeIfPresent(sessionURL, relativeTo: paths.sessionsRoot)
                } catch let cleanupError {
                    message += "（読み込み途中のセッションを削除できませんでした: \(cleanupError.localizedDescription)）"
                }
            }
            recording.finish()
            setCaptureStatus(message, tone: .error)
        }
    }

    func enqueueProcessing(_ request: PendingProcessing) {
        processingCoordinator.enqueue(request)
    }

    func awaitIdleRelease() async {
        await idleReleaseTask?.value
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveTranscription.failure(sessionID: sessionID)
    }

    func hasLiveProcessingWorker(sessionID: UUID) -> Bool {
        liveCoordinator.hasWork(sessionID: sessionID)
    }

    func processingStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { [weak self] status in
            let text = status.text
            await MainActor.run {
                guard let self else { return }
                self.processingStatusText = text
                if self.displayedSessionID == sessionID {
                    self.transcriptViewModel.setStatus(text)
                }
            }
        }
    }

    func processingGenerationDidOpen(sessionID: UUID, generationID: UUID) {
        _ = generationID
        processingSessionID = sessionID
    }

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self else { return }
                if state == .complete {
                    self.clearProcessingSession(sessionID)
                }
                guard self.displayedSessionID == sessionID else { return }
                do {
                    try self.transcriptViewModel.update(segments: segments)
                    self.processingState = state
                } catch {
                    let message = "文字起こし表示を更新できませんでした: \(error.localizedDescription)"
                    self.processingState = .partialFailure(message)
                    self.processingStatusText = message
                    self.transcriptViewModel.setStatus(message)
                }
            }
        }
    }

    func processingDidChange(_ event: SessionProcessingEvent) {
        switch event {
        case .backlogged:
            processingState = .backlogged
            processingStatusText = "文字起こし処理が待機中です"
            transcriptViewModel.setStatus("文字起こし処理が待機中です")
        case .held(let item):
            clearProcessingSession(item.sessionID)
            processingState = .backlogged
            processingStatusText = UserFacingStatus.finalizationPausedForHeat.text
            if displayedSessionID == item.sessionID {
                transcriptViewModel.setStatus(UserFacingStatus.finalizationPausedForHeat.text)
            }
        case .heldForModels(let item):
            clearProcessingSession(item.sessionID)
            showWaitingForModels(sessionID: item.sessionID)
        case .began(let item):
            processingState = .running
            if item.kind != .decisionRetry {
                processingSessionID = item.sessionID
            }
        case .liveFailed(let failure):
            processingStatusText =
                "ライブ文字起こしは停止しました: \(failure)"
        case .finished(let item, let result):
            if let result {
                reportFailedFinalization(result)
            }
            clearProcessingSession(item.sessionID)
        case .next:
            processingState = .backlogged
            processingStatusText = "次の文字起こし処理を開始します"
            transcriptViewModel.setStatus("次の文字起こし処理を開始します")
        case .willFinishDrain:
            if processingQueue.summaries.isEmpty,
               processingState == .running || processingState == .backlogged {
                processingState = .complete
            }
        case .drained:
            releaseIdleResourcesIfIdle()
        }
    }

    /// A completed run that compaction or cleanup then failed is a failure the user must see.
    private func reportFailedFinalization(_ result: SessionProcessingResult) {
        guard result.disposition == .failed, let message = result.message else { return }
        processingState = .partialFailure(message)
    }
}
