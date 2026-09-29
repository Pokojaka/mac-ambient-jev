import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func systemAudioSessionPersistsSourceAndCatalogDisplaysIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = AppPaths(
        applicationSupportURL: directory,
        cacheURL: directory.appending(path: "cache"),
        sessionsRootOverride: directory.appending(path: "chosen-sessions")
    )
    let id = UUID()
    let sessionURL = try SessionBootstrapper().createSession(
        paths: paths, sessionID: id, sourceKind: .live, captureSource: .systemAudio
    )
    let data = try Data(contentsOf: sessionURL.appending(path: "session.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(SessionManifest.self, from: data)
    #expect(manifest.captureSource == .systemAudio)
    #expect(try SavedSessionCatalog().list(sessionsRoot: paths.sessionsRoot).first?.captureSource == .systemAudio)
}

@Test
func legacySessionWithoutCaptureSourceDefaultsToMicrophone() throws {
    let id = UUID()
    let json = """
    {"session_id":"\(id.uuidString)","created_at":"2026-09-28T00:00:00Z","source_kind":"live"}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(SessionManifest.self, from: Data(json.utf8))
    #expect(manifest.captureSource == .microphone)
}

@Test
func appBundleRecipeEmitsJapaneseSystemAudioPermission() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let recipe = repository.appending(path: "scripts/build_app.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [recipe.path, "--print-info-plist"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let description = try #require(plist["NSAudioCaptureUsageDescription"] as? String)
    #expect(description.contains("システム音声"))
    #expect(description.contains("文字起こし"))
}
