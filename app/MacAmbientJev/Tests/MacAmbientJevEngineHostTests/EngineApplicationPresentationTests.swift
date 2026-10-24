import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private final class MutablePresentationCaptureClock: CaptureClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval

    init(time: TimeInterval) {
        self.time = time
    }

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func set(_ time: TimeInterval) {
        lock.lock()
        self.time = time
        lock.unlock()
    }
}

private struct AmplePresentationCaptureDiskSpace: CaptureDiskSpaceProviding {
    func availableBytes(at url: URL) throws -> Int64? { 1_000_000_000 }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationPresentationTests {
    private func preparedHarness(root: URL) async throws -> ApplicationHarness {
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(try engineTestSettings(), expectedRevision: nil)
        try await h.call("models.prepare")
        return h
    }

    private func startRecording(in h: ApplicationHarness, source: EngineSource) async throws -> (id: String, uuid: UUID) {
        guard case let .recordingStart(started) = try await h.call(
            "recording.start", payload: "{\"source\":\"\(source.rawValue)\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            throw TestTimeout(description: "missing recording session")
        }
        return (started.sessionID, try #require(UUID(uuidString: started.sessionID)))
    }

    private func states(in h: ApplicationHarness) throws -> [EngineState] {
        try h.outputs.compactMap { output in
            guard case let .state(state) = output.event else { return nil }
            return state
        }
    }

    private func waitForState(
        in h: ApplicationHarness,
        after revision: UInt64,
        matching predicate: (EngineState) -> Bool
    ) async throws -> EngineState {
        try await h.sink.changes.wait("engine state after revision \(revision)") {
            try self.states(in: h).contains { state in
                state.revision.value > revision && predicate(state)
            }
        }
        return try #require(try states(in: h).first { state in
            state.revision.value > revision && predicate(state)
        })
    }

    private func waitForFinalizedRecording(
        in h: ApplicationHarness,
        after revision: UInt64
    ) async throws -> EngineState {
        try await waitForState(in: h, after: revision) { state in
            state.recording == nil
                && state.queue.isEmpty
                && state.presentation.processingIndicator == .complete
                && state.presentation.processingStatusText == "文字起こしと話者分離が完了しました（1区間）"
        }
    }

    private func appendSpeech(in h: ApplicationHarness, seconds: Double) async throws {
        let capture = try #require(h.capture.session)
        try await capture.appendSpeech(seconds: seconds)
    }

    private func removeTestRoot(_ root: URL) {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        precondition(resolvedRoot.deletingLastPathComponent() == temporaryDirectory)
        precondition(resolvedRoot.lastPathComponent.hasPrefix("engine-app-"))
        do {
            try FileManager.default.removeItem(at: resolvedRoot)
        } catch {
            Issue.record("could not remove test root: \(error)")
        }
    }

