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
        processingDirectory: URL, initialCheckpoint: AudioCheckpoint, measureMicInputLevels: Bool
    ) async throws -> any LiveVADProcessing {
        try await LiveVADSession.make(
            processingDirectory: processingDirectory,
            initialCheckpoint: initialCheckpoint,
            measureMicInputLevels: measureMicInputLevels
        )
    }

    func startLiveVAD(sessionID: UUID) async throws {
        let checkpoint = try await captureEngine.committedCheckpoint()
        guard isCurrentRecording(sessionID) else { return }
        let directory = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)

        liveVADFailureText = nil
        liveVADSegmentCount = 0
        let vadSession = try await makeLiveVADSession(
            directory, checkpoint, micInputSessionID == sessionID
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
                    if processingState != .backlogged {
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

        liveASRQueues[sessionID, default: []].append(
            LiveASRBatch(
                segments: segments,
                checkpoint: checkpoint,
                enqueuedAt: Date()
            )
        )

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
                      self.recordingSessionID == sessionID,
                      self.recordingPhase == .recording else { return }
                self.processingState = state
                self.transcriptViewModel.update(segments: segments)
                self.transcriptViewModel.setDisplayState(.live)
            }
        }
    }

    func drainLiveASRQueue(sessionID: UUID) async {
        while liveASRFailures[sessionID] == nil,
              let pending = liveASRQueues[sessionID],
              let oldest = pending.first {
            if recordingSessionID == sessionID,
               recordingPhase == .recording {
                let pressure = Self.thermalPressure(
                    from: ProcessInfo.processInfo.thermalState
                )
                let pendingCount = pending.reduce(0) { $0 + $1.segments.count }
                let decision = LiveASRThermalPolicy.decision(
                    pressure: pressure,
                    pendingCount: pendingCount,
                    oldestPendingAge: Date().timeIntervalSince(oldest.enqueuedAt)
                )
                if case .wait(let delay) = decision {
                    processingState = .backlogged
                    let text = "発熱を抑えるため文字起こしを調整中（未処理 \(pendingCount)区間）"
                    processingStatusText = text
                    transcriptViewModel.setStatus(text)
                    try? await Task.sleep(for: delay)
                }
            }

            guard liveASRFailures[sessionID] == nil,
                  var queue = liveASRQueues[sessionID],
                  !queue.isEmpty else { break }
            let batch = queue.removeFirst()
            liveASRQueues[sessionID] = queue

            let statusHandler: NativeSessionProcessor.StatusHandler = {
                [weak self] text in
                await MainActor.run {
                    guard let self,
                          self.recordingSessionID == sessionID,
                          self.recordingPhase == .recording else { return }
                    self.processingStatusText = text
                    if self.displayedSessionID == sessionID {
                        self.transcriptViewModel.setStatus(text)
                    }
                }
            }

            let updateHandler = liveUpdateHandler(sessionID: sessionID)
            do {
                _ = try await sessionProcessor.processLiveSegments(
                    sessionID: sessionID,
                    segments: batch.segments,
                    checkpoint: batch.checkpoint,
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

        if liveASRFailures[sessionID] == nil,
           let queue = liveASRQueues[sessionID],
           !queue.isEmpty {
            liveASRTasks[sessionID] = Task { [weak self] in
                await self?.drainLiveASRQueue(sessionID: sessionID)
            }
        }
    }

    static func thermalPressure(
        from state: ProcessInfo.ThermalState
    ) -> ThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
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
        liveASRTasks[sessionID] = nil
        liveASRFailures[sessionID] = nil
    }
}
