import Foundation
import Testing
@testable import MacAmbientJevCore

@Suite struct SessionStorageCutoverTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let id = UUID(uuidString: "0123ABCD-0000-0000-0000-000000000001")!

    private func make(_ source: SessionSource) throws -> String {
        try SessionFolderName.make(createdAt: date, sessionID: id, source: source, timeZone: utc)
    }

    @Test func localTimeAndRecordingSources() throws {
        for source in [CaptureSource.microphone, .systemAudio] {
            #expect(try make(.recording(source)) == "2023-11-14_22-13-20_録音_0123abcd")
            #expect(try SessionFolderName.make(
                createdAt: date, sessionID: id, source: .recording(source),
                timeZone: TimeZone(identifier: "Asia/Tokyo")!
            ) == "2023-11-15_07-13-20_録音_0123abcd")
        }
    }

    @Test(arguments: [
        ("lecture.part.one.m4a", "lecture.part.one"),
        ("under_score.wav", "under_score"),
        (".hidden/meeting:one.wav", "-hidden-meeting-one"),
        (".\u{301}hidden.wav", "-\u{301}hidden"),
        (".hidden", "-hidden"),
        ("no-extension", "no-extension"),
        ("e\u{301}.wav", "e\u{301}"),
    ]) func importedStems(input: String, expected: String) throws {
        let source = SessionSource.imported(originalFilename: input)
        let name = try make(source)
        let parsed = try SessionFolderName.parse(name)
        #expect(Array(parsed.stem.utf8) == Array(expected.utf8))
        let manifest = SessionManifest(sessionID: id, createdAt: date.addingTimeInterval(86400), source: source)
        try SessionFolderName.validate(name, manifest: manifest)
        guard case .imported(let original) = manifest.source else { Issue.record("expected import"); return }
        #expect(Array(original.utf8) == Array(input.utf8))
    }

    @Test func truncatesAtCharacterBoundaries() throws {
        let exact = String(repeating: "x", count: 226)
        let name = try make(.imported(originalFilename: exact + ".wav"))
        #expect(name.utf8.count == 255)
        #expect(try SessionFolderName.parse(name).stem == exact)
        #expect(try SessionFolderName.parse(make(.imported(originalFilename: exact + "extra.wav"))).stem == exact)
        let composed = String(repeating: "e\u{301}", count: 76)
        let truncated = try SessionFolderName.parse(make(.imported(originalFilename: composed + ".wav"))).stem
        #expect(Array(truncated.utf8) == Array(String(repeating: "e\u{301}", count: 75).utf8))
        let family = "👨‍👩‍👧‍👦"
        let emoji = try SessionFolderName.parse(make(.imported(originalFilename: String(repeating: family, count: 10) + ".wav"))).stem
        #expect(emoji == String(repeating: family, count: 9))
        #expect(emoji.utf8.count == 225)
    }

    @Test(arguments: ["", "bad\0.wav", "a" + String(repeating: "\u{301}", count: 120) + ".wav"])
    func invalidSourcesThrow(filename: String) {
        #expect(throws: SessionFolderNameError.self) { _ = try make(.imported(originalFilename: filename)) }
    }

    @Test func unrepresentableDatesThrow() {
        for date in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -62_167_219_200), Date(timeIntervalSince1970: 253_402_300_800)] {
            #expect(throws: SessionFolderNameError.invalidCreationDate) {
                _ = try SessionFolderName.make(createdAt: date, sessionID: id, source: .recording(.microphone), timeZone: utc)
            }
        }
    }

    @Test func parsingUsesStrictGregorianComponents() throws {
        let name = "2024-03-10_02-30-00_stem_with_underscores_0123abcd"
        let parsed = try SessionFolderName.parse(name)
        #expect(parsed.datetimePrefix == "2024-03-10_02-30-00")
        #expect(parsed.stem == "stem_with_underscores")
        #expect(parsed.sessionIDPrefix == "0123abcd")
        #expect(try SessionFolderName.parse("2024-02-29_23-59-59_stem_0123abcd").stem == "stem")
    }

    @Test(arguments: [
        "2023-02-29_00-00-00_x_0123abcd", "2024-02-30_00-00-00_x_0123abcd",
        "2024-13-01_00-00-00_x_0123abcd", "2024-01-00_00-00-00_x_0123abcd",
        "2024-01-01_24-00-00_x_0123abcd", "2024-01-01_00-60-00_x_0123abcd",
        "2024-01-01_00-00-60_x_0123abcd", "0000-01-01_00-00-00_x_0123abcd",
        "2024-01-01_00-00-00_x_0123ABCD", "2024-01-01_00-00-00_x_0123abcg",
        "2024-01-01_00-00-00_x_0123abc", "2024-01-01_00-00-00__0123abcd",
        "2024-01-01_00-00-00_.x_0123abcd", "2024-01-01_00-00-00_x/y_0123abcd",
        "2024-01-01_00-00-00_x:y_0123abcd", "2024-01-01_00-00-00_x\0_0123abcd",
        "2024-01-01_00-00-00_.\u{301}x_0123abcd",
        "2024-01-01_00-00-00_" + String(repeating: "x", count: 227) + "_0123abcd",
        "0123ABCD-0000-0000-0000-000000000001",
    ]) func invalidNamesThrow(name: String) {
        #expect(throws: SessionFolderNameError.invalidName(name)) { _ = try SessionFolderName.parse(name) }
    }

    @Test func validationChecksIdentityAndSourceNotCreationTimestamp() throws {
        let name = try make(.recording(.microphone))
        try SessionFolderName.validate(name, manifest: SessionManifest(
            sessionID: id, createdAt: date.addingTimeInterval(-1000), source: .recording(.systemAudio)
        ))
        let otherID = UUID(uuidString: "1123ABCD-0000-0000-0000-000000000001")!
        #expect(throws: SessionFolderNameError.sessionIDPrefixMismatch(folderName: name, sessionID: otherID)) {
            try SessionFolderName.validate(name, manifest: SessionManifest(sessionID: otherID, createdAt: date, source: .recording(.microphone)))
        }
        #expect(throws: SessionFolderNameError.sourceStemMismatch(folderName: name)) {
            try SessionFolderName.validate(name, manifest: SessionManifest(sessionID: id, createdAt: date, source: .imported(originalFilename: "other.wav")))
        }
    }

    private func create(root: URL, id: UUID, date: Date, source: SessionSource) throws -> URL {
        let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
        return try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: id, source: source, createdAt: date, timeZone: utc
        )
    }

    @Test func locatorCountsFullIdentitiesBeforeValidating() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locator = SessionDirectoryLocator(fileManager: .default)
        #expect(throws: SessionDirectoryLookupError.notFound(id)) { _ = try locator.resolve(sessionsRoot: root, sessionID: id) }
        let valid = try create(root: root, id: id, date: date, source: .recording(.microphone))
        let collision = UUID(uuidString: "0123ABCD-0000-0000-0000-000000000002")!
        let peer = try create(root: root, id: collision, date: date.addingTimeInterval(1), source: .recording(.systemAudio))
        let broken = root.appending(path: ".broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: broken.appending(path: "session.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "missing"), withIntermediateDirectories: true)
        #expect(try locator.resolve(sessionsRoot: root, sessionID: id) == valid)
        #expect(try locator.resolve(sessionsRoot: root, sessionID: collision) == peer)
        let duplicate = root.appending(path: "malformed", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: valid, to: duplicate)
        #expect(throws: SessionDirectoryLookupError.multipleMatches(sessionID: id, folders: [valid, duplicate])) {
            _ = try locator.resolve(sessionsRoot: root, sessionID: id)
        }
        try FileManager.default.removeItem(at: valid)
        #expect(throws: SessionFolderNameError.invalidName(duplicate.lastPathComponent)) {
            _ = try locator.resolve(sessionsRoot: root, sessionID: id)
        }
        let absent = UUID()
        #expect(throws: SessionDirectoryLookupError.notFound(absent)) {
            _ = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: absent)
        }
    }

    @Test func enumerationErrorsPropagate() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: CocoaError.self) { _ = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: root, sessionID: id) }
        #expect(throws: CocoaError.self) { _ = try SavedSessionCatalog(fileManager: .default).list(sessionsRoot: root) }
        #expect(throws: CocoaError.self) { _ = try SessionRecoveryScanner(sessionsRoot: root).pendingSessions() }
    }

    @Test func catalogAndRecoveryIsolateInvalidFoldersAndDuplicateIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try create(root: root, id: id, date: date, source: .recording(.microphone))
        let writer = try DurableAudioWriter(directory: SessionLayout(sessionURL: valid).processingDirectory,
            sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1)
        try await writer.append(samples: [0.25, 0.5])
        _ = try await writer.finish()
        var invalidURLs: [URL] = []
        for name in [".missing", "broken"] {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if name == "broken" { try Data("broken".utf8).write(to: url.appending(path: "session.json")) }
            invalidURLs.append(url)
        }
        for kind in ["suffix", "stem", "malformed", "uuid"] {
            let invalidID = UUID()
            let healthy = try create(root: root, id: invalidID, date: date, source: .recording(.microphone))
            let name: String
            switch kind {
            case "suffix": name = "2023-11-14_22-13-20_録音_00000000"
            case "stem": name = "2023-11-14_22-13-20_wrong_" + invalidID.uuidString.prefix(8).lowercased()
            case "uuid": name = invalidID.uuidString
            default: name = "malformed"
            }
            let invalid = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: healthy, to: invalid)
            invalidURLs.append(invalid)
        }
        try Data([1]).write(to: root.appending(path: "not-a-session"))
        let catalog = SavedSessionCatalog(fileManager: .default)
        let scanner = SessionRecoveryScanner(sessionsRoot: root)
        let rows = try catalog.list(sessionsRoot: root)
        #expect(rows.first?.sessionURL == valid)
        #expect(rows.first?.canReprocess == true)
        #expect(rows.dropFirst().map(\.sessionURL) == invalidURLs.sorted { $0.lastPathComponent < $1.lastPathComponent })
        for row in rows.dropFirst() {
            #expect(!row.canReprocess)
            #expect(row.id == row.sessionURL)
            guard case .unreadable = row else { Issue.record("invalid folder was readable"); continue }
            if [".missing", "broken"].contains(row.sessionURL.lastPathComponent) { #expect(row.sessionID == nil) }
            else { #expect(row.sessionID != nil) }
        }
        let scan = try scanner.pendingSessions()
        #expect(scan.candidates.map(\.sessionURL) == [valid])
        #expect(scan.failures.map(\.sessionURL) == invalidURLs.sorted { $0.lastPathComponent < $1.lastPathComponent })
        let duplicate = root.appending(path: try SessionFolderName.make(
            createdAt: date.addingTimeInterval(1), sessionID: id, source: .recording(.microphone), timeZone: utc),
            directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: valid, to: duplicate)
        let duplicateRows = try catalog.list(sessionsRoot: root).filter { $0.sessionID == id }
        #expect(Set(duplicateRows.map(\.id)) == Set([valid, duplicate]))
        #expect(duplicateRows.allSatisfy { !$0.canReprocess })
        for row in duplicateRows { guard case .unreadable = row else { Issue.record("duplicate remained readable"); continue } }
        let duplicateScan = try scanner.pendingSessions()
        #expect(duplicateScan.candidates.isEmpty)
        #expect(Set(duplicateScan.failures.map(\.sessionURL)) == Set(invalidURLs + [valid, duplicate]))
    }

    @Test func creationCollisionDoesNotOverwriteManifest() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try create(root: root, id: id, date: date, source: .recording(.microphone))
        let original = try Data(contentsOf: first.appending(path: "session.json"))
        let collision = UUID(uuidString: "0123ABCD-0000-0000-0000-000000000002")!
        #expect(throws: CocoaError.self) { _ = try create(root: root, id: collision, date: date, source: .recording(.microphone)) }
        #expect(try Data(contentsOf: first.appending(path: "session.json")) == original)
    }
}
