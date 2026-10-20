import Foundation
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevRuntime

@MainActor
@Test func unreadableFoldersRemainIndividuallySelectableAndIDsAreAmbiguous() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let firstBroken = root.appending(path: ".missing", directoryHint: .isDirectory)
    let secondBroken = root.appending(path: "broken", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstBroken, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondBroken, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: secondBroken.appending(path: "session.json"))
    let (defaults, suiteName) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(
        paths: paths, captureEngine: FakeAppCaptureEngine(), microphoneAccess: { false },
        pausesProcessing: true, userDefaults: defaults, engines: .production(paths: paths),
        makeLiveVADSession: idleLiveVADFactory(),
        thermalMonitor: TestThermalMonitor(.nominal)
    )
    state.refreshSavedSessions()
    state.selectSavedSession(sessionURL: firstBroken)
    #expect(state.selectedSavedSessionURL == firstBroken)
    #expect(state.displayedSessionID == nil)
    state.selectSavedSession(sessionURL: secondBroken)
    #expect(state.selectedSavedSessionURL == secondBroken)
    #expect(state.displayedSessionID == nil)
    let id = UUID()
    let first = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    state.refreshSavedSessions()
    state.selectSavedSession(sessionID: id)
    #expect(state.selectedSavedSessionURL == first)
    #expect(state.displayedSessionID == id)
    #expect(state.readableSavedSession(id)?.sessionURL == first)
    let second = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_001), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    state.refreshSavedSessions()
    state.selectSavedSession(sessionURL: secondBroken)
    state.selectSavedSession(sessionID: id)
    #expect(state.selectedSavedSessionURL == secondBroken)
    #expect(state.readableSavedSession(id) == nil)
    state.reprocess(sessionID: id)
    #expect(state.processingQueue.pending.isEmpty)
    state.selectSavedSession(sessionURL: second)
    #expect(state.selectedSavedSessionURL == second)
    #expect(state.displayedSessionID == id)
    let sessionID = UUID()
    state.recording.start(sessionID: sessionID)
    state.markRecordingStarted(sessionID: sessionID)
    state.selectSavedSession(sessionURL: firstBroken)
    #expect(state.selectedSavedSessionURL == second)
}
