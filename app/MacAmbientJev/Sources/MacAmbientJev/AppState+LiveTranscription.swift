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
    static func makeFluidLiveVADSession(
        processingDirectory: URL, initialCheckpoint: AudioCheckpoint, measureMicInputLevels: Bool, sessionURL: URL
    ) async throws -> any LiveVADProcessing {
        try await LiveVADSession.make(
            processingDirectory: processingDirectory,
            sessionURL: sessionURL,
            initialCheckpoint: initialCheckpoint,
            measureMicInputLevels: measureMicInputLevels,
            segmentationRunID: "seg_live_\(UUID().uuidString.lowercased())"
        )
    }

    func startLiveVAD(sessionID: UUID) async throws {
        let checkpoint = try await captureEngine.committedCheckpoint()
        guard isCurrentRecording(sessionID) else { return }
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let directory = SessionLayout(sessionURL: sessionURL).processingDirectory

        liveVADFailureText = nil
        liveVADSegmentCount = 0
        let vadSession = try await makeLiveVADSession(
            directory, checkpoint, micInputSessionID == sessionID, sessionURL
        )
        guard isCurrentRecording(sessionID) else { return }
        liveVADSession = vadSession
        transcriptViewModel.setDisplayState(.live)

        do {
            _ = try await sessionProcessor.startLiveTranscription(
                sessionID: sessionID,
                segmentationRunID: vadSession.segmentationRunID,
                sampleRate: checkpoint.sampleRate
            )
        } catch {
            liveASRFailures[sessionID] = error.localizedDescription
            if isCurrentRecording(sessionID) {
                processingStatusText =
                    "録音は継続しています。ライブ文字起こしを開始できませんでした: \(error.localizedDescription)"
            }
        }
        guard isCurrentRecording(sessionID) else {
            cleanupLiveASRState(sessionID: sessionID)
            await sessionProcessor.cancelLiveTranscription(sessionID: sessionID)
            return
        }

        liveVADTask?.cancel()
        liveVADTask = Task { [weak self] in
            await self?.runLiveVADLoop(sessionID: sessionID)
        }
    }

    func runLiveVADLoop(sessionID: UUID) async {
        while !Task.isCancelled,
              recordingSessionID == sessionID,
              recordingPhase == .recording {
            do {
                try await Task.sleep(
                    for: .milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)
                )
            } catch {
                return
            }

            guard !Task.isCancelled,
                  recordingSessionID == sessionID,
                  let liveVADSession else {
                return
            }

            do {
                let checkpoint = try await captureEngine.committedCheckpoint()
                let progress = try await liveVADSession.processAvailable(
                    checkpoint: checkpoint
                )
                liveVADSegmentCount = progress.totalSegmentCount
                // Delivered before ASR enqueueing so transcription latency cannot delay volume decisions.
                if isCurrentRecording(sessionID), micInputSessionID == sessionID,
                   !progress.micSpeechLevels.isEmpty {
                    captureEngine.consumeMicSpeechLevels(progress.micSpeechLevels, sessionID: sessionID)
                }
                if !progress.emittedSegments.isEmpty {
                    await enqueueLiveASR(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint
                    )
                    if processingState != .backlogged, liveContentPriorityStatus[sessionID] == nil {
                        processingStatusText =
                            "録音中に発話を検出しています（\(progress.totalSegmentCount)区間）"
                    }
                }
            } catch {
                liveVADFailureText = error.localizedDescription
                processingStatusText =
                    "録音は継続しています。発話検出を停止しました: \(error.localizedDescription)"
                reportMicSpeechMonitoringUnavailable(sessionID: sessionID)
                return
            }
        }
    }

    func stopLiveVADPolling() async {
        guard let liveVADTask else { return }
        liveVADTask.cancel()
        _ = await liveVADTask.value
        self.liveVADTask = nil
    }

    func enqueueLiveASR(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) async {
        guard !segments.isEmpty,
              liveASRFailures[sessionID] == nil else {
            return
        }

        do {
            _ = try await sessionProcessor.registerLiveSegments(
                sessionID: sessionID,
                segments: segments
            )
        } catch {
            liveASRFailures[sessionID] = error.localizedDescription
            processingStatusText =
                "録音は継続しています。発話区間を保存できませんでした: \(error.localizedDescription)"
            return
        }

        liveASRLatestCheckpoints[sessionID] = checkpoint
        liveASRQueues[sessionID, default: []].append(LiveASRBatch(segments: segments))
        startLiveASRDrainIfIdle(sessionID: sessionID)
    }

    func startLiveASRDrainIfIdle(sessionID: UUID) {
        guard liveASRTasks[sessionID] == nil else { return }
        liveASRTasks[sessionID] = Task { [weak self] in
            await self?.drainLiveASRQueue(sessionID: sessionID)
        }
    }

    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self,
                      self.displayedSessionID == sessionID,
                      self.recordingSessionID == sessionID
                        || (self.currentlyProcessingSessionID == sessionID
                            && self.liveASRTasks[sessionID] != nil) else { return }
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

    func drainLiveASRQueue(sessionID: UUID) async {
        await idleReleaseTask?.value
        while liveASRFailures[sessionID] == nil,
              liveASRQueues[sessionID]?.isEmpty == false {
            do {
                try await waitForLiveThermalHeadroom(sessionID: sessionID)
            } catch {
                break
            }

            guard liveASRFailures[sessionID] == nil,
                  var queue = liveASRQueues[sessionID],
                  !queue.isEmpty else { break }
            guard let checkpoint = liveASRLatestCheckpoints[sessionID] else {
                preconditionFailure("Queued live ASR segments require a committed checkpoint")
            }
            let batch = queue.removeFirst()
            liveASRQueues[sessionID] = queue

            let statusHandler: NativeSessionProcessor.StatusHandler = {
                [weak self] text in
                await MainActor.run {
                    guard let self,
                          self.recordingSessionID == sessionID,
                          self.recordingPhase == .recording else { return }
                    if text.hasPrefix(UserFacingStatus.decisionAuthorizationRequired.text)
                        || text.hasPrefix(UserFacingStatus.decisionDeferred.text)
                        || text.hasPrefix("発話文の判定を保存できませんでした")
                        || text.hasPrefix("ライブの発話文判定に失敗しました") {
                        self.liveContentPriorityStatus[sessionID] = text
                    }
                    let visibleStatus = self.liveContentPriorityStatus[sessionID] ?? text
                    self.processingStatusText = visibleStatus
                    if self.displayedSessionID == sessionID {
                        self.transcriptViewModel.setStatus(visibleStatus)
                    }
                }
            }

            let updateHandler = liveUpdateHandler(sessionID: sessionID)
            do {
                _ = try await sessionProcessor.processLiveSegments(
                    sessionID: sessionID,
                    segments: batch.segments,
                    checkpoint: checkpoint,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            } catch {
                liveASRFailures[sessionID] = error.localizedDescription
                liveASRQueues[sessionID] = []
                processingStatusText =
                    "録音は継続しています。ライブ文字起こしを停止しました: \(error.localizedDescription)"
            }
        }

        liveASRTasks[sessionID] = nil

        if !Task.isCancelled,
           liveASRFailures[sessionID] == nil,
           liveASRQueues[sessionID]?.isEmpty == false {
            startLiveASRDrainIfIdle(sessionID: sessionID)
        }
    }

    /// Thermal pressure only throttles live recognition while recording; the queued backlog stays intact
    /// and resumes from its oldest batch once pressure drops below critical.
    func waitForLiveThermalHeadroom(sessionID: UUID) async throws {
        while isCurrentRecording(sessionID) {
            switch LiveASRThermalPolicy.decision(pressure: readLiveThermalPressure()) {
            case .processNow:
                return
            case .wait(let delay):
                let pendingCount = liveASRQueues[sessionID, default: []]
                    .reduce(0) { $0 + $1.segments.count }
                showLiveThermalStatus(
                    "発熱を抑えるため文字起こしを調整中（未処理 \(pendingCount)区間）",
                    sessionID: sessionID
                )
                try await Task.sleep(for: delay)
                return
            case .suspendUntilCooled:
                showLiveThermalStatus(
                    UserFacingStatus.liveTranscriptionThermalSuspended.text,
                    sessionID: sessionID
                )
                try await Task.sleep(
                    for: .milliseconds(LiveTranscriptionCadence.thermalRecheckIntervalMilliseconds)
                )
            }
        }
    }

    private func showLiveThermalStatus(_ text: String, sessionID: UUID) {
        processingState = .backlogged
        processingStatusText = text
        if displayedSessionID == sessionID {
            transcriptViewModel.setStatus(text)
        }
    }

    static func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        // An unknown state is treated as critical so live recognition never runs on unclassified heat.
        @unknown default: .critical
        }
    }

    func waitForLiveASRDrain(sessionID: UUID) async {
        while let task = liveASRTasks[sessionID] {
            _ = await task.value
        }
    }

    func cleanupLiveASRState(sessionID: UUID) {
        liveASRQueues[sessionID] = nil
        liveASRLatestCheckpoints[sessionID] = nil
        liveASRTasks[sessionID] = nil
        liveASRFailures[sessionID] = nil
        liveContentPriorityStatus[sessionID] = nil
    }
}
