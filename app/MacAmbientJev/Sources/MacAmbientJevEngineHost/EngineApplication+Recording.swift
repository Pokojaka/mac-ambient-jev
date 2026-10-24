import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

// MARK: EngineRecordingHandling

extension EngineApplicationCore: EngineRecordingHandling {
    func devices(_ payload: EngineDevicesListPayload, context: EngineRequestContext) async throws -> EngineDevicesResult {
        do {
            return try capture.devices(source: payload.source)
        } catch {
            throw EngineFailures.commandError(from: error, fallback: .deviceFailure, stage: .devices, recoveryAction: .selectDevice)
        }
    }

    func start(_ payload: EngineRecordingStartPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        _ = try requireSettings(stage: .capture)
        _ = try requireModelsPrepared(stage: .capture)
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のため録音を開始できません", stage: .capture)
        }
        guard recording.phase == .idle else {
            throw EngineFailures.commandError(.busy, "録音または取り込みを実行中です", stage: .capture, recoveryAction: .retry)
        }
        guard !processingQueue.isMaintainingStorage else {
            throw EngineFailures.commandError(
                .busy, "起動時の保存データの整理と復旧が終わるまで録音を開始できません", stage: .capture, recoveryAction: .retry
            )
        }
        guard isProcessingIdle else {
            throw EngineFailures.commandError(
                .busy, "文字起こしの確定処理が実行中のため録音を開始できません", stage: .capture, recoveryAction: .retry
            )
        }

        // Claim the recording before the first suspension so a second start sees a busy engine.
        presentation.isSilent = false
        presentation.audioGapCount = 0
        presentation.liveFailureNotices.removeAll()
        presentation.processingState = .idle
        presentation.processingStatusText = nil
        recording.requestPermission()
        finishOutcomes.removeAll()
        let sessionID = UUID()
        startAttempt = StartAttempt(source: payload.source, device: payload.device, sessionURL: nil, error: nil)
        activeRecording = (payload.source, payload.device)
        let sessionsRoot = paths.sessionsRoot
        let task = Task { @MainActor [self] in
            await RecordingStartCoordinator(sessionsRoot: sessionsRoot).start(sessionID: sessionID, effects: self)
        }
        startTask = task
        await task.value
        startTask = nil
        let attempt = startAttempt
        startAttempt = nil
        if let error = attempt?.error { throw error }
        return try EngineSessionPayload(sessionID: EngineFailures.wireID(sessionID))
    }

    func stop(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        let sessionID = try EngineFailures.sessionID(payload.sessionID, stage: .capture)
        guard recording.sessionID == sessionID else {
            throw EngineFailures.commandError(
                .sessionNotFound, "録音中のセッションではありません", stage: .capture, sessionID: sessionID
            )
        }
        switch recording.phase {
        case .recording:
            guard recording.beginStopping(sessionID: sessionID) else {
                preconditionFailure("a recording lifecycle in .recording begins stopping")
            }
            setRecordingStatus("録音を保存しています", tone: .neutral)
            stateDidChange()
            await runStop(sessionID: sessionID, failureMessage: nil)
        case .stopping:
            // A capture failure already began the stop; wait for it to finish.
            await stopTask?.value
        case .idle, .requestingPermission, .starting, .importing:
            throw EngineFailures.commandError(
                .busy, "録音を開始している途中です", stage: .capture, sessionID: sessionID, recoveryAction: .retry
            )
        }
        if case let .failed(message)? = finishOutcomes.removeValue(forKey: sessionID) {
            throw EngineFailures.commandError(
                .captureFailure, message ?? "録音を保存できませんでした", stage: .capture,
                sessionID: sessionID, recoveryAction: .reprocess
            )
        }
        return payload
    }

    /// Stops the recording through the shared finish sequence and records it as the task shutdown can wait for.
    func runStop(sessionID: UUID, failureMessage: String?) async {
        let task = Task { @MainActor [self] in
            await liveCoordinator.finishRecording(
                sessionID: sessionID, failureMessage: failureMessage, processing: processingCoordinator, effects: self
            )
        }
        stopTask = task
        await task.value
        stopTask = nil
    }

    func captureDidFail(sessionID: UUID, message: String) {
        guard recording.beginStopping(sessionID: sessionID) else { return }
        setRecordingStatus(message, tone: .error)
        isShuttingDown = true
        processingCoordinator.requestPause()
        report(EngineFailures.failure(
            code: .captureFailure, message: message, stage: .capture, sessionID: sessionID,
            severity: .fatal, recoveryAction: .reprocess
        ))
        stopTask = Task { @MainActor [self] in
            await liveCoordinator.finishRecording(
                sessionID: sessionID, failureMessage: message, processing: processingCoordinator, effects: self
            )
            stopTask = nil
            events.captureFailed(message)
        }
    }

    var captureSourceForStart: CaptureSource? {
        guard let attempt = startAttempt else { return nil }
        return attempt.source == .microphone ? .microphone : .systemAudio
    }
}

