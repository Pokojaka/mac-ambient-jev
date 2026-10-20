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

extension AppState {
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

        let sessionID = UUID()
        recording.start(sessionID: sessionID)
        if statusTone != .warning {
            setCaptureStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        }

        var createdSessionURL: URL?

        do {
            let sessionURL = try prepareSession(sessionID: sessionID, source: .recording(captureSource))
            createdSessionURL = sessionURL
            if captureSource == .microphone {
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
                onFailure: { [weak self] message in
                    guard let self else { return }
                    if !self.recording.deferFailureWhileStarting(sessionID: sessionID, message: message) {
                        self.captureDidFail(sessionID: sessionID, message: message)
                    }
                },
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
            markRecordingStarted(sessionID: sessionID)
            if let failure = recording.takePendingFailure(sessionID: sessionID) {
                captureDidFail(sessionID: sessionID, message: failure)
                return
            }
            showNewSession(sessionID)
            setCaptureStatus(captureSource == .systemAudio ? "システム音声を録音中" : "マイクを録音中", tone: .recording)
            if !pausesProcessing {
                prepareASRModel()
            }
            do {
                try await startLiveVAD(sessionID: sessionID)
            } catch {
                guard isCurrentRecording(sessionID) else { return }
                liveTranscription.vadFailureText = error.localizedDescription
                processingStatusText =
                    "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)"
                reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
            }
        } catch {
            _ = recording.takePendingFailure(sessionID: sessionID)
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false
            var removalFailure: String?
            if let sessionURL = createdSessionURL {
                let processing = SessionLayout(sessionURL: sessionURL).processingDirectory
                let keepSession: Bool
                do {
                    let checkpoint = try AudioCheckpoint.loadRecovered(from: processing, relativeTo: sessionURL)
                    keepSession = try checkpoint?.info.hasCapturedAudio ?? false
                } catch {
                    // Damaged durable data must remain available for recovery/diagnosis.
                    keepSession = true
                }
                if keepSession {
                    refreshSavedSessions()
                } else {
                    do {
                        try SessionFileAccess.removeIfPresent(sessionURL, relativeTo: paths.sessionsRoot)
                    } catch {
                        removalFailure = "空の録音フォルダを削除できませんでした: \(error.localizedDescription)"
                        refreshSavedSessions()
                    }
                }
            }
            recording.finish()
            if case AudioCaptureEngineError.cancelled = error, removalFailure == nil {
                setCaptureStatus("録音の開始を中止しました", tone: .neutral)
            } else {
                setCaptureStatus(
                    [error.localizedDescription, removalFailure].compactMap { $0 }.joined(separator: "。"),
                    tone: .error
                )
            }
            releaseIdleResourcesIfIdle()
        }
    }

    func markRecordingStarted(sessionID: UUID) {
        recording.didStart(sessionID: sessionID)
        liveTranscription.begin(sessionID: sessionID)
    }

    @discardableResult
    func captureDidFail(sessionID: UUID, message: String) -> Task<Void, Never>? {
        guard recording.beginStopping(sessionID: sessionID) else { return nil }
        setCaptureStatus(message, tone: .error)
        return Task {
            await finishRecording(sessionID: sessionID, failureMessage: message)
        }
    }

    func stopRecording() async {
        guard let sessionID = recordingSessionID,
              recording.beginStopping(sessionID: sessionID) else {
            return
        }

        setCaptureStatus("録音を保存しています", tone: .neutral)
        await finishRecording(sessionID: sessionID, failureMessage: nil)
    }

