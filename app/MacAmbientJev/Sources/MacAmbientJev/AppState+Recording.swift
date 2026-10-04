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
            recordingPhase = .requestingPermission
            setCaptureStatus(UserFacingStatus.checkingMicrophone.text, tone: .neutral)
            guard await microphoneAccess() else {
                recordingPhase = .idle
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
            recordingPhase = .idle
            setCaptureStatus("録音先を作成できませんでした: \(error.localizedDescription)", tone: .error)
            return
        }

        recordingPhase = .starting
        if statusTone != .warning {
            setCaptureStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        }

        let sessionID = UUID()
        let sessionURL = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        recordingSessionID = sessionID
        do {
            try prepareSession(
                sessionID: sessionID,
                sessionURL: sessionURL,
                source: .recording(captureSource)
            )
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
                    if self.recordingPhase == .starting,
                       self.recordingSessionID == sessionID {
                        self.pendingCaptureFailure = (sessionID, message)
                    } else {
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
            if let failure = pendingCaptureFailure, failure.sessionID == sessionID {
                pendingCaptureFailure = nil
                captureDidFail(sessionID: sessionID, message: failure.message)
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
                liveVADFailureText = error.localizedDescription
                processingStatusText =
                    "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)"
                reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
            }
        } catch {
            pendingCaptureFailure = nil
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false
            let processing = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
            let keepSession: Bool
            do {
                let checkpoint = try AudioCheckpoint.loadRecovered(from: processing)
                keepSession = checkpoint?.hasCapturedAudio ?? false
            } catch {
                // Damaged durable data must remain available for recovery/diagnosis.
                keepSession = true
            }
            var removalFailure: String?
            if keepSession {
                refreshSavedSessions()
            } else {
                do {
                    try FileManager.default.removeItem(at: sessionURL)
                } catch {
                    removalFailure = "空の録音フォルダを削除できませんでした: \(error.localizedDescription)"
                    refreshSavedSessions()
                }
            }
            recordingSessionID = nil
            recordingPhase = .idle
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
        recordingSessionID = sessionID
        recordingPhase = .recording
        liveASRQueues[sessionID] = []
        liveASRFailures[sessionID] = nil
    }

    @discardableResult
    func captureDidFail(sessionID: UUID, message: String) -> Task<Void, Never>? {
        guard isCurrentRecording(sessionID) else { return nil }
        recordingPhase = .stopping
        setCaptureStatus(message, tone: .error)
        return Task {
            await finishRecording(sessionID: sessionID, failureMessage: message)
        }
    }

    func stopRecording() async {
        guard recordingPhase == .recording,
              let sessionID = recordingSessionID else {
            return
        }

        recordingPhase = .stopping
        setCaptureStatus("録音を保存しています", tone: .neutral)
        await finishRecording(sessionID: sessionID, failureMessage: nil)
    }

    func finishRecording(sessionID: UUID, failureMessage: String?) async {
        await sessionProcessor.stopLiveContentPriority(sessionID: sessionID)
        do {
            let result = try await captureEngine.stop()
            await stopLiveVADPolling()
            let checkpoint = result.checkpoint
            dropoutCount = result.dropoutCount
            if let writerFailure = result.writerFailure {
                await finishAfterWriterFailure(
                    sessionID: sessionID, checkpoint: checkpoint, message: writerFailure
                )
                return
            }

            if let liveVADSession {
                do {
                    // Final speech windows arrive after capture stopped and never reach the volume control.
                    let progress = try await liveVADSession.finish(
                        checkpoint: checkpoint
                    )
                    liveVADSegmentCount = progress.totalSegmentCount
                    await enqueueLiveASR(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint
                    )
                } catch {
                    liveVADFailureText = error.localizedDescription
                }
            }
            liveVADSession = nil

            let durationSeconds = checkpoint.sampleRate > 0
                ? Double(checkpoint.committedFrames) / checkpoint.sampleRate
                : 0

            recordingSessionID = nil
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false
            recordingPhase = .idle

            if failureMessage == nil {
                if let releaseFailure = result.systemAudioReleaseFailure {
                    setCaptureStatus("録音は保存しましたが、\(releaseFailure)", tone: .warning)
                } else if result.didOverflow {
                    setCaptureStatus(
                        "録音は保存しましたが、一部の音声が欠落した可能性があります。",
                        tone: .warning
                    )
                } else if let liveVADFailureText {
                    setCaptureStatus(
                        "録音を保存しました。発話検出を後で再実行します: \(liveVADFailureText)",
                        tone: .warning
                    )
                } else {
                    let segmentSuffix = liveVADSegmentCount > 0
                        ? "・発話 \(liveVADSegmentCount)区間"
                        : ""
                    setCaptureStatus(
                        "録音を保存しました（\(Self.formatDuration(durationSeconds))\(segmentSuffix)）",
                        tone: .neutral
                    )
                }
            }

            if liveVADFailureText == nil {
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
                        source: .recordedTimeline(checkpoint),
                        metadataPolicy: .reject
                    )
                )
            }

            liveVADFailureText = nil
            if failureMessage != nil { refreshSavedSessions() }
            liveVADSegmentCount = 0
        } catch {
            await stopLiveVADPolling()
            liveVADSession = nil
            liveVADFailureText = nil
            liveVADSegmentCount = 0
            cleanupLiveASRState(sessionID: sessionID)
            await sessionProcessor.cancelLiveTranscription(
                sessionID: sessionID
            )
            recordingSessionID = nil
            endMicInputSession()
            captureWarningText = nil
            isMicrophoneSilent = false
            recordingPhase = .idle
            if failureMessage == nil {
                setCaptureStatus(error.localizedDescription, tone: .error)
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
        liveVADSession = nil
        liveVADFailureText = nil
        liveVADSegmentCount = 0
        cleanupLiveASRState(sessionID: sessionID)
        await sessionProcessor.cancelLiveTranscription(sessionID: sessionID)
        recordingSessionID = nil
        endMicInputSession()
        captureWarningText = nil
        isMicrophoneSilent = false
        recordingPhase = .idle
        setCaptureStatus(message, tone: .error)
        enqueueProcessing(
            .finalize(
                sessionID: sessionID,
                source: .recordedTimeline(checkpoint),
                metadataPolicy: .reject
            )
        )
        refreshSavedSessions()
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

    func prepareSession(
        sessionID: UUID,
        sessionURL: URL,
        source: SessionSource
    ) throws {
        let createdURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths,
            sessionID: sessionID,
            source: source,
            createdAt: Date()
        )
        precondition(
            createdURL.standardizedFileURL == sessionURL.standardizedFileURL
        )
    }

    func isCurrentRecording(_ sessionID: UUID) -> Bool {
        recordingSessionID == sessionID && recordingPhase == .recording
    }

    func showNewSession(_ sessionID: UUID) {
        selectedSavedSessionID = nil
        displayedSessionID = sessionID
        transcriptViewModel.update(segments: [])
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