// MARK: RecordingStartEffects

extension EngineApplicationCore: RecordingStartEffects {
    func recordingStartDidBegin(sessionID: UUID) {
        setRecordingStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        stateDidChange()
    }

    func bootstrapSession(sessionID: UUID) throws -> URL {
        guard let source = captureSourceForStart else { preconditionFailure("a recording start has no attempt") }
        let url = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(source), createdAt: Date(), timeZone: .current
        )
        startAttempt?.sessionURL = url
        return url
    }

    func startCapture(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard let attempt = startAttempt, let sessionURL = attempt.sessionURL else {
            preconditionFailure("capture starts after the session is bootstrapped")
        }
        let callbacks = EngineCaptureCallbacks(
            onFailure: onFailure,
            onWarning: { [weak self] message in
                guard let self, self.recording.sessionID == sessionID else { return }
                self.report(EngineFailures.failure(
                    code: .captureFailure, message: message, stage: .capture, sessionID: sessionID,
                    severity: .warning, recoveryAction: .none
                ))
            },
            onDropouts: { [weak self] count in
                guard let self, self.recording.sessionID == sessionID else { return }
                self.presentation.audioGapCount = count
                self.stateDidChange()
            },
            onSilenceChanged: { [weak self] silent in
                guard let self, self.recording.sessionID == sessionID else { return }
                self.presentation.isSilent = silent
                self.stateDidChange()
            }
        )
        do {
            captureSession = try await capture.startCapture(
                sessionID: sessionID, sessionURL: sessionURL, source: attempt.source, device: attempt.device,
                callbacks: callbacks
            )
        } catch {
            startAttempt?.error = Self.startError(error, sessionID: sessionID)
            throw error
        }
    }

    func markRecordingStarted(sessionID: UUID) {
        recording.didStart(sessionID: sessionID)
        liveTranscription.begin(sessionID: sessionID)
        stateDidChange()
    }

    func captureDidFailDuringStart(sessionID: UUID, message: String) {
        captureDidFail(sessionID: sessionID, message: message)
    }

    func recordingDidStart(sessionID: UUID) {
        guard let activeRecording else {
            preconditionFailure("a started recording has an active source")
        }
        setRecordingStatus(
            activeRecording.source == .microphone ? "マイクを録音中" : "システム音声を録音中",
            tone: .recording
        )
        stateDidChange()
    }

    func startLiveSession(sessionID: UUID) async throws {
        guard let inference, let captureSession else { return }
        let checkpoint = try await captureSession.committedCheckpoint()
        guard recording.isCurrentRecording(sessionID) else { return }
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let directory = SessionLayout(sessionURL: sessionURL).processingDirectory
        let vadSession = try inference.makeLiveVADSession(
            directory, sessionURL, checkpoint, "seg_live_\(UUID().uuidString.lowercased())"
        )
        guard recording.isCurrentRecording(sessionID) else { return }
        await liveCoordinator.startVAD(sessionID: sessionID, session: vadSession, checkpoint: checkpoint)
    }

    func liveSessionStartDidFail(sessionID: UUID, error: any Error) {
        liveTranscription.vadFailureText = error.localizedDescription
        addLiveFailureNotice("録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)")
        report(EngineFailures.failure(
            code: .processingFailure,
            message: "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)",
            stage: .vad, sessionID: sessionID, severity: .warning, recoveryAction: .reprocess,
            details: [EngineFailures.detail(for: error)]
        ))
    }

    func recordingStartWillCleanUp() {
        captureSession = nil
        presentation.isSilent = false
    }

    func recordingStartDidFail(_ failure: RecordingStartFailure) {
        activeRecording = nil
        if let original = startAttempt?.error {
            switch failure {
            case .cancelled:
                break
            case let .failed(text):
                if text != original.message {
                    var cleanupErrors = original.cleanupErrors
                    cleanupErrors.append(EngineFailures.detail(
                        domain: "recording_start", code: "cleanup", message: text
                    ))
                    startAttempt?.error = Self.replacing(original, message: text, cleanupErrors: cleanupErrors)
                }
            }
        } else {
            let message: String
            let code: EngineErrorCode
            switch failure {
            case .cancelled:
                message = "録音の開始を中止しました"
                code = .cancelled
            case let .failed(text):
                message = text
                code = .captureFailure
            }
            startAttempt?.error = EngineFailures.commandError(code, message, stage: .capture, recoveryAction: .retry)
        }
        guard let error = startAttempt?.error else {
            preconditionFailure("a failed recording start has an error")
        }
        let tone: EngineRecordingTone
        switch failure {
        case .cancelled:
            tone = .neutral
        case .failed:
            tone = .error
        }
        setRecordingStatus(error.message, tone: tone)
        stateDidChange()
    }

    private static func replacing(
        _ original: EngineCommandError,
        message: String,
        cleanupErrors: [EngineErrorDetail]
    ) -> EngineCommandError {
        do {
            return try EngineCommandError(
                code: original.code, message: EngineFailures.nonempty(message), stage: original.stage,
                sessionID: original.sessionID, severity: original.severity, recoveryAction: original.recoveryAction,
                details: original.details, cleanupErrors: cleanupErrors
            )
        } catch {
            preconditionFailure("replacing a start failure preserves valid error fields: \(error)")
        }
    }

    func refreshSavedSessions() {
        savedSessionsAreStale = true
    }

    private static func startError(_ error: any Error, sessionID: UUID) -> EngineCommandError {
        if let capture = error as? AudioCaptureEngineError {
            let code: EngineErrorCode
            let recoveryAction: EngineRecoveryAction
            switch capture {
            case .insufficientDiskSpace, .diskSpaceUnavailable:
                code = .diskSpace
                recoveryAction = .freeDiskSpace
            case .cancelled:
                code = .cancelled
                recoveryAction = .none
            case .alreadyRecording, .notRecording, .invalidInputFormat, .inputUnavailable, .noSystemAudioCaptured,
                 .noAudioCaptured, .writerFailure, .captureFailure, .micInputVolumeNotConfigured:
                code = .captureFailure
                recoveryAction = .selectDevice
            }
            return EngineFailures.commandError(
                code, capture.localizedDescription, stage: .capture, sessionID: sessionID,
                recoveryAction: recoveryAction, details: [EngineFailures.detail(for: error)]
            )
        }
        return EngineFailures.commandError(
            from: error, fallback: .captureFailure, stage: .capture, recoveryAction: .selectDevice
        )
    }
}

