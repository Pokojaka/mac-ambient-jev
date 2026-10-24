import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

struct SavedFinishToneCase: Sendable, CustomTestStringConvertible {
    let name: String
    let didOverflow: Bool
    let releaseFailure: String?
    let failureMessage: String?
    let vadFailureText: String?
    let expectedText: String
    let expectedTone: EngineRecordingTone

    var testDescription: String { name }
}

@MainActor
@Suite struct EngineApplicationRecordingPresentationRegressionTests {
    private func makeHarness() throws -> ApplicationHarness {
        ApplicationHarness(root: try ApplicationHarness.makeRoot())
    }

    private func stopResult(didOverflow: Bool, releaseFailure: String?) -> AudioCaptureStopResult {
        let checkpoint = AudioCheckpoint(
            committedFrames: 32_000,
            sampleRate: 16_000,
            channelCount: 1,
            sampleFormat: .float32LE,
            chunkFiles: ["audio-00000.f32le"],
            chunkFrameCounts: [32_000],
            gapEvents: []
        )
        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: didOverflow,
            dropoutCount: 0,
            gapCount: 0,
            totalGapFrames: 0,
            sleepAssertionHeld: false,
            writerFailure: nil,
            systemAudioReleaseFailure: releaseFailure
        )
    }

    private func removeRoot(_ root: URL) {
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

    @Test func recordingStartKeepsStartingTextUntilRecordingDidStart() throws {
        let harness = try makeHarness()
        defer { removeRoot(harness.root) }
        let core = harness.app.core
        let sessionID = UUID()
        core.recording.start(sessionID: sessionID)
        core.startAttempt = .init(source: .microphone, device: .default, sessionURL: nil, error: nil)
        core.activeRecording = (.microphone, .default)

        core.recordingStartDidBegin(sessionID: sessionID)
        #expect(core.presentation.recordingStatusText == UserFacingStatus.startingRecording.text)
        #expect(try core.presentationState().recordingTone == .neutral)

        core.markRecordingStarted(sessionID: sessionID)
        #expect(core.presentation.recordingStatusText == UserFacingStatus.startingRecording.text)
        #expect(try core.presentationState().recordingTone == .neutral)

        core.recordingDidStart(sessionID: sessionID)
        #expect(core.presentation.recordingStatusText == "マイクを録音中")
        #expect(try core.presentationState().recordingTone == .recording)
    }

    @Test func partialLiveFailurePreservesProcessingTextAndNotices() async throws {
        let harness = try makeHarness()
        defer { removeRoot(harness.root) }
        let core = harness.app.core
        let sessionID = UUID()
        core.recording.start(sessionID: sessionID)
        core.recording.didStart(sessionID: sessionID)
        core.activeRecording = (.microphone, .default)
        let previousText = "録音中の発話を文字起こししています"
        let previousNotices = ["既存のライブ失敗通知"]
        core.presentation.processingStatusText = previousText
        core.presentation.liveFailureNotices = previousNotices

        let liveUpdate = core.liveUpdateHandler(sessionID: sessionID)
        await liveUpdate([], .partialFailure("部分的な失敗"))

        #expect(core.presentation.processingState == .partialFailure("部分的な失敗"))
        #expect(core.presentation.processingStatusText == previousText)
        #expect(core.presentation.liveFailureNotices == previousNotices)
        let presentationState = try core.presentationState()
        #expect(presentationState.processingIndicator == .partialFailure)
        #expect(presentationState.processingStatusText == previousText)
        #expect(presentationState.liveFailureNotices == previousNotices)
    }

    @Test func cancelledStartKeepsJapaneseErrorPresentation() throws {
        let harness = try makeHarness()
        defer { removeRoot(harness.root) }
        let core = harness.app.core
        core.startAttempt = .init(source: .microphone, device: .default, sessionURL: nil, error: nil)
        core.setRecordingStatus("マイクを録音中", tone: .recording)

        core.recordingStartDidFail(.cancelled)

        #expect(core.startAttempt?.error?.message == "録音の開始を中止しました")
        #expect(core.presentation.recordingStatusText == "録音の開始を中止しました")
        #expect(try core.presentationState().recordingTone == .neutral)
    }

    @Test func failedStartKeepsJapaneseErrorPresentation() throws {
        let harness = try makeHarness()
        defer { removeRoot(harness.root) }
        let core = harness.app.core
        let message = "入力デバイスを開始できませんでした"
        core.startAttempt = .init(source: .microphone, device: .default, sessionURL: nil, error: nil)
        core.setRecordingStatus("マイクを録音中", tone: .recording)

        core.recordingStartDidFail(.failed(message))

        #expect(core.startAttempt?.error?.message == message)
        #expect(core.presentation.recordingStatusText == message)
        #expect(try core.presentationState().recordingTone == .error)
    }

    @Test(arguments: [
        SavedFinishToneCase(
            name: "clean save",
            didOverflow: false,
            releaseFailure: nil,
            failureMessage: nil,
            vadFailureText: nil,
            expectedText: "録音を保存しました（00:02）",
            expectedTone: .neutral
        ),
        SavedFinishToneCase(
            name: "release warning takes priority",
            didOverflow: true,
            releaseFailure: "オーディオタップの解放に失敗しました",
            failureMessage: nil,
            vadFailureText: "発話検出器を利用できません",
            expectedText: "録音は保存しましたが、オーディオタップの解放に失敗しました",
            expectedTone: .warning
        ),
        SavedFinishToneCase(
            name: "overflow warning takes priority over VAD warning",
            didOverflow: true,
            releaseFailure: nil,
            failureMessage: nil,
            vadFailureText: "発話検出器を利用できません",
            expectedText: "録音は保存しましたが、一部の音声が欠落した可能性があります。",
            expectedTone: .warning
        ),
        SavedFinishToneCase(
            name: "VAD warning",
            didOverflow: false,
            releaseFailure: nil,
            failureMessage: nil,
            vadFailureText: "発話検出器を利用できません",
            expectedText: "録音を保存しました。発話検出を後で再実行します: 発話検出器を利用できません",
            expectedTone: .warning
        ),
        SavedFinishToneCase(
            name: "supplied failure takes priority",
            didOverflow: true,
            releaseFailure: "オーディオタップの解放に失敗しました",
            failureMessage: "録音保存中に致命的なエラーが発生しました",
            vadFailureText: "発話検出器を利用できません",
            expectedText: "録音保存中に致命的なエラーが発生しました",
            expectedTone: .error
        )
    ])
    func savedFinishUsesRecordingToneAndPriorityOrder(_ finishCase: SavedFinishToneCase) throws {
        let harness = try makeHarness()
        defer { removeRoot(harness.root) }
        let core = harness.app.core
        let sessionID = UUID()
        core.recording.start(sessionID: sessionID)
        core.recording.didStart(sessionID: sessionID)
        core.activeRecording = (.microphone, .default)
        core.recordingDidStart(sessionID: sessionID)
        #expect(try core.presentationState().recordingTone == .recording)

        core.recordingDidFinish(.saved(
            result: stopResult(didOverflow: finishCase.didOverflow, releaseFailure: finishCase.releaseFailure),
            failureMessage: finishCase.failureMessage,
            vadFailureText: finishCase.vadFailureText,
            vadSegmentCount: 0
        ))

        let finishedPresentation = try core.presentationState()
        #expect(finishedPresentation.recordingStatusText == finishCase.expectedText, Comment(rawValue: finishCase.name))
        #expect(finishedPresentation.recordingTone == finishCase.expectedTone, Comment(rawValue: finishCase.name))
    }
}
