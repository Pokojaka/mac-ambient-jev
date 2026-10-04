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
        enqueueProcessing(.finalize(sessionID: sessionID, source: source, metadataPolicy: .replace))
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
            && pendingProcessing.isEmpty
            && thermallyHeldProcessing.isEmpty
            && processingTask == nil
            && currentlyProcessingSessionID == nil
            && finalizationGate.sessionIDs.isEmpty
            && liveASRTasks.isEmpty
            && liveASRQueues.values.allSatisfy(\.isEmpty)
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

    func retryDeferredJev() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions().candidates

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
                source: .imported(originalFilename: sourceURL.lastPathComponent)
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
                .finalize(
                    sessionID: sessionID,
                    source: .importedOriginal(imported.originalURL),
                    metadataPolicy: .reject
                )
            )
        } catch {
            var message = "音声ファイルを読み込めませんでした: \(error.localizedDescription)"
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                do {
                    try FileManager.default.removeItem(at: sessionURL)
                } catch let cleanupError {
                    message += "（読み込み途中のセッションを削除できませんでした: \(cleanupError.localizedDescription)）"
                }
            }
            recordingPhase = .idle
            setCaptureStatus(message, tone: .error)
        }
    }

    nonisolated static var isThermallyCritical: Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    func enqueueProcessing(_ request: PendingProcessing) {
        if !pausesProcessing, request.finalizesTranscript {
            prepareASRModel()
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

    /// Keeps a finalization until the Mac leaves critical thermal state.
    func holdForHeat(_ request: PendingProcessing) {
        thermallyHeldProcessing.append(request)
        processingState = .backlogged
        processingStatusText = UserFacingStatus.finalizationPausedForHeat.text
        if displayedSessionID == request.sessionID {
            transcriptViewModel.setStatus(UserFacingStatus.finalizationPausedForHeat.text)
        }
    }

    func resumeThermallyHeldProcessing() {
        guard !Self.isThermallyCritical, !thermallyHeldProcessing.isEmpty, !pausesProcessing else {
            return
        }
        pendingProcessing.insert(contentsOf: thermallyHeldProcessing, at: 0)
        thermallyHeldProcessing = []
        prepareASRModel()
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    func drainProcessingQueue() async {
        await idleReleaseTask?.value
        while !pendingProcessing.isEmpty {
            let request = pendingProcessing.removeFirst()
            if request.finalizesTranscript, Self.isThermallyCritical {
                holdForHeat(request)
                continue
            }
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
            let shouldPause: NativeSessionProcessor.PauseCheck = { Self.isThermallyCritical }

            if displayedSessionID == requestSessionID, request.finalizesTranscript {
                transcriptViewModel.setDisplayState(.finalizing)
            }

            let finalization: SessionProcessingResult?
            switch request {
            case .finalize(let sessionID, let source, let metadataPolicy):
                let result: SessionProcessingResult
                switch source {
                case .recordedTimeline(let checkpoint):
                    result = await sessionProcessor.processFinalTranscript(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        pacingMode: .normal,
                        shouldPause: shouldPause,
                        onPhase: { _ in },
                        metadataPolicy: metadataPolicy,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                case .importedOriginal(let originalURL):
                    result = await sessionProcessor.processImportedSession(
                        sessionID: sessionID,
                        originalURL: originalURL,
                        pacingMode: .normal,
                        shouldPause: shouldPause,
                        onPhase: { _ in },
                        metadataPolicy: metadataPolicy,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                }
                if result.disposition == .paused {
                    holdForHeat(request)
                } else {
                    finalizationGate.release(sessionID)
                }
                refreshSavedSessions()
                finalization = result
            case .finishLive(let sessionID, let checkpoint):
                await waitForLiveASRDrain(sessionID: sessionID)

                if let failure = liveASRFailures[sessionID] {
                    await sessionProcessor.cancelLiveTranscription(
                        sessionID: sessionID
                    )
                    processingStatusText =
                        "ライブ文字起こしは停止しました。録音全体を確定処理します: \(failure)"
                }
                let result = await sessionProcessor.finishLiveTranscription(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    finalSegments: [],
                    pacingMode: .normal,
                    shouldPause: shouldPause,
                    onPhase: { _ in },
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
                cleanupLiveASRState(sessionID: sessionID)
                if result.disposition == .paused {
                    // The live session has ended; resuming finalizes the saved recording.
                    holdForHeat(.finalize(
                        sessionID: sessionID,
                        source: .recordedTimeline(checkpoint),
                        metadataPolicy: .reject
                    ))
                }
                finalization = result
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
                refreshSavedSessions()
                finalization = nil
            }

            if let retained = finalization?.retainedTranscript,
               displayedSessionID == requestSessionID {
                switch retained {
                case .finalized: transcriptViewModel.setDisplayState(.finalized)
                case .provisional: transcriptViewModel.setDisplayState(.live)
                case .nothing: transcriptViewModel.setDisplayState(.empty)
                }
            }
            if !pendingProcessing.isEmpty {
                processingState = .backlogged
                processingStatusText = "次の文字起こし処理を開始します"
                transcriptViewModel.setStatus("次の文字起こし処理を開始します")
            }
            if finalization?.disposition == .completed {
                await autoExportIfEnabled(sessionID: requestSessionID)
            }
            currentlyProcessingSessionID = nil
        }

        if thermallyHeldProcessing.isEmpty,
           processingState == .running || processingState == .backlogged {
            processingState = .complete
        }
        processingTask = nil
        releaseIdleResourcesIfIdle()
    }

    func recoverPendingSessions() async {
        do {
            let scan = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions()
            let candidates = scan.candidates
                .filter { $0.manifest.sessionID != recordingSessionID }

            if !candidates.isEmpty {
                processingStatusText = "未完了の文字起こしを復旧しています（\(candidates.count)件）"
                transcriptViewModel.setStatus(
                    "未完了の文字起こしを復旧しています"
                )
            }

            for candidate in candidates {
                switch candidate.action {
                case .retryContentPriority(let segmentIDs):
                    enqueueProcessing(
                        try contentPriorityRetry(
                            for: candidate,
                            segmentIDs: segmentIDs
                        )
                    )
                case .finalize:
                    enqueueProcessing(
                        .finalize(
                            sessionID: candidate.manifest.sessionID,
                            source: candidate.source,
                            metadataPolicy: .reject
                        )
                    )
                }
            }

            if let firstFailure = scan.failures.first {
                processingStatusText =
                    "復旧できないセッションがあります（\(scan.failures.count)件）: \(firstFailure.message)"
                transcriptViewModel.setStatus(
                    "復旧できないセッションがあります（\(scan.failures.count)件）"
                )
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

    /// Jev retries reuse the timeline the published runs were computed against.
    func contentPriorityRetry(
        for candidate: RecoverableSession,
        segmentIDs: [String]
    ) throws -> PendingProcessing {
        let layout = SessionLayout(sessionURL: candidate.sessionURL)
        guard let checkpoint = try AudioCheckpoint.loadRecovered(
            from: layout.processingDirectory
        ) else {
            throw SessionRecoveryScannerError.missingAudio
        }
        return .retryContentPriority(
            sessionID: candidate.manifest.sessionID,
            checkpoint: checkpoint,
            segmentIDs: segmentIDs
        )
    }
}
