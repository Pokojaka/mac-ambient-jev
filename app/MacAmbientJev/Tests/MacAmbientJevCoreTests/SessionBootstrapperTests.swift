import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func sessionBootstrapperCreatesManifestAndEventLog() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support"),
        cacheURL: root.appending(path: "cache"),
        sessionsRootOverride: nil
    )
    let sessionID = UUID()

    let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths,
        sessionID: sessionID,
        source: .imported(originalFilename: "lecture.m4a"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )

    #expect(
        FileManager.default.fileExists(
            atPath: sessionURL.appending(path: "session.json").path
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: sessionURL.appending(path: "events.jsonl").path
        )
    )

    let data = try Data(
        contentsOf: sessionURL.appending(path: "session.json")
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(SessionManifest.self, from: data)

    #expect(manifest.sessionID == sessionID)
    #expect(manifest.source == .imported(originalFilename: "lecture.m4a"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["capture_source"] == nil)
}
