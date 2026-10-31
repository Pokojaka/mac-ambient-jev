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

extension AppState: RecordingFinishEffects, RecordingStartEffects {
    func toggleRecording() async {
        switch recordingPhase {
        case .starting:
            captureEngine.cancelStarting()
            setCaptureStatus("録音の開始を中止しています", tone: .neutral)
        case .recording:
            await stopRecording()
        case .idle:
            await startRecording()
        case .requestingPermission, .stopping, .importing:
            break
        }
    }

    func startRecording() async {
        guard recordingPhase == .idle else { return }
        failureStopTask = nil
        captureWarningText = nil
        micInputStatus = nil
        isMicrophoneSilent = false
        dropoutCount = 0

        let automaticMicInputVolume: Bool
        do {
            automaticMicInputVolume = try MicInputVolumePreference.read(from: userDefaults)
        } catch {
            setCaptureStatus(error.localizedDescription, tone: .error)
            return
        }

        if captureSource == .microphone {
            recording.requestPermission()
            setCaptureStatus(UserFacingStatus.checkingMicrophone.text, tone: .neutral)
            guard await microphoneAccess() else {
                recording.finish()
                setCaptureStatus(
                    "マイクへのアクセスが許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」で許可してください。",
                    tone: .error
                )
                return
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: paths.root,
                withIntermediateDirectories: true
            )
        } catch {
            recording.finish()
            setCaptureStatus("録音先を作成できませんでした: \(error.localizedDescription)", tone: .error)
            return
        }

        micInputVolumeAutomaticForStart = automaticMicInputVolume
        await RecordingStartCoordinator(sessionsRoot: paths.sessionsRoot)
            .start(sessionID: UUID(), effects: self)
    }

    func recordingStartDidBegin(sessionID: UUID) {
        if statusTone != .warning {
            setCaptureStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        }
    }

    func bootstrapSession(sessionID: UUID) throws -> URL {
        try prepareSession(sessionID: sessionID, source: .recording(captureSource))
    }

    func startCapture(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        if captureSource == .microphone {
            guard let automaticMicInputVolume = micInputVolumeAutomaticForStart else {
                preconditionFailure("マイク入力音量の自動調整設定が録音開始前に読み込まれていません")
            }
            micInputSessionID = sessionID
            captureEngine.configureMicInputVolume(
                automaticAdjustmentEnabled: automaticMicInputVolume,
                onStatus: { [weak self] id, status in
                    guard let self, self.micInputSessionID == id else { return }
                    self.micInputStatus = status
                }
            )
        }
        try await captureEngine.start(
            sessionID: sessionID,
            source: captureSource,
            onFailure: onFailure,
            onWarning: { [weak self] message in
                guard let self, self.recordingSessionID == sessionID else { return }
                if let previous = self.captureWarningText {
                    if !previous.contains(message) {
                        self.captureWarningText = previous + " / " + message
                    }
                } else {
                    self.captureWarningText = message
                }
            },
            onPermissionWaiting: { [weak self] in
                guard let self, self.recordingSessionID == sessionID else { return }
                self.setCaptureStatus("システム音声の録音許可を待っています", tone: .neutral)
            },
            onDropouts: { [weak self] count in
                guard let self, self.recordingSessionID == sessionID else { return }
                self.dropoutCount = count
            },
            onSilenceChanged: { [weak self] silent in
                guard let self, self.recordingSessionID == sessionID else { return }
                self.isMicrophoneSilent = silent
            }
        )
    }

    func markRecordingStarted(sessionID: UUID) {
        recording.didStart(sessionID: sessionID)
        liveTranscription.begin(sessionID: sessionID)
    }

    func captureDidFailDuringStart(sessionID: UUID, message: String) {
        captureDidFail(sessionID: sessionID, message: message)
    }

    func recordingDidStart(sessionID: UUID) {
        showNewSession(sessionID)
        setCaptureStatus(captureSource == .systemAudio ? "システム音声を録音中" : "マイクを録音中", tone: .recording)
        if !pausesProcessing {
            prepareModels()
        }
    }

    /// A recording that starts without the VAD model runs without live detection for its whole length.
    func startLiveSession(sessionID: UUID) async throws {
        guard modelProvisioning.isFetched(.vad) else { throw LiveModelsNotFetched() }
        try await startLiveVAD(sessionID: sessionID)
    }

    func liveSessionStartDidFail(sessionID: UUID, error: any Error) {
        if error is LiveModelsNotFetched {
            liveTranscription.vadFailureText = ModelPreparationStatus.waitingForModelsText
            processingStatusText = modelPreparation.waitingText
            reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
            return
        }
        liveTranscription.vadFailureText = error.localizedDescription
        processingStatusText =
            "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)"
        reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
    }

