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

extension AppState: SessionProcessingEffects {
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

    func prepareASRModel() {
        guard modelPreparationTask == nil, modelPreparation != .ready else { return }
        modelPreparation = .preparing(0)
        // A release requested after this point waits for this load, so only an earlier release is awaited here.
        let earlierRelease = idleReleaseTask
        modelPreparationTask = Task { [weak self] in
            await earlierRelease?.value
            guard let self else { return }
            do {
                try await sessionProcessor.prepareASR { [weak self] progress, _ in
                    Task { @MainActor in
                        guard let self,
                              case .preparing(let current) = self.modelPreparation else { return }
                        self.modelPreparation = .preparing(max(current, min(1, progress)))
                    }
                }
                modelPreparation = .ready
            } catch {
                modelPreparation = .failed(error.localizedDescription)
            }
            modelPreparationTask = nil
        }
    }

    /// True when nothing uses the models: no recording, live transcription, queued, held, or running processing.
    var isIdleForRelease: Bool {
        recordingPhase == .idle
            && processingQueue.pending.isEmpty
            && processingQueue.thermallyHeld.isEmpty
            && !processingCoordinator.isDraining
            && processingQueue.currentSessionID == nil
            && processingQueue.claimedSessionIDs.isEmpty
            && liveCoordinator.isASRIdle
    }

    /// Releases the ASR and diarization models and the MLX cache once the app is idle. Model loads, live recognition,
    /// and finalization wait for a release in progress; the engines load their models again when next used.
    func releaseIdleResourcesIfIdle() {
        guard isIdleForRelease, idleReleaseTask == nil else { return }
        // A load requested after this point waits for the release, so only an earlier load is awaited here.
        let earlierPreparation = modelPreparationTask
        idleReleaseTask = Task { [weak self] in
            await earlierPreparation?.value
            guard let self else { return }
            if isIdleForRelease {
                modelPreparation = .idle
                await sessionProcessor.releaseIdleResources()
            }
            idleReleaseTask = nil
        }
    }

    func retryDeferredDecisions() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions().candidates

            var queuedCount = 0
            for candidate in candidates {
                let boundarySegments: [SegmentTextReference]
                let clauses: [ClauseReference]
                switch candidate.action {
                case .recoverDecisionRun(let segments, let references),
                     .retryContentPriority(let segments, let references):
                    boundarySegments = segments
                    clauses = references
                case .finalize:
                    continue
                }

                enqueueProcessing(
                    contentPriorityRetry(
                        for: candidate,
                        boundarySegments: boundarySegments,
                        clauses: clauses
                    )
                )
                queuedCount += 1
            }

            if queuedCount == 0 {
                processingStatusText =
                    "再試行が必要な判定はありません"
                transcriptViewModel.setStatus(
                    "再試行が必要な判定はありません"
                )
            }
        } catch {
            processingStatusText =
                "保留中の判定を確認できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "保留中の判定を確認できませんでした"
            )
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

        let sessionID = UUID()
        var createdSessionURL: URL?

        do {
            let sessionURL = try prepareSession(
                sessionID: sessionID,
                source: .imported(originalFilename: sourceURL.lastPathComponent)
            )
            createdSessionURL = sessionURL
            _ = try AudioImporter().importFile(
                sourceURL,
                into: sessionURL
            )

            recording.finish()
            showNewSession(sessionID)
            setCaptureStatus(
                "「\(sourceURL.lastPathComponent)」を読み込みました",
                tone: .neutral
            )
            enqueueProcessing(
                .finalize(
                    sessionID: sessionID,
                    metadataPolicy: .reject
                )
            )
        } catch {
            var message = "音声ファイルを読み込めませんでした: \(error.localizedDescription)"
            if let sessionURL = createdSessionURL {
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
        { [weak self] text in
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
               processingState == .running || processingState == .backlogged {
                processingState = .complete
            }
        case .drained:
            releaseIdleResourcesIfIdle()
        }
    }

    func recoverPendingSessions() async {
        processingQueue.beginStorageMaintenance()
        do {
            let scan = try SessionRecoveryScanner(sessionsRoot: paths.sessionsRoot).pendingSessions()
            let maintenance = scan.maintenance.filter { $0.sessionID != recordingSessionID }
            let maintenanceStatus = "保存済み録音の音声を整理しています（\(maintenance.count)件）"
            let previousProcessingStatus = processingStatusText
            let previousTranscriptStatus = transcriptViewModel.statusText
            let maintenanceFailures = await SessionStorageMaintainer.maintain(
                maintenance,
                willMaintain: { _ in
                    await MainActor.run {
                        self.processingStatusText = maintenanceStatus
                        self.transcriptViewModel.setStatus(maintenanceStatus)
                    }
                }
            )
            processingQueue.endStorageMaintenance()
            // Only remove our temporary status; recording or processing may have replaced it while awaiting.
            if !maintenance.isEmpty {
                if processingStatusText == maintenanceStatus {
                    processingStatusText = previousProcessingStatus
                }
                if transcriptViewModel.statusText == maintenanceStatus {
                    transcriptViewModel.setStatus(previousTranscriptStatus)
                }
            }
            let recoveries = SessionProcessingCoordinator.recoveryRequests(
                candidates: scan.candidates,
                recordingSessionID: recordingSessionID,
                maintenanceFailures: maintenanceFailures,
                pending: processingQueue.pending
            )

            if !recoveries.isEmpty {
                processingStatusText = "未完了の文字起こしを復旧しています（\(recoveries.count)件）"
                transcriptViewModel.setStatus(
                    "未完了の文字起こしを復旧しています"
                )
            }
            for recovery in recoveries {
                enqueueProcessing(recovery)
            }
            if !processingQueue.pending.isEmpty {
                processingCoordinator.startDrainIfIdle()
            }

            var sentences: [String] = []
            if !scan.failures.isEmpty {
                sentences.append(
                    "復旧できないセッションが\(scan.failures.count)件あります。詳細は「保存済み録音」で確認できます"
                )
            }
            if !maintenanceFailures.isEmpty {
                let details = maintenanceFailures.values.sorted().joined(separator: " / ")
                sentences.append(
                    "保存済み録音の音声を整理できなかったセッションが\(maintenanceFailures.count)件あります: \(details)"
                )
            }
            if !sentences.isEmpty {
                let message = sentences.joined(separator: "。")
                if recoveries.isEmpty { processingState = .partialFailure(message) }
                processingStatusText = message
            }
        } catch {
            processingQueue.endStorageMaintenance()
            processingState = .partialFailure(error.localizedDescription)
            processingStatusText =
                "未完了セッションを復旧できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "未完了セッションを復旧できませんでした"
            )
            if !processingQueue.pending.isEmpty {
                processingCoordinator.startDrainIfIdle()
            }
        }
    }

    /// A completed run that compaction or cleanup then failed is a failure the user must see.
    private func reportFailedFinalization(_ result: SessionProcessingResult) {
        guard result.disposition == .failed, let message = result.message else { return }
        processingState = .partialFailure(message)
    }

    /// Decision retries reuse the timeline the published runs were computed against.
    func contentPriorityRetry(
        for candidate: RecoverableSession,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference]
    ) -> PendingProcessing {
        .retryContentPriority(
            sessionID: candidate.manifest.sessionID,
            boundarySegments: boundarySegments,
            clauses: clauses
        )
    }
}
