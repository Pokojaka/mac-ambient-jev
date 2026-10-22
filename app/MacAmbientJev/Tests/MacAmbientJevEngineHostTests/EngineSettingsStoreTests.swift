import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

private struct SettingsFixture {
    let base: URL
    let paths: AppPaths
    let store: EngineSettingsStore

    init(logicalCPUCount: Int = 8) throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "EngineSettingsStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        paths = AppPaths(
            applicationSupportURL: base.appending(path: "support", directoryHint: .isDirectory),
            cacheURL: base.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: nil
        )
        store = EngineSettingsStore(paths: paths, logicalCPUCount: logicalCPUCount)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    func writeRaw(_ text: String) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    static func settings(threads: Int = 2, decisions: Bool = true) throws -> EngineSettings {
        try EngineSettings(
            schemaVersion: 1,
            source: .microphone,
            device: .default,
            asrSize: .small,
            executionProvider: .cpu,
            threads: threads,
            lowHeat: false,
            decisionsEnabled: decisions,
            automaticExport: false,
            exportDestinationPath: nil
        )
    }
}

struct EngineSettingsStoreTests {
    @Test func missingSettingsAreRequiredAndNothingIsCreated() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        #expect(throws: EngineSettingsError.required(path: fixture.store.fileURL.path)) {
            try fixture.store.load()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.path))
        #expect(EngineSettingsError.required(path: "x").errorCode == .settingsRequired)
        #expect(EngineSettingsError.required(path: "x").recoveryAction == .replaceSettings)
    }

    @Test func firstSetupCreatesRevisionOneAndLoadsBack() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let settings = try SettingsFixture.settings()
        let saved = try fixture.store.replace(expectedRevision: nil, settings: settings)
        #expect(saved.revision == (try EngineID(1)))
        #expect(try fixture.store.load() == saved)
        #expect(saved.settings == settings)
    }

    @Test func replacementAdvancesRevisionAndRejectsStaleExpectation() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings())
        let second = try fixture.store.replace(expectedRevision: first.revision, settings: SettingsFixture.settings(threads: 3))
        #expect(second.revision == (try EngineID(2)))

        let stale = EngineSettingsError.staleRevision(expected: first.revision, actual: second.revision)
        #expect(throws: stale) {
            try fixture.store.replace(expectedRevision: first.revision, settings: SettingsFixture.settings())
        }
        #expect(throws: EngineSettingsError.staleRevision(expected: nil, actual: second.revision)) {
            try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings())
        }
        #expect(stale.errorCode == .staleRevision)
        #expect(try fixture.store.load() == second)
    }

    @Test func firstSetupWithAnExpectedRevisionIsStale() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let expected = try EngineID(1)
        #expect(throws: EngineSettingsError.staleRevision(expected: expected, actual: nil)) {
            try fixture.store.replace(expectedRevision: expected, settings: SettingsFixture.settings())
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    @Test func threadsAboveTheMachineLimitAreRejectedWithoutWriting() throws {
        let fixture = try SettingsFixture(logicalCPUCount: 2)
        defer { fixture.cleanUp() }
        #expect(throws: (any Error).self) {
            try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings(threads: 3))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        do {
            try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings(threads: 3))
        } catch let error as EngineSettingsError {
            #expect(error.errorCode == .invalidSettings)
        }
    }

    @Test func corruptFilesAreReportedAndRepairedOnlyByFullReplacement() throws {
        let invalidFiles = [
            "not json",
            #"{"revision":"1"}"#,
            #"{"revision":"1","settings":{"schema_version":2,"source":"microphone","device":{"kind":"default"},"asr_size":"0.6b","execution_provider":"cpu","threads":2,"low_heat":false,"decisions_enabled":true,"automatic_export":false,"export_destination_path":null}}"#,
            #"{"revision":"1","settings":{"schema_version":1,"source":"microphone","device":{"kind":"default"},"asr_size":"0.6b","execution_provider":"cpu","threads":2,"low_heat":false,"decisions_enabled":true,"automatic_export":false,"export_destination_path":null,"extra":1}}"#,
            #"{"revision":"1","revision":"2","settings":{}}"#,
            #"{"revision":"1","settings":{"schema_version":1,"source":"microphone","device":{"kind":"default"},"asr_size":"0.6b","execution_provider":"cpu","threads":2,"low_heat":false,"decisions_enabled":true}}"#,
        ]
        for text in invalidFiles {
            let fixture = try SettingsFixture()
            defer { fixture.cleanUp() }
            try fixture.writeRaw(text)

            do {
                _ = try fixture.store.load()
                Issue.record("load accepted \(text)")
            } catch let error as EngineSettingsError {
                guard case .corrupt = error else { Issue.record("not corrupt: \(error)"); continue }
                #expect(error.errorCode == .invalidSettings)
                #expect(error.recoveryAction == .replaceSettings)
            }
            do {
                _ = try fixture.store.replace(expectedRevision: try EngineID(1), settings: SettingsFixture.settings())
                Issue.record("replace with a revision repaired \(text)")
            } catch let error as EngineSettingsError {
                guard case .corrupt = error else { Issue.record("not corrupt: \(error)"); continue }
            }
            #expect(try Data(contentsOf: fixture.store.fileURL) == Data(text.utf8))

            let repaired = try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings())
            #expect(repaired.revision == (try EngineID(1)))
            #expect(try fixture.store.load() == repaired)
        }
    }

    @Test func settingsAboveTheMachineLimitOnDiskAreCorrupt() throws {
        let wide = try SettingsFixture(logicalCPUCount: 8)
        defer { wide.cleanUp() }
        try wide.store.replace(expectedRevision: nil, settings: SettingsFixture.settings(threads: 4))
        let narrow = EngineSettingsStore(paths: wide.paths, logicalCPUCount: 2)
        do {
            _ = try narrow.load()
            Issue.record("accepted threads above the limit")
        } catch let error as EngineSettingsError {
            guard case .corrupt = error else { Issue.record("not corrupt: \(error)"); return }
        }
    }

    @Test func aSymlinkedSettingsFileIsAFilesystemError() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        try fixture.store.replace(expectedRevision: nil, settings: SettingsFixture.settings())
        let target = fixture.base.appending(path: "other.json")
        try FileManager.default.moveItem(at: fixture.store.fileURL, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.store.fileURL, withDestinationURL: target)
        do {
            _ = try fixture.store.load()
            Issue.record("followed a symlink")
        } catch let error as EngineSettingsError {
            guard case .filesystem = error else { Issue.record("not filesystem: \(error)"); return }
            #expect(error.errorCode == .filesystem)
        }
    }
}

struct ApplicationRootLockTests {
    @Test func aSecondHolderFailsClearlyUntilTheFirstReleases() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        let first = try ApplicationRootLock.acquire(paths: fixture.paths)
        #expect(throws: ApplicationRootLockError.alreadyRunning(path: first.lockURL.path)) {
            try ApplicationRootLock.acquire(paths: fixture.paths)
        }
        first.release()
        first.release()
        let second = try ApplicationRootLock.acquire(paths: fixture.paths)
        second.release()
    }

    @Test func droppingTheLockReleasesIt() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanUp() }
        do {
            let lock = try ApplicationRootLock.acquire(paths: fixture.paths)
            #expect(lock.lockURL.lastPathComponent == ApplicationRootLock.fileName)
        }
        try ApplicationRootLock.acquire(paths: fixture.paths).release()
    }
}
