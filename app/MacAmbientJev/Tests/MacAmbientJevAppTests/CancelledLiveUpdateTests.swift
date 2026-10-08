import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCapture
import MacAmbientJevCore
import MacAmbientJevRuntime

private actor BlockedLiveUpdate {
    private var entered: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func wait() async {
        entered?.resume()
        entered = nil
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilBlocked() async {
        if resume != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}

@MainActor
@Test("cancelled session cannot apply a suspended live transcript update")
func cancelledSessionCannotApplySuspendedLiveUpdate() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory()
    )
    state.showNewSession(sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    let handler = state.liveUpdateHandler(sessionID: sessionID)
    let barrier = BlockedLiveUpdate()
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "late", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "取り消した音声", scene: .unknown, speakers: [], scopeSpans: [], isDiarized: false
    )
    let current = try MaterializedTranscriptSegment.fixture(
        segmentID: "current", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "録音中の音声", scene: .unknown, speakers: [], scopeSpans: [], isDiarized: false
    )
    await handler([current], .running)
    let beforeCancellation = state.transcriptViewModel.rows
    #expect(!beforeCancellation.isEmpty)

    let blockedHandler: NativeSessionProcessor.UpdateHandler = { segments, processing in
        await barrier.wait()
        await handler(segments, processing)
    }
    let pending = Task {
        await blockedHandler([segment], .running)
    }
    await barrier.waitUntilBlocked()
    let stopping = state.captureDidFail(
        sessionID: sessionID, message: "録音の保存に失敗しました: disk full"
    )
    await stopping?.value
    await barrier.release()
    await pending.value

    #expect(state.transcriptViewModel.rows == beforeCancellation)
}

@MainActor
@Test
func aStaleLiveUpdateCannotReplaceFinalRowsWhileTheSameSessionIsBeingProcessed() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory), sessionsRootOverride: nil
    )
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: AudioCaptureEngine(paths: paths), microphoneAccess: { false },
        pausesProcessing: false, userDefaults: defaults, engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory()
    )
    let sessionID = UUID()
    state.showNewSession(sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    let liveHandler = state.liveUpdateHandler(sessionID: sessionID)
    let live = try MaterializedTranscriptSegment.fixture(
        segmentID: "live", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "ライブ原文", scene: .unknown, speakers: [], scopeSpans: [], isDiarized: false
    )
    await liveHandler([live], .running)
    #expect(state.transcriptViewModel.rows.map(\.text) == ["ライブ原文"])

    state.recordingSessionID = nil
    state.recordingPhase = .idle
    state.currentlyProcessingSessionID = sessionID
    let final = try MaterializedTranscriptSegment.fixture(
        segmentID: "final", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "確定本文", scene: .unknown, speakers: [], scopeSpans: [], isDiarized: true
    )
    try state.transcriptViewModel.update(segments: [final])
    state.transcriptViewModel.setDisplayState(.finalized)
    let finalizedRows = state.transcriptViewModel.rows
    await liveHandler([live], .running)
    #expect(state.transcriptViewModel.rows == finalizedRows)
    #expect(state.transcriptViewModel.displayState == .finalized)
}
