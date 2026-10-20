import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevRuntime

@MainActor
@Test("Finder reveals the catalog's own session folder and the sessions root, and fails when a folder is absent")
func revealTargetsComeFromTheCatalogAndFailWhenMissing() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal)
    )
    let missingRoot = root.appending(path: "absent", directoryHint: .isDirectory)
    let missingState = AppState(
        paths: AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: missingRoot),
        captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults,
        engines: .production(paths: paths), makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal)
    )
    #expect(throws: SessionFolderRevealError.sessionsRootMissing) {
        try missingState.existingSessionsRoot()
    }
    #expect(try state.existingSessionsRoot() == root)

    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: UUID(), source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let unlisted = root.appending(path: "unlisted", directoryHint: .isDirectory)
    #expect(throws: SessionFolderRevealError.notInCatalog("unlisted")) {
        try state.existingSessionFolder(unlisted)
    }

    state.refreshSavedSessions()
    #expect(try state.existingSessionFolder(sessionURL) == sessionURL)

    try FileManager.default.removeItem(at: sessionURL)
    #expect(throws: SessionFolderRevealError.sessionFolderMissing(sessionURL.lastPathComponent)) {
        try state.existingSessionFolder(sessionURL)
    }
}
