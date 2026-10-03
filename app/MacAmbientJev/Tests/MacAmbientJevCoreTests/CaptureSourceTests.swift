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
        paths: paths, sessionID: id, source: .recording(.systemAudio)
    )
    let data = try Data(contentsOf: sessionURL.appending(path: "session.json"))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(SessionManifest.self, from: data)
    #expect(manifest.source == .recording(.systemAudio))
    guard case .readable(let session) = try SavedSessionCatalog().list(sessionsRoot: paths.sessionsRoot).first else {
        Issue.record("expected a readable session")
        return
    }
    #expect(session.source == .recording(.systemAudio))
}

@Test(arguments: [
    #""source_kind":"recording""#,
    #""source_kind":"recording","original_filename":"a.wav""#,
    #""source_kind":"imported""#,
    #""source_kind":"imported","original_filename":"""#,
    #""source_kind":"imported","capture_source":"microphone""#,
])
func sessionManifestRequiresTheFieldsOfItsSourceKind(_ sourceFields: String) {
    let json = """
    {"session_id":"\(UUID().uuidString)","created_at":"2026-09-28T00:00:00Z",\(sourceFields)}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(throws: DecodingError.self) {
        try decoder.decode(SessionManifest.self, from: Data(json.utf8))
    }
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
