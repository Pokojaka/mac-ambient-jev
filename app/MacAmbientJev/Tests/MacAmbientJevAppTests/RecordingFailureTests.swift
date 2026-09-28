import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@MainActor
@Test("durable write failure stops recording and preserves committed audio")
func durableWriteFailureStopsCaptureWithoutDeletingAudio() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
    )
    let sessionID = UUID()
    let state = AppState(paths: paths)
    state.markRecordingStarted(sessionID: sessionID)
    let sessionURL = try SessionBootstrapper().createSession(
        paths: paths, sessionID: sessionID, sourceKind: .live
    )
    let directory = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: directory, sampleRate: 16_000, channelCount: 1, chunkDurationSeconds: 1
    )
    try await writer.append(samples: Array(repeating: 0.25, count: 16_000))
    let checkpoint = await writer.committedSnapshot()

    let stopping = state.captureDidFail(sessionID: sessionID)
    #expect(state.recordingPhase == .stopping)
    #expect(state.statusText == "録音の保存に失敗しました")
    await stopping?.value

    #expect(state.recordingPhase == .idle)
    #expect(!state.isRecording)
    #expect(FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(state.savedSessions.first(where: { $0.sessionID == sessionID })?.audioSource
        == .processingTimeline(checkpoint))
    #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint)
        .readSamples(frameRange: 0..<16_000) == Array(repeating: 0.25, count: 16_000))
}
