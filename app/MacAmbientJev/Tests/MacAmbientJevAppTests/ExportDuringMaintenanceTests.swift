import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevRuntime

@MainActor
@Test("exporting a recording whose audio is still PCM during launch maintenance reports the maintenance")
func exportDuringMaintenanceReportsMaintenanceForPCMRecordings() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory()
    )
    let checkpoint = AudioCheckpoint(
        committedFrames: 16_000, sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE,
        chunkFiles: [], chunkFrameCounts: [], gapEvents: []
    )
    let session = SavedSession(
        sessionID: UUID(), sessionURL: root.appending(path: "session", directoryHint: .isDirectory),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: .recording(.microphone),
        duration: .seconds(1), audio: .available(.recordedPCM(checkpoint)),
        hasActiveTranscript: true, processingStatus: .complete
    )
    state.isMaintainingStorage = true

    await state.export(session)

    let message = "保存済み録音の音声を整理しています。整理が終わってから書き出してください"
    #expect(state.sessionExports[session.sessionID] == .failed(message))
    #expect(state.processingStatusText == "書き出せませんでした: \(message)")
}