// MARK: RecordingFinishEffects

extension EngineApplicationCore: RecordingFinishEffects {
    func stopCapture() async throws -> AudioCaptureStopResult {
        guard let captureSession else { throw AudioCaptureEngineError.notRecording }
        defer { self.captureSession = nil }
        return try await captureSession.stop()
    }

    func captureStopped(dropoutCount: UInt64) {
        presentation.audioGapCount = dropoutCount
        stateDidChange()
    }

    func recordingDidFinish(_ outcome: RecordingFinishOutcome) {
        let sessionID = recording.sessionID
        recording.finish()
        activeRecording = nil
        presentation.isSilent = false
        if let sessionID { finishOutcomes[sessionID] = outcome }
        switch outcome {
        case let .failed(message):
            let failureMessage = message ?? "録音の保存に失敗しました"
            setRecordingStatus(failureMessage, tone: .error)
            let shouldSignalController = !isShuttingDown
            isShuttingDown = true
            processingCoordinator.requestPause()
            report(EngineFailures.failure(
                code: .captureFailure, message: failureMessage, stage: .capture, sessionID: sessionID,
                severity: .fatal, recoveryAction: .reprocess
            ))
            if shouldSignalController {
                // Yielding a capture-failed event never waits on the stop task that is finishing this callback.
                events.captureFailed(failureMessage)
            }
        case let .saved(result, failureMessage, vadFailureText, vadSegmentCount):
            if let failureMessage {
                setRecordingStatus(failureMessage, tone: .error)
            } else if let release = result.systemAudioReleaseFailure {
                setRecordingStatus("録音は保存しましたが、\(release)", tone: .warning)
            } else if result.didOverflow {
                setRecordingStatus(
                    "録音は保存しましたが、一部の音声が欠落した可能性があります。", tone: .warning
                )
            } else if let vadFailureText {
                setRecordingStatus(
                    "録音を保存しました。発話検出を後で再実行します: \(vadFailureText)", tone: .warning
                )
            } else {
                let checkpoint = result.checkpoint
                precondition(checkpoint.sampleRate.isFinite && checkpoint.sampleRate > 0)
                let durationSeconds = Double(checkpoint.committedFrames) / checkpoint.sampleRate
                let segmentSuffix = vadSegmentCount > 0 ? "・発話 \(vadSegmentCount)区間" : ""
                setRecordingStatus(
                    "録音を保存しました（\(Self.formatRecordingDuration(durationSeconds))\(segmentSuffix)）",
                    tone: .neutral
                )
            }
            if let release = result.systemAudioReleaseFailure {
                report(EngineFailures.failure(
                    code: .captureFailure, message: "録音は保存しましたが、\(release)", stage: .capture, sessionID: sessionID,
                    severity: .warning, recoveryAction: .none
                ))
            }
            if result.didOverflow {
                report(EngineFailures.failure(
                    code: .captureFailure, message: "録音は保存しましたが、一部の音声が欠落した可能性があります", stage: .capture,
                    sessionID: sessionID, severity: .warning, recoveryAction: .none
                ))
            }
            if let vadFailureText {
                report(EngineFailures.failure(
                    code: .processingFailure, message: "録音を保存しました。発話検出を後で再実行します: \(vadFailureText)",
                    stage: .vad, sessionID: sessionID, severity: .warning, recoveryAction: .reprocess
                ))
            }
        }
        stateDidChange()
    }
}