    @Test(
        "real capture health monitor publishes source-specific silence and audio gaps",
        arguments: [EngineSource.microphone, .systemAudio]
    )
    func captureHealthMonitorPresentation(source: EngineSource) async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeTestRoot(root) }
        let h = try await preparedHarness(root: root)
        let started = try await startRecording(in: h, source: source)
        let callbacks = try #require(h.capture.callbacks)
        let expectedRecordingText = source == .microphone ? "マイクを録音中" : "システム音声を録音中"
        let expectedSilenceText = source == .microphone
            ? "マイク入力が30秒以上無音です。ミュート設定を確認してください"
            : "システム音声が30秒以上無音です"
        let startedState = try await h.state()
        #expect(startedState.recording?.sessionID == started.id)
        #expect(startedState.presentation.recordingStatusText == expectedRecordingText)
        #expect(!startedState.presentation.silenceWarningActive)
        #expect(startedState.presentation.silenceWarningText == nil)

        let clock = MutablePresentationCaptureClock(time: 100)
        let monitor = CaptureHealthMonitor(
            source: source == .microphone ? .microphone : .systemAudio,
            clock: clock,
            diskSpace: AmplePresentationCaptureDiskSpace(),
            directory: h.paths.sessionsRoot,
            startedAt: 100,
            onFailure: callbacks.onFailure,
            onWarning: callbacks.onWarning,
            onDropouts: callbacks.onDropouts,
            onSilenceChanged: callbacks.onSilenceChanged
        )

        clock.set(129.999)
        #expect(monitor.poll(lastBufferMillis: 129_999, silentSinceMillis: 100_000, dropouts: 0))
        let beforeThreshold = try await h.state()
        #expect(beforeThreshold.revision == startedState.revision)
        #expect(!beforeThreshold.presentation.silenceWarningActive)
        #expect(beforeThreshold.presentation.silenceWarningText == nil)

        clock.set(130)
        #expect(monitor.poll(lastBufferMillis: 130_000, silentSinceMillis: 100_000, dropouts: 0))
        let silenceState = try await waitForState(in: h, after: beforeThreshold.revision.value) { state in
            state.presentation.silenceWarningActive && state.presentation.silenceWarningText == expectedSilenceText
        }
        #expect(silenceState.revision.value > beforeThreshold.revision.value)
        #expect(silenceState.presentation.silenceWarningActive)
        #expect(silenceState.presentation.silenceWarningText == expectedSilenceText)

        clock.set(130.001)
        #expect(monitor.poll(lastBufferMillis: 130_001, silentSinceMillis: 0, dropouts: 0))
        let resumedState = try await waitForState(in: h, after: silenceState.revision.value) { state in
            !state.presentation.silenceWarningActive && state.presentation.silenceWarningText == nil
        }
        #expect(!resumedState.presentation.silenceWarningActive)
        #expect(resumedState.presentation.silenceWarningText == nil)

        clock.set(160)
        #expect(monitor.poll(lastBufferMillis: 160_000, silentSinceMillis: 130_000, dropouts: 0))
        let secondSilenceState = try await waitForState(in: h, after: resumedState.revision.value) { state in
            state.presentation.silenceWarningActive && state.presentation.silenceWarningText == expectedSilenceText
        }

        clock.set(160.001)
        #expect(monitor.poll(lastBufferMillis: 160_001, silentSinceMillis: 130_000, dropouts: 1))
        let oneGapState = try await waitForState(in: h, after: secondSilenceState.revision.value) { state in
            state.presentation.audioGapCount == 1 && state.presentation.audioGapText == "音声の欠落: 1 回"
        }
        #expect(oneGapState.presentation.audioGapCount == 1)
        #expect(oneGapState.presentation.audioGapText == "音声の欠落: 1 回")

        clock.set(160.002)
        #expect(monitor.poll(lastBufferMillis: 160_002, silentSinceMillis: 130_000, dropouts: 2))
        let twoGapState = try await waitForState(in: h, after: oneGapState.revision.value) { state in
            state.presentation.audioGapCount == 2 && state.presentation.audioGapText == "音声の欠落: 2 回"
        }
        #expect(twoGapState.presentation.audioGapCount == 2)
        #expect(twoGapState.presentation.audioGapText == "音声の欠落: 2 回")

        clock.set(160.003)
        #expect(monitor.poll(lastBufferMillis: 160_003, silentSinceMillis: 130_000, dropouts: 2))
        let repeatedPollState = try await h.state()
        #expect(repeatedPollState.revision == twoGapState.revision)
        #expect(repeatedPollState.presentation.audioGapCount == 2)
        #expect(repeatedPollState.presentation.audioGapText == "音声の欠落: 2 回")

        try await appendSpeech(in: h, seconds: 2)
        let beforeFinalization = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.id)\"}")
        let stoppedState = try await h.state()
        #expect(stoppedState.recording == nil)
        #expect(!stoppedState.presentation.silenceWarningActive)
        #expect(stoppedState.presentation.silenceWarningText == nil)
        #expect(stoppedState.presentation.audioGapText == nil)
        let finalized = try await waitForFinalizedRecording(in: h, after: beforeFinalization.revision.value)
        #expect(finalized.presentation.silenceWarningText == nil)
        #expect(finalized.presentation.audioGapText == nil)
        #expect(finalized.failures.isEmpty)
        #expect(try h.outputs.allSatisfy { output in
            if case .error = output.event { return false }
            return true
        })

        let next = try await startRecording(in: h, source: source)
        let nextState = try await h.state()
        #expect(nextState.recording?.sessionID == next.id)
        #expect(nextState.presentation.audioGapCount == 0)
        #expect(nextState.presentation.audioGapText == nil)
        #expect(!nextState.presentation.silenceWarningActive)
        #expect(nextState.presentation.silenceWarningText == nil)

        callbacks.onDropouts(9)
        callbacks.onSilenceChanged(true)
        let afterOldCallbacks = try await h.state()
        #expect(afterOldCallbacks.revision == nextState.revision)
        #expect(afterOldCallbacks.presentation.audioGapCount == 0)
        #expect(afterOldCallbacks.presentation.audioGapText == nil)
        #expect(!afterOldCallbacks.presentation.silenceWarningActive)
        #expect(afterOldCallbacks.presentation.silenceWarningText == nil)

        try await appendSpeech(in: h, seconds: 2)
        let beforeSecondFinalization = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(next.id)\"}")
        _ = try await waitForFinalizedRecording(in: h, after: beforeSecondFinalization.revision.value)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test("recording presentation uses native save and completion statuses")
    func recordingAndFinalizationPresentation() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeTestRoot(root) }
        let h = try await preparedHarness(root: root)
        let started = try await startRecording(in: h, source: .microphone)
        let recordingState = try await h.state()
        #expect(recordingState.presentation.recordingStatusText == "マイクを録音中")

        try await appendSpeech(in: h, seconds: 2)
        let beforeFinalization = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.id)\"}")
        let savedState = try await h.state()
        #expect(savedState.recording == nil)
        #expect(savedState.presentation.recordingStatusText == "録音を保存しました（00:02・発話 1区間）")

        let finalized = try await waitForFinalizedRecording(in: h, after: beforeFinalization.revision.value)
        #expect(finalized.presentation.processingIndicator == .complete)
        #expect(finalized.presentation.processingStatusText == "文字起こしと話者分離が完了しました（1区間）")
        #expect(finalized.failures.isEmpty)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test("partial live failure preserves the recording status text")
    func partialLiveFailurePreservesProcessingStatusText() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeTestRoot(root) }
        let h = try await preparedHarness(root: root)
        let started = try await startRecording(in: h, source: .microphone)
        let core = h.app.core
        let ordinaryStatus = "録音中の発話を文字起こししています"
        let liveStatus = core.liveStatusHandler(sessionID: started.uuid)
        await liveStatus(.message(ordinaryStatus))
        let statusState = try await h.state()
        #expect(statusState.presentation.processingStatusText == ordinaryStatus)

        let liveUpdate = core.liveUpdateHandler(sessionID: started.uuid)
        await liveUpdate([], .partialFailure("部分的な失敗"))
        let partialFailureState = try await waitForState(in: h, after: statusState.revision.value) { state in
            state.presentation.processingIndicator == .partialFailure
        }
        #expect(partialFailureState.presentation.processingIndicator == .partialFailure)
        #expect(partialFailureState.presentation.processingStatusText == ordinaryStatus)
        #expect(partialFailureState.presentation.liveFailureNotices == statusState.presentation.liveFailureNotices)

        try await appendSpeech(in: h, seconds: 2)
        let beforeStop = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.id)\"}")
        _ = try await waitForFinalizedRecording(in: h, after: beforeStop.revision.value)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test("live notices and processing states flow through real application handlers")
    func liveNoticesAndProcessingIndicators() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeTestRoot(root) }
        let h = try await preparedHarness(root: root)
        let started = try await startRecording(in: h, source: .microphone)
        let core = h.app.core

        let cases: [(LiveTranscriptionEvent, String)] = [
            (
                .startFailed(started.uuid, "start detail"),
                "録音は継続しています。ライブ文字起こしを開始できませんでした: start detail"
            ),
            (
                .registrationFailed(started.uuid, "registration detail"),
                "録音は継続しています。発話区間を保存できませんでした: registration detail"
            ),
            (
                .recognitionFailed(started.uuid, "recognition detail"),
                "録音は継続しています。ライブ文字起こしを停止しました: recognition detail"
            ),
            (
                .vadFailed(started.uuid, "vad detail"),
                "録音は継続しています。発話検出を停止しました: vad detail"
            )
        ]
        var expectedNotices: [String] = []
        for (event, expectedNotice) in cases {
            let before = try await h.state()
            core.liveDidChange(event)
            let changed = try await waitForState(in: h, after: before.revision.value) { state in
                state.presentation.liveFailureNotices.last == expectedNotice
            }
            expectedNotices.append(expectedNotice)
            #expect(changed.presentation.liveFailureNotices == expectedNotices)
        }

        let normalStatus = "録音中の発話を文字起こししています"
        let normalHandler = core.liveStatusHandler(sessionID: started.uuid)
        await normalHandler(.message(normalStatus))
        let afterNormalStatus = try await h.state()
        #expect(afterNormalStatus.presentation.processingStatusText == normalStatus)
        #expect(afterNormalStatus.presentation.liveFailureNotices == expectedNotices)

        let duplicateMessage = "録音は継続しています。ライブ文字起こしを開始できませんでした: duplicate"
        let beforeDuplicate = try await h.state()
        core.liveDidChange(.startFailed(started.uuid, "duplicate"))
        let withDuplicate = try await waitForState(in: h, after: beforeDuplicate.revision.value) { state in
            state.presentation.liveFailureNotices.last == duplicateMessage
        }
        #expect(withDuplicate.presentation.processingStatusText == normalStatus)
        core.liveDidChange(.startFailed(started.uuid, "duplicate"))
        let afterDuplicateRepeat = try await h.state()
        #expect(afterDuplicateRepeat.presentation.liveFailureNotices.filter { $0 == duplicateMessage }.count == 1)

        for index in 0..<20 {
            core.liveDidChange(.startFailed(started.uuid, "cap-\(index)"))
        }
        let cappedNotices = (4..<20).map {
            "録音は継続しています。ライブ文字起こしを開始できませんでした: cap-\($0)"
        }
        let cappedState = try await waitForState(in: h, after: withDuplicate.revision.value) { state in
            state.presentation.liveFailureNotices == cappedNotices
        }
        #expect(cappedState.presentation.liveFailureNotices.count == EngineApplicationCore.failureLimit)
        #expect(cappedState.presentation.liveFailureNotices == cappedNotices)
        #expect(cappedState.presentation.processingStatusText == normalStatus)
        #expect(cappedState.revision.value > withDuplicate.revision.value)

        let liveUpdate = core.liveUpdateHandler(sessionID: started.uuid)
        let processingCases: [(ProcessingState, EngineProcessingIndicator)] = [
            (.running, .running),
            (.idle, .idle),
            (.backlogged, .backlogged),
            (.complete, .complete),
            (.partialFailure("partial failure detail"), .partialFailure)
        ]
        for (processingState, indicator) in processingCases {
            let before = try await h.state()
            await liveUpdate([], processingState)
            let changed = try await waitForState(in: h, after: before.revision.value) { state in
                state.presentation.processingIndicator == indicator
            }
            #expect(changed.presentation.processingIndicator == indicator)
            #expect(changed.presentation.processingStatusText == normalStatus)
            #expect(changed.presentation.liveFailureNotices == cappedNotices)
        }

        try await appendSpeech(in: h, seconds: 2)
        let beforeStop = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.id)\"}")
        let stoppedState = try await h.state()
        #expect(stoppedState.recording == nil)
        #expect(stoppedState.presentation.liveFailureNotices == cappedNotices)
        _ = try await waitForFinalizedRecording(in: h, after: beforeStop.revision.value)

        let next = try await startRecording(in: h, source: .microphone)
        let nextState = try await h.state()
        #expect(nextState.recording?.sessionID == next.id)
        #expect(nextState.presentation.liveFailureNotices.isEmpty)
        #expect(nextState.presentation.processingStatusText == nil)
        #expect(nextState.presentation.processingIndicator == .idle)

        try await appendSpeech(in: h, seconds: 2)
        let beforeSecondStop = try await h.state()
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(next.id)\"}")
        _ = try await waitForFinalizedRecording(in: h, after: beforeSecondStop.revision.value)
        #expect(try await h.shutdown() == .shutdownRequested)
    }
}