    func recordingStartWillCleanUp() {
        endMicInputSession()
        captureWarningText = nil
        isMicrophoneSilent = false
    }

    func recordingStartDidFail(_ failure: RecordingStartFailure) {
        switch failure {
        case .cancelled:
            setCaptureStatus("録音の開始を中止しました", tone: .neutral)
        case .failed(let message):
            setCaptureStatus(message, tone: .error)
        }
    }

    @discardableResult
    func captureDidFail(sessionID: UUID, message: String) -> Task<Void, Never>? {
        guard recording.beginStopping(sessionID: sessionID) else { return nil }
        setCaptureStatus(message, tone: .error)
        let task = Task {
            await liveCoordinator.finishRecording(
                sessionID: sessionID,
                failureMessage: message,
                processing: processingCoordinator,
                effects: self
            )
        }
        failureStopTask = task
        return task
    }

    func stopRecording() async {
        guard let sessionID = recordingSessionID,
              recording.beginStopping(sessionID: sessionID) else {
            return
        }

        setCaptureStatus("録音を保存しています", tone: .neutral)
        await liveCoordinator.finishRecording(
            sessionID: sessionID,
            failureMessage: nil,
            processing: processingCoordinator,
            effects: self
        )
    }

    func stopCapture() async throws -> AudioCaptureStopResult {
        try await captureEngine.stop()
    }

    func captureStopped(dropoutCount: UInt64) {
        self.dropoutCount = dropoutCount
    }

    func recordingDidFinish(_ outcome: RecordingFinishOutcome) {
        recording.finish()
        endMicInputSession()
        captureWarningText = nil
        isMicrophoneSilent = false

        switch outcome {
        case .failed(let message):
            if let message {
                setCaptureStatus(message, tone: .error)
            }
        case .saved(let result, let failureMessage, let vadFailureText, let vadSegmentCount):
            let checkpoint = result.checkpoint
            let durationSeconds = checkpoint.sampleRate > 0
                ? Double(checkpoint.committedFrames) / checkpoint.sampleRate
                : 0

            if let failureMessage {
                setCaptureStatus(failureMessage, tone: .error)
            } else if let resultReleaseFailure = result.systemAudioReleaseFailure {
                setCaptureStatus("録音は保存しましたが、\(resultReleaseFailure)", tone: .warning)
            } else if result.didOverflow {
                setCaptureStatus(
                    "録音は保存しましたが、一部の音声が欠落した可能性があります。",
                    tone: .warning
                )
            } else if let vadFailureText {
                setCaptureStatus(
                    "録音を保存しました。発話検出を後で再実行します: \(vadFailureText)",
                    tone: .warning
                )
            } else {
                let segmentSuffix = vadSegmentCount > 0
                    ? "・発話 \(vadSegmentCount)区間"
                    : ""
                setCaptureStatus(
                    "録音を保存しました（\(SavedSessionDisplayText.recordingDuration(durationSeconds))\(segmentSuffix)）",
                    tone: .neutral
                )
            }
        }
    }

    func reportMicSpeechMonitoringUnavailable(sessionID: UUID) {
        guard isCurrentRecording(sessionID), micInputSessionID == sessionID else { return }
        captureEngine.micSpeechMonitoringUnavailable(sessionID: sessionID)
    }

    /// Called after capture stop returns, so stop-time restore failures have already been reported.
    func endMicInputSession() {
        micInputSessionID = nil
        if let status = micInputStatus, status.adjustment.isFailure {
            micInputStatus = MicInputStatus(
                warning: nil, speechMonitoringUnavailable: false, adjustment: status.adjustment
            )
        } else {
            micInputStatus = nil
        }
    }

    /// Asks the system for microphone access when the user has not decided yet.
    static func requestSystemMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func prepareSession(sessionID: UUID, source: SessionSource) throws -> URL {
        let createdAt = Date()
        return try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths,
            sessionID: sessionID,
            source: source,
            createdAt: createdAt,
            timeZone: .current
        )
    }

    func isCurrentRecording(_ sessionID: UUID) -> Bool {
        recording.isCurrentRecording(sessionID)
    }

    func showNewSession(_ sessionID: UUID) {
        savedSessionOperations.clearSelection()
        displayedSessionID = sessionID
        do {
            try transcriptViewModel.update(segments: [])
        } catch {
            transcriptViewModel.setStatus("文字起こし表示を初期化できませんでした: \(error.localizedDescription)")
        }
    }

    func terminateCapture() {
        captureEngine.terminate()
    }

    func setCaptureStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }
}
