import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

@MainActor
@Suite(.timeLimit(.minutes(10)))
struct EngineApplicationDeviceReconnectTests {
    private func states(in harness: ApplicationHarness) throws -> [EngineState] {
        try harness.outputs.compactMap { output in
            guard case let .state(state) = output.event else { return nil }
            return state
        }
    }

    private func waitForState(
        in harness: ApplicationHarness,
        after revision: UInt64,
        matching predicate: (EngineState) -> Bool
    ) async throws -> EngineState {
        try await harness.sink.changes.wait("engine state after revision \(revision)") {
            try self.states(in: harness).contains { state in
                state.revision.value > revision && predicate(state)
            }
        }
        return try #require(try states(in: harness).first { state in
            state.revision.value > revision && predicate(state)
        })
    }

    private func deviceLostErrors(
        in harness: ApplicationHarness
    ) throws -> [(output: EngineOutput, failure: EngineFailure)] {
        try harness.outputs.compactMap { output in
            guard case let .error(failure) = output.event, failure.code == .deviceLost else { return nil }
            return (output: output, failure: failure)
        }
    }

    @Test func reconnectCallbacksUpdateWaitingPresentationAndResumeRecording() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = ApplicationHarness(root: root)
        harness.start()
        try await harness.hello()
        try await harness.replaceSettings(engineTestSettings(), expectedRevision: nil)
        try await harness.callAcknowledgingResources("models.prepare")
        guard case let .recordingStart(started) = try await harness.callAcknowledgingResources(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            return
        }

        let captureSession = try #require(harness.capture.session)
        let callbacks = try #require(harness.capture.callbacks)
        try await captureSession.appendSpeech(seconds: 2)

        let recordingState = try await harness.state()
        #expect(recordingState.recording?.sessionID == started.sessionID)
        #expect(recordingState.recording?.phase == .recording)
        callbacks.onSilenceChanged(true)
        callbacks.onDeviceWaitingChanged(true)

        let waitingState = try await waitForState(in: harness, after: recordingState.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .waitingForDevice
                && state.presentation.recordingStatusText == "録音デバイスの復帰を待っています"
                && state.presentation.recordingTone == .warning
                && !state.presentation.silenceWarningActive
                && state.presentation.silenceWarningText == nil
        }
        #expect(waitingState.recording?.sessionID == started.sessionID)
        #expect(waitingState.recording?.phase == .waitingForDevice)
        #expect(waitingState.presentation.recordingStatusText == "録音デバイスの復帰を待っています")
        #expect(waitingState.presentation.recordingTone == .warning)
        #expect(!waitingState.presentation.silenceWarningActive)
        #expect(waitingState.presentation.silenceWarningText == nil)

        callbacks.onSilenceChanged(true)
        let afterSuppressedSilence = try await harness.state()
        #expect(afterSuppressedSilence.revision == waitingState.revision)
        #expect(!afterSuppressedSilence.presentation.silenceWarningActive)
        #expect(afterSuppressedSilence.presentation.silenceWarningText == nil)

        callbacks.onDropouts(1)
        let gapState = try await waitForState(in: harness, after: waitingState.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.presentation.audioGapCount == 1
                && state.presentation.audioGapText == "音声の欠落: 1 回"
        }
        #expect(gapState.presentation.audioGapCount == 1)
        #expect(gapState.presentation.audioGapText == "音声の欠落: 1 回")

        callbacks.onDeviceWaitingChanged(false)
        let resumedState = try await waitForState(in: harness, after: gapState.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .recording
                && state.presentation.recordingStatusText == "マイクを録音中"
                && state.presentation.recordingTone == .recording
                && !state.presentation.silenceWarningActive
                && state.presentation.silenceWarningText == nil
        }
        #expect(resumedState.recording?.sessionID == started.sessionID)
        #expect(resumedState.recording?.phase == .recording)
        #expect(resumedState.presentation.recordingStatusText == "マイクを録音中")
        #expect(resumedState.presentation.recordingTone == .recording)
        #expect(!resumedState.presentation.silenceWarningActive)
        #expect(resumedState.presentation.silenceWarningText == nil)
        #expect(resumedState.presentation.audioGapCount == 1)
        #expect(resumedState.presentation.audioGapText == "音声の欠落: 1 回")

        try await harness.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
        #expect(captureSession.isStopped)
        let finalized = try await harness.waitForSession(status: .finalized)
        #expect(finalized.sessionID == started.sessionID)
        #expect(try await harness.shutdown() == .shutdownRequested)
    }

    @Test(arguments: [String?.none, String?.some("Native operation mja_capture_open failed with code -401")])
    func lostDeviceSavesDurableAudioReportsWarningAndKeepsEngineAvailable(lastReopenError: String?) async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = ApplicationHarness(root: root)
        harness.start()
        try await harness.hello()
        try await harness.replaceSettings(engineTestSettings(), expectedRevision: nil)
        try await harness.callAcknowledgingResources("models.prepare")
        guard case let .recordingStart(started) = try await harness.callAcknowledgingResources(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            return
        }

        let captureSession = try #require(harness.capture.session)
        let callbacks = try #require(harness.capture.callbacks)
        try await captureSession.appendSpeech(seconds: 2)
        let committed = try await captureSession.committedCheckpoint()
        #expect(committed.committedFrames == 32_000)

        let sessionsBeforeLoss = try await harness.sessions()
        let activeSession = try #require(sessionsBeforeLoss.first)
        #expect(activeSession.sessionID == started.sessionID)
        let layout = SessionLayout(
            sessionURL: harness.paths.sessionsRoot.appending(path: activeSession.folderID, directoryHint: .isDirectory)
        )
        let durableCheckpoint = try #require(try AudioCheckpoint.loadRecovered(
            from: layout.processingDirectory,
            relativeTo: layout.sessionURL
        ))
        #expect(durableCheckpoint.committedFrames == committed.committedFrames)
        let durableSamples = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: durableCheckpoint,
            sessionURL: layout.sessionURL
        ).readSamples(frameRange: 0..<durableCheckpoint.committedFrames)
        #expect(durableSamples.count == Int(durableCheckpoint.committedFrames))
        #expect(durableSamples.contains { $0 != 0 })

        let recordingState = try await harness.state()
        callbacks.onDeviceWaitingChanged(true)
        let waitingState = try await waitForState(in: harness, after: recordingState.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .waitingForDevice
                && state.presentation.recordingStatusText == "録音デバイスの復帰を待っています"
        }
        #expect(waitingState.recording?.phase == .waitingForDevice)

        let expectedReopenDetails: [EngineErrorDetail]
        if let lastReopenError {
            expectedReopenDetails = [try EngineErrorDetail(
                domain: "capture", code: "reopen", message: lastReopenError, path: nil, deviceID: nil
            )]
        } else {
            expectedReopenDetails = []
        }

        callbacks.onDeviceLost(lastReopenError)
        callbacks.onDeviceWaitingChanged(false)
        callbacks.onDeviceLost(nil)
        let stoppingState = try await waitForState(in: harness, after: waitingState.revision.value) { state in
            state.recording?.sessionID == started.sessionID
                && state.recording?.phase == .stopping
                && state.presentation.recordingStatusText == "録音を保存しています"
                && state.presentation.recordingTone == .neutral
        }
        let firstPostWaitingState = try #require(try states(in: harness).first { state in
            state.revision.value > waitingState.revision.value
        })
        #expect(firstPostWaitingState.revision == stoppingState.revision)
        #expect(firstPostWaitingState.recording?.phase == .stopping)
        #expect(firstPostWaitingState.presentation.recordingStatusText == "録音を保存しています")
        #expect(firstPostWaitingState.presentation.recordingTone == .neutral)

        try await harness.sink.changes.wait("unsolicited device-lost error") {
            try self.deviceLostErrors(in: harness).contains { $0.output.requestID == nil }
        }

        let failureEvents = try deviceLostErrors(in: harness)
        #expect(failureEvents.count == 1)
        let failureEvent = try #require(failureEvents.first)
        #expect(failureEvent.output.requestID == nil)
        #expect(failureEvent.failure.code == .deviceLost)
        #expect(failureEvent.failure.message == "録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています")
        #expect(failureEvent.failure.stage == .capture)
        #expect(failureEvent.failure.sessionID == started.sessionID)
        #expect(failureEvent.failure.requestID == nil)
        #expect(failureEvent.failure.severity == .warning)
        #expect(failureEvent.failure.recoveryAction == .selectDevice)
        #expect(failureEvent.failure.details == expectedReopenDetails)
        #expect(failureEvent.failure.cleanupErrors.isEmpty)
        #expect(captureSession.isStopped)

        let finalized = try await harness.waitForSession(status: .finalized)
        #expect(finalized.sessionID == started.sessionID)
        guard case let .recordingFLAC(storedAudio) = try SessionAudioStorageStore(layout: layout).load() else {
            Issue.record("device-lost recording was not retained as finalized audio")
            return
        }
        let storedReader = try FLACTimelineReader(
            url: layout.recordingFLACURL,
            info: storedAudio,
            sessionURL: layout.sessionURL
        )
        try storedReader.validateAudio()
        #expect(storedAudio.committedFrames == durableCheckpoint.committedFrames)

        let state = try await harness.state()
        let emittedStates = try states(in: harness)
        let postWaitingStates = emittedStates.filter { state in
            state.revision.value > waitingState.revision.value
        }
        #expect(postWaitingStates.allSatisfy { $0.recording?.phase != .recording })
        #expect(postWaitingStates.allSatisfy { $0.presentation.recordingTone != .recording })
        #expect(state.recording == nil)
        #expect(state.failures.allSatisfy { $0.severity != .fatal })
        for emittedState in emittedStates {
            for emittedFailure in emittedState.failures where emittedFailure.code == .deviceLost {
                #expect(emittedFailure.details == failureEvent.failure.details)
                #expect(emittedFailure.cleanupErrors == failureEvent.failure.cleanupErrors)
            }
        }
        let errors = try harness.outputs.compactMap { output -> EngineFailure? in
            guard case let .error(failure) = output.event else { return nil }
            return failure
        }
        #expect(errors.allSatisfy { $0.severity != .fatal })
        let listedSessions = try await harness.sessions()
        #expect(listedSessions.count == 1)
        #expect(listedSessions.first?.sessionID == started.sessionID)
        #expect(listedSessions.first?.status == .finalized)
        #expect(try deviceLostErrors(in: harness).count == 1)
        #expect(try await harness.shutdown() == .shutdownRequested)
    }
}
