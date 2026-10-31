import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevRuntime
import MacAmbientJevPipeline
import UniformTypeIdentifiers

struct LiveModelsNotFetched: Error {}

extension AppState {
    static func fluidLiveVADFactory(models: MacModelStore) -> LiveVADFactory {
        { processingDirectory, initialCheckpoint, measureMicInputLevels, sessionURL in
            try await MacLiveVADSessionFactory.make(
                models: models,
                processingDirectory: processingDirectory,
                sessionURL: sessionURL,
                initialCheckpoint: initialCheckpoint,
                measureMicInputLevels: measureMicInputLevels,
                segmentationRunID: "seg_live_\(UUID().uuidString.lowercased())"
            )
        }
    }

    func startLiveVAD(sessionID: UUID) async throws {
        let checkpoint = try await captureEngine.committedCheckpoint()
        guard isCurrentRecording(sessionID) else { return }
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let directory = SessionLayout(sessionURL: sessionURL).processingDirectory

        let vadSession = try await makeLiveVADSession(
            directory, checkpoint, micInputSessionID == sessionID, sessionURL
        )
        guard isCurrentRecording(sessionID) else { return }

        await liveCoordinator.startVAD(
            sessionID: sessionID,
            session: vadSession,
            checkpoint: checkpoint
        )
    }

    func liveStatusHandler(sessionID: UUID) -> NativeSessionProcessor.StatusHandler {
        { [weak self] status in
            let text = status.text
            await MainActor.run {
                guard let self,
                      self.recordingSessionID == sessionID,
                      self.recordingPhase == .recording else { return }
                if text.hasPrefix(UserFacingStatus.decisionDeferred.text)
                    || text.hasPrefix("発話文の判定を保存できませんでした")
                    || text.hasPrefix("ライブの発話文判定に失敗しました") {
                    self.liveTranscription.contentPriorityStatus[sessionID] = text
                }
                let visibleStatus = self.liveTranscription.contentPriorityStatus[sessionID] ?? text
                self.processingStatusText = visibleStatus
                if self.displayedSessionID == sessionID {
                    self.transcriptViewModel.setStatus(visibleStatus)
                }
            }
        }
    }

    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self,
                      self.displayedSessionID == sessionID,
                      self.recordingSessionID == sessionID
                        || (self.processingQueue.currentSessionID == sessionID
                            && self.liveCoordinator.isDraining(sessionID: sessionID)) else { return }
                do {
                    try self.transcriptViewModel.update(segments: segments)
                    self.processingState = state
                    self.transcriptViewModel.setDisplayState(
                        self.recordingPhase == .recording ? .live : .finalizing
                    )
                } catch {
                    let message = "文字起こし表示を更新できませんでした: \(error.localizedDescription)"
                    self.processingState = .partialFailure(message)
                    self.processingStatusText = message
                    self.transcriptViewModel.setStatus(message)
                }
            }
        }
    }

    func waitForLiveASRDrain(sessionID: UUID) async {
        await liveCoordinator.waitForDrain(sessionID: sessionID)
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveCoordinator.cleanup(sessionID: sessionID)
    }

    private func showLiveThermalStatus(_ text: String, sessionID: UUID) {
        processingState = .backlogged
        processingStatusText = text
        if displayedSessionID == sessionID {
            transcriptViewModel.setStatus(text)
        }
    }
}

extension AppState: LiveTranscriptionEffects {
    func committedLiveCheckpoint() async throws -> AudioCheckpoint {
        try await captureEngine.committedCheckpoint()
    }

    func liveDidChange(_ event: LiveTranscriptionEvent) {
        switch event {
        case .started:
            transcriptViewModel.setDisplayState(.live)
        case .startFailed(let sessionID, let message):
            guard isCurrentRecording(sessionID) else { return }
            processingStatusText =
                "録音は継続しています。ライブ文字起こしを開始できませんでした: \(message)"
        case .registrationFailed(_, let message):
            processingStatusText =
                "録音は継続しています。発話区間を保存できませんでした: \(message)"
        case .recognitionFailed(_, let message):
            processingStatusText =
                "録音は継続しています。ライブ文字起こしを停止しました: \(message)"
        case .thermal(let sessionID, let message):
            showLiveThermalStatus(message, sessionID: sessionID)
        case .vadProgress(let sessionID, let progress):
            if isCurrentRecording(sessionID),
               micInputSessionID == sessionID,
               !progress.micSpeechLevels.isEmpty {
                captureEngine.consumeMicSpeechLevels(progress.micSpeechLevels, sessionID: sessionID)
            }
        case .vadSegmentsEnqueued(let sessionID, let segmentCount):
            if processingState != .backlogged,
               liveTranscription.contentPriorityStatus[sessionID] == nil {
                processingStatusText =
                    "録音中に発話を検出しています（\(segmentCount)区間）"
            }
        case .waitingForModels(let sessionID):
            guard isCurrentRecording(sessionID) else { return }
            processingStatusText = modelPreparation.waitingText
            if displayedSessionID == sessionID {
                transcriptViewModel.setStatus(modelPreparation.waitingText)
            }
        case .vadFailed(let sessionID, let message):
            processingStatusText =
                "録音は継続しています。発話検出を停止しました: \(message)"
            reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
        }
    }
}