// MARK: LiveTranscriptionEffects

extension EngineApplicationCore: LiveTranscriptionEffects {
    var recordingSessionID: UUID? { recording.sessionID }

    func isCurrentRecording(_ sessionID: UUID) -> Bool {
        recording.isCurrentRecording(sessionID)
    }

    func committedLiveCheckpoint() async throws -> AudioCheckpoint {
        guard let captureSession else { throw AudioCaptureEngineError.notRecording }
        return try await captureSession.committedCheckpoint()
    }

    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { [weak self] status in
            let text = Self.processorPresentationText(status)
            await MainActor.run {
                guard let self,
                      self.recording.sessionID == sessionID,
                      self.recording.phase == .recording else { return }
                let isDecisionDeferred = text.hasPrefix(UserFacingStatus.decisionDeferred.text)
                let isSaveFailure = text.hasPrefix("発話文の判定を保存できませんでした")
                let isLiveDecisionFailure = text.hasPrefix("ライブの発話文判定に失敗しました")
                if isDecisionDeferred || isSaveFailure || isLiveDecisionFailure {
                    self.liveTranscription.contentPriorityStatus[sessionID] = text
                    self.addLiveFailureNotice(text)
                }
                self.presentation.processingStatusText =
                    self.liveTranscription.contentPriorityStatus[sessionID] ?? text
                self.stateDidChange()
            }
        }
    }

    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self,
                      self.recordingSessionID == sessionID
                        || (self.processingQueue.currentSessionID == sessionID
                            && self.liveCoordinator.isDraining(sessionID: sessionID)) else { return }
                self.transcriptDidUpdate(sessionID: sessionID, segments: segments)
                self.presentation.processingState = state
                self.stateDidChange()
            }
        }
    }

    func liveDidChange(_ event: LiveTranscriptionEvent) {
        switch event {
        case .started, .vadProgress, .thermal:
            break
        case let .vadSegmentsEnqueued(sessionID, segmentCount):
            guard recording.sessionID == sessionID else { return }
            if presentation.processingState != .backlogged,
               liveTranscription.contentPriorityStatus[sessionID] == nil {
                presentation.processingStatusText =
                    "録音中に発話を検出しています（\(segmentCount)区間）"
                stateDidChange()
            }
        case let .startFailed(sessionID, message):
            let text = "録音は継続しています。ライブ文字起こしを開始できませんでした: \(message)"
            reportLiveWarning(sessionID, text, stage: .asr)
            if recording.sessionID == sessionID { addLiveFailureNotice(text) }
        case let .registrationFailed(sessionID, message):
            let text = "録音は継続しています。発話区間を保存できませんでした: \(message)"
            reportLiveWarning(sessionID, text, stage: .vad)
            if recording.sessionID == sessionID { addLiveFailureNotice(text) }
        case let .recognitionFailed(sessionID, message):
            let text = "録音は継続しています。ライブ文字起こしを停止しました: \(message)"
            reportLiveWarning(sessionID, text, stage: .asr)
            if recording.sessionID == sessionID { addLiveFailureNotice(text) }
        case let .vadFailed(sessionID, message):
            let text = "録音は継続しています。発話検出を停止しました: \(message)"
            reportLiveWarning(sessionID, text, stage: .vad)
            if recording.sessionID == sessionID { addLiveFailureNotice(text) }
        }
    }

    private func reportLiveWarning(_ sessionID: UUID, _ message: String, stage: EngineStage) {
        report(EngineFailures.failure(
            code: .processingFailure, message: message, stage: stage, sessionID: sessionID,
            severity: .warning, recoveryAction: .reprocess
        ))
    }
}
