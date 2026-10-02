import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevRuntime
import UniformTypeIdentifiers

extension AppState {
    func reprocess(sessionID: UUID) {
        guard recordingPhase == .idle,
              !finalizationGate.sessionIDs.contains(sessionID),
              currentlyProcessingSessionID != sessionID,
              !pendingProcessing.contains(where: { $0.sessionID == sessionID }),
              let session = savedSessions.first(where: { $0.sessionID == sessionID }),
              session.canReprocess,
              let source = session.audioSource else {
            return
        }
        selectSavedSession(sessionID: sessionID)
        guard finalizationGate.claim(sessionID) else { return }
        enqueueProcessing(.finalize(sessionID: sessionID, source: source))
    }

    func prepareASRModel() {
        guard modelPreparationTask == nil, modelPreparation != .ready else { return }
        modelPreparation = .preparing(0)
        modelPreparationTask = Task { [weak self] in
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

    func retryDeferredJev() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions()

            var queuedCount = 0
            for candidate in candidates {
                guard case .retryContentPriority(let segmentIDs)
                        = candidate.action else {
                    continue
                }

                enqueueProcessing(
                    try contentPriorityRetry(
                        for: candidate,
                        segmentIDs: segmentIDs
                    )
                )
                queuedCount += 1
            }

            if queuedCount == 0 {
                processingStatusText =
                    "再試行が必要な意味分類はありません"
                transcriptViewModel.setStatus(
                    "再試行が必要な意味分類はありません"
                )
            }
        } catch {
            processingStatusText =
                "保留中の意味分類を確認できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "保留中の意味分類を確認できませんでした"
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

        recordingPhase = .importing
        setCaptureStatus(UserFacingStatus.importingAudio.text, tone: .neutral)

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sessionID = UUID()
        let sessionURL = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        do {
            try prepareSession(
                sessionID: sessionID,
                sessionURL: sessionURL,
                sourceKind: .importedFile,
                originalFilename: sourceURL.lastPathComponent
            )
            let imported = try AudioImporter().importFile(
                sourceURL,
                into: sessionURL
            )

            recordingPhase = .idle
            showNewSession(sessionID)
            setCaptureStatus(
                "「\(sourceURL.lastPathComponent)」を読み込みました",
                tone: .neutral
            )
            enqueueProcessing(
                .imported(
                    sessionID: sessionID,
                    originalURL: imported.originalURL
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: sessionURL)
            recordingPhase = .idle
            setCaptureStatus(
                "音声ファイルを読み込めませんでした: \(error.localizedDescription)",
                tone: .error
            )
        }
    }

    func enqueueProcessing(_ request: PendingProcessing) {
        if !pausesProcessing {
            switch request {
            case .imported, .timeline, .resumeASR, .finalize:
                prepareASRModel()
            case .finishLive, .retryContentPriority, .selectCompletedASR, .diarization:
                break
            }
        }

        pendingProcessing.append(request)
        guard !pausesProcessing else { return }

        if processingTask != nil {
            processingState = .backlogged
            processingStatusText = "文字起こし処理が待機中です"
            transcriptViewModel.setStatus("文字起こし処理が待機中です")
            return
        }

        processingTask = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    func drainProcessingQueue() async {
        while !pendingProcessing.isEmpty {
            let request = pendingProcessing.removeFirst()
            let requestSessionID = request.sessionID
            currentlyProcessingSessionID = requestSessionID
            processingState = .running

            let statusHandler: NativeSessionProcessor.StatusHandler = { [weak self] text in
                await MainActor.run {
                    guard let self else { return }
                    self.processingStatusText = text
                    if self.displayedSessionID == requestSessionID {
                        self.transcriptViewModel.setStatus(text)
                    }
                }
            }

            let updateHandler: NativeSessionProcessor.UpdateHandler = { [weak self] segments, state in
                await MainActor.run {
                    guard let self, self.displayedSessionID == requestSessionID else { return }
                    self.processingState = state
                    self.transcriptViewModel.update(segments: segments)
                    if state == .complete {
                        self.transcriptViewModel.setDisplayState(.finalized)
                    }
                }
            }

            if displayedSessionID == requestSessionID, request.finalizesTranscript {
                transcriptViewModel.setDisplayState(.finalizing)
            }

            var completedSessionID: UUID? = request.sessionID
            switch request {
            case .finalize(let sessionID, let source):
                switch source {
                case .recordedTimeline(let checkpoint):
                    _ = await sessionProcessor.processFinalTranscript(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                case .importedOriginal(let originalURL):
                    _ = await sessionProcessor.processImportedSession(
                        sessionID: sessionID,
                        originalURL: originalURL,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                }
                finalizationGate.release(sessionID)
                refreshSavedSessions()
            case .imported(let sessionID, let originalURL):
                await sessionProcessor.processImportedSession(
                    sessionID: sessionID,
                    originalURL: originalURL,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .timeline(let sessionID, let checkpoint):
                await sessionProcessor.processTimelineSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .finishLive(let sessionID, let checkpoint):
                await waitForLiveASRDrain(sessionID: sessionID)

                if let failure = liveASRFailures[sessionID] {
                    await sessionProcessor.cancelLiveTranscription(
                        sessionID: sessionID
                    )
                    cleanupLiveASRState(sessionID: sessionID)
                    completedSessionID = nil
                    processingStatusText =
                        "ライブ文字起こしを再処理します: \(failure)"
                    pendingProcessing.insert(
                        .timeline(
                            sessionID: sessionID,
                            checkpoint: checkpoint
                        ),
                        at: 0
                    )
                } else {
                    let result = await sessionProcessor.finishLiveTranscription(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                    cleanupLiveASRState(sessionID: sessionID)

                    if case .fallbackRequired(let reason) = result {
                        completedSessionID = nil
                        processingStatusText =
                            "録音後に文字起こしを再実行します: \(reason)"
                        pendingProcessing.insert(
                            .timeline(
                                sessionID: sessionID,
                                checkpoint: checkpoint
                            ),
                            at: 0
                        )
                    }
                }
            case .retryContentPriority(
                let sessionID,
                let checkpoint,
                let segmentIDs
            ):
                await sessionProcessor.retryContentPrioritySession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    segmentIDs: segmentIDs,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
                completedSessionID = nil
                refreshSavedSessions()
            case .resumeASR(let sessionID, let checkpoint, let plan):
                await sessionProcessor.resumePendingASRSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .selectCompletedASR(let sessionID, let checkpoint, let plan):
                await sessionProcessor.selectCompletedASRSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .diarization(let sessionID, let checkpoint, let plan):
                await sessionProcessor.runRecoveredDiarizationSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            }

            if !pendingProcessing.isEmpty {
                processingState = .backlogged
                processingStatusText = "次の文字起こし処理を開始します"
                transcriptViewModel.setStatus("次の文字起こし処理を開始します")
            }
            if let completedSessionID {
                await autoExportIfEnabled(sessionID: completedSessionID)
            }
            currentlyProcessingSessionID = nil
        }

        if processingState == .running || processingState == .backlogged {
            processingState = .complete
        }
        processingTask = nil
    }

    func recoverPendingSessions() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions()
                .filter { $0.manifest.sessionID != recordingSessionID }

            guard !candidates.isEmpty else { return }

            processingStatusText = "未完了の文字起こしを復旧しています（\(candidates.count)件）"
            transcriptViewModel.setStatus(
                "未完了の文字起こしを復旧しています"
            )

            for candidate in candidates {
                let sessionID = candidate.manifest.sessionID

                switch (candidate.action, candidate.source) {
                case (.retryContentPriority(let segmentIDs), _):
                    enqueueProcessing(
                        try contentPriorityRetry(
                            for: candidate,
                            segmentIDs: segmentIDs
                        )
                    )

                case (.resumeASR(let plan), .recordedTimeline(let checkpoint)):
                    enqueueProcessing(
                        .resumeASR(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.selectCompletedASR(let plan), .recordedTimeline(let checkpoint)):
                    enqueueProcessing(
                        .selectCompletedASR(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.runDiarization(let plan), .recordedTimeline(let checkpoint)):
                    enqueueProcessing(
                        .diarization(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.reprocess, .recordedTimeline(let checkpoint)):
                    enqueueProcessing(
                        .timeline(
                            sessionID: sessionID,
                            checkpoint: checkpoint
                        )
                    )

                case (.finalize, .recordedTimeline(let checkpoint)):
                    enqueueProcessing(
                        .timeline(
                            sessionID: sessionID,
                            checkpoint: checkpoint
                        )
                    )

                case (_, .importedOriginal(let originalURL)):
                    // An import's timeline is derived from its original, so
                    // recovery rebuilds it and reruns the whole import.
                    enqueueProcessing(
                        .imported(
                            sessionID: sessionID,
                            originalURL: originalURL
                        )
                    )
                }
            }
        } catch {
            processingState = .partialFailure(error.localizedDescription)
            processingStatusText =
                "未完了セッションを復旧できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "未完了セッションを復旧できませんでした"
            )
        }
    }

    /// Jev retries reuse the timeline the existing events were computed against;
    /// for an import that is the timeline derived from its original.
    func contentPriorityRetry(
        for candidate: RecoverableSession,
        segmentIDs: [String]
    ) throws -> PendingProcessing {
        let checkpoint: AudioCheckpoint
        switch candidate.source {
        case .recordedTimeline(let value):
            checkpoint = value
        case .importedOriginal:
            let layout = SessionLayout(sessionURL: candidate.sessionURL)
            guard let value = try AudioCheckpoint.loadRecovered(
                from: layout.processingDirectory
            ) else {
                throw SessionRecoveryScannerError.missingAudio
            }
            checkpoint = value
        }
        return .retryContentPriority(
            sessionID: candidate.manifest.sessionID,
            checkpoint: checkpoint,
            segmentIDs: segmentIDs
        )
    }
}