    func finishRecording(sessionID: UUID, failureMessage: String?) async {
        do {
            let result = try await captureEngine.stop()
            await stopLiveVADPolling()
            let checkpoint = result.checkpoint
            dropoutCount = result.dropoutCount
            if let writerFailure = result.writerFailure {
                let message = Self.combinedFailureMessage(
                    writerFailure, result.systemAudioReleaseFailure
                ) ?? writerFailure
                await finishAfterWriterFailure(
                    sessionID: sessionID, checkpoint: checkpoint, message: message
                )
                return
            }

            let stopFailureMessage = Self.combinedFailureMessage(
                failureMessage, result.systemAudioReleaseFailure
            )

            await liveCoordinator.finishVAD(sessionID: sessionID, checkpoint: checkpoint)

            let durationSeconds = checkpoint.sampleRate > 0
                ? Double(checkpoint.committedFrames) / checkpoint.sampleRate
                : 0

            recording.finish()
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false

            if let stopFailureMessage {
                setCaptureStatus(stopFailureMessage, tone: .error)
            } else if let resultReleaseFailure = result.systemAudioReleaseFailure {
                setCaptureStatus("録音は保存しましたが、\(resultReleaseFailure)", tone: .warning)
            } else if result.didOverflow {
                setCaptureStatus(
                    "録音は保存しましたが、一部の音声が欠落した可能性があります。",
                    tone: .warning
                )
            } else if let liveVADFailureText = liveTranscription.vadFailureText {
                setCaptureStatus(
                    "録音を保存しました。発話検出を後で再実行します: \(liveVADFailureText)",
                    tone: .warning
                )
            } else {
                let segmentSuffix = liveTranscription.vadSegmentCount > 0
                    ? "・発話 \(liveTranscription.vadSegmentCount)区間"
                    : ""
                setCaptureStatus(
                    "録音を保存しました（\(Self.formatDuration(durationSeconds))\(segmentSuffix)）",
                    tone: .neutral
                )
            }

            if liveTranscription.vadFailureText == nil {
                enqueueProcessing(
                    .finishLive(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                )
            } else {
                cleanupLiveASRState(sessionID: sessionID)
                await sessionProcessor.cancelLiveTranscription(
                    sessionID: sessionID
                )
                enqueueProcessing(
                    .finalize(
                        sessionID: sessionID,
                        metadataPolicy: .reject
                    )
                )
            }

            if failureMessage != nil { refreshSavedSessions() }
            liveCoordinator.resetVAD()
        } catch {
            await stopLiveVADPolling()
            liveCoordinator.resetVAD()
            cleanupLiveASRState(sessionID: sessionID)
            await sessionProcessor.cancelLiveTranscription(
                sessionID: sessionID
            )
            recording.finish()
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false
            if let stopFailureMessage = Self.combinedFailureMessage(
                failureMessage, error.localizedDescription
            ) {
                setCaptureStatus(stopFailureMessage, tone: .error)
            }
            if failureMessage != nil { refreshSavedSessions() }
            releaseIdleResourcesIfIdle()
        }
    }

    /// The storage failure stays on screen; the healthy durable prefix is finalized from the
    /// timeline because live results past that prefix were never saved.
    private func finishAfterWriterFailure(
        sessionID: UUID, checkpoint: AudioCheckpoint, message: String
    ) async {
        liveCoordinator.resetVAD()
        cleanupLiveASRState(sessionID: sessionID)
        await sessionProcessor.cancelLiveTranscription(sessionID: sessionID)
        recording.finish()
        endMicInputSession()
        captureWarningText = nil
        isMicrophoneSilent = false
        setCaptureStatus(message, tone: .error)
        enqueueProcessing(
            .finalize(
                sessionID: sessionID,
                metadataPolicy: .reject
            )
        )
        refreshSavedSessions()
    }

    private static func combinedFailureMessage(
        _ primary: String?, _ additional: String?
    ) -> String? {
        let messages = [primary, additional].compactMap { $0 }.filter { !$0.isEmpty }
        guard !messages.isEmpty else { return nil }
        return messages.reduce(into: [String]()) { unique, message in
            if !unique.contains(message) { unique.append(message) }
        }.joined(separator: "。")
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

    static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }

        return String(
            format: "%02d:%02d",
            minutes,
            remainingSeconds
        )
    }
}
