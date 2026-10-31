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

    func reprocess(sessionID: UUID) {
        guard recordingPhase == .idle,
              !processingQueue.containsForReprocessing(sessionID),
              let session = readableSavedSession(sessionID),
              session.audioSource != nil else {
            return
        }
        selectSavedSession(sessionID: sessionID)
        guard processingQueue.claimReprocessing(sessionID) else { return }
        enqueueProcessing(.finalize(sessionID: sessionID, metadataPolicy: .replace))
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
            if let held = processingQueue.modelHeld.first {
                showWaitingForModels(sessionID: held.sessionID)
            }
        case .downloading, .loading:
            if !processingQueue.modelHeld.isEmpty, processingStatusText != status.waitingText,
               let held = processingQueue.modelHeld.first {
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
            && processingQueue.pending.isEmpty
            && processingQueue.thermallyHeld.isEmpty
            && processingQueue.modelHeld.isEmpty
            && !processingCoordinator.isDraining
            && processingQueue.currentSessionID == nil
            && processingQueue.claimedSessionIDs.isEmpty
            && liveCoordinator.isASRIdle
            && !modelPreparer.isRunning
    }

    /// Releases the ASR and diarization models and the MLX cache once the app is idle. Model loads, live recognition,
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
            let retained = try RetainedSessionImporter(paths: .trustedApplication(paths))
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

    func resumeThermallyHeldProcessing() {
        processingCoordinator.resumeThermallyHeldProcessing()
    }

    func awaitIdleRelease() async {
        await idleReleaseTask?.value
    }

    func liveASRFailure(sessionID: UUID) -> String? {
        liveTranscription.failure(sessionID: sessionID)
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

    func processingUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self, self.displayedSessionID == sessionID else { return }
                do {
                    try self.transcriptViewModel.update(segments: segments)
                    self.processingState = state
                    if state == .complete {
                        self.transcriptViewModel.setDisplayState(.finalized)
                    }
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
        case .held(let request):
            processingState = .backlogged
            processingStatusText = UserFacingStatus.finalizationPausedForHeat.text
            if displayedSessionID == request.sessionID {
                transcriptViewModel.setStatus(UserFacingStatus.finalizationPausedForHeat.text)
            }
        case .heldForModels(let request):
            showWaitingForModels(sessionID: request.sessionID)
        case .began(let request):
            processingState = .running
            if displayedSessionID == request.sessionID, request.finalizesTranscript {
                transcriptViewModel.setDisplayState(.finalizing)
            }
        case .liveFailed(let failure):
            processingStatusText =
                "ライブ文字起こしは停止しました。録音全体を確定処理します: \(failure)"
        case .finished(let request, let result):
            if let result {
                reportFailedFinalization(result)
            }
            if let retained = result?.retainedTranscript,
               displayedSessionID == request.sessionID {
                switch retained {
                case .finalized: transcriptViewModel.setDisplayState(.finalized)
                case .provisional: transcriptViewModel.setDisplayState(.live)
                case .nothing: transcriptViewModel.setDisplayState(.empty)
                }
            }
        case .next:
            processingState = .backlogged
            processingStatusText = "次の文字起こし処理を開始します"
            transcriptViewModel.setStatus("次の文字起こし処理を開始します")
        case .willFinishDrain:
            if processingQueue.thermallyHeld.isEmpty,
               processingQueue.modelHeld.isEmpty,
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
