import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

private typealias Key = PortableProcessingConfiguration

private struct Fixture {
    let root: URL
    let environment: [String: String]

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableProcessingConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let silero = root.appendingPathComponent("silero.onnx")
        try Data().write(to: silero)
        var environment = [
            Key.sileroModelKey: silero.path,
            Key.qwen3SizeKey: "0.6b",
        ]
        for (key, name) in [
            (Key.qwen3DirectoryKey, "qwen3"),
            (Key.diarizationDirectoryKey, "diarization"),
            (Key.clauseTaggerDirectoryKey, "tagger"),
        ] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            environment[key] = directory.path
        }
        return Fixture(root: root, environment: environment)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func resolve(
        _ edit: (inout [String: String]) -> Void = { _ in },
        threads: Int? = 2,
        cpus: Int = 8,
        decisions: Bool = false
    ) throws -> PortableProcessingConfiguration {
        var environment = environment
        edit(&environment)
        return try PortableProcessingConfiguration.resolve(
            environment: environment, threads: threads, logicalCPUCount: cpus, withDecisions: decisions
        )
    }

    func message(_ edit: (inout [String: String]) -> Void = { _ in }, threads: Int? = 2, cpus: Int = 8, decisions: Bool = false) throws -> String? {
        do {
            _ = try resolve(edit, threads: threads, cpus: cpus, decisions: decisions)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct PortableProcessingConfigurationTests {
    @Test
    func resolvesWithoutDecisionsAndIgnoresTheTaggerVariable() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let configuration = try fixture.resolve()
        #expect(configuration.sileroModelURL.path == fixture.environment[Key.sileroModelKey])
        #expect(configuration.qwen3ModelDirectory.path == fixture.environment[Key.qwen3DirectoryKey])
        #expect(configuration.qwen3Size == .small)
        #expect(configuration.diarizationModelDirectory.path == fixture.environment[Key.diarizationDirectoryKey])
        #expect(configuration.clauseTaggerModelDirectory == nil)
        #expect(configuration.threads == 2)
    }

    @Test
    func requiresTheTaggerVariableOnlyWithDecisions() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        #expect(try fixture.message({ $0[Key.clauseTaggerDirectoryKey] = nil }) == nil)
        let message = try fixture.message({ $0[Key.clauseTaggerDirectoryKey] = nil }, decisions: true)
        #expect(message?.contains(Key.clauseTaggerDirectoryKey) == true)
        let configuration = try fixture.resolve(decisions: true)
        #expect(configuration.clauseTaggerModelDirectory?.path == fixture.environment[Key.clauseTaggerDirectoryKey])
    }

    @Test(arguments: [
        Key.sileroModelKey, Key.qwen3DirectoryKey, Key.qwen3SizeKey,
        Key.diarizationDirectoryKey, Key.clauseTaggerDirectoryKey,
    ])
    func rejectsMissingEmptyRelativeAndNonexistentValues(key: String) throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let missing = try fixture.message({ $0[key] = nil }, decisions: true)
        #expect(missing?.contains(key) == true)
        let empty = try fixture.message({ $0[key] = "" }, decisions: true)
        #expect(empty?.contains(key) == true)
        if key != Key.qwen3SizeKey {
            let relative = try fixture.message({ $0[key] = "relative/path" }, decisions: true)
            #expect(relative?.contains(key) == true)
            let absent = fixture.root.appendingPathComponent("absent").path
            let nonexistent = try fixture.message({ $0[key] = absent }, decisions: true)
            #expect(nonexistent?.contains(key) == true)
        }
    }

    @Test
    func rejectsTheWrongKindOfPath() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let directory = fixture.environment[Key.qwen3DirectoryKey]!
        let silero = fixture.environment[Key.sileroModelKey]!
        #expect(try fixture.message({ $0[Key.sileroModelKey] = directory })?.contains(Key.sileroModelKey) == true)
        #expect(try fixture.message({ $0[Key.qwen3DirectoryKey] = silero })?.contains(Key.qwen3DirectoryKey) == true)
    }

    @Test(arguments: ["0.6B", "1.7", "large", " 0.6b"])
    func rejectsInvalidQwen3Size(value: String) throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        #expect(try fixture.message({ $0[Key.qwen3SizeKey] = value })?.contains(Key.qwen3SizeKey) == true)
    }

    @Test
    func acceptsBothQwen3Sizes() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        #expect(try fixture.resolve({ $0[Key.qwen3SizeKey] = "1.7b" }).qwen3Size == .large)
    }

    @Test
    func validatesThreadsAgainstTheCapAndTheCPUCount() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        #expect(try fixture.resolve(threads: 1).threads == 1)
        #expect(try fixture.resolve(threads: 4, cpus: 16).threads == 4)
        #expect(try fixture.resolve(threads: 2, cpus: 2).threads == 2)
        for (threads, cpus) in [(nil, 8), (0, 8), (-1, 8), (5, 16), (3, 2)] as [(Int?, Int)] {
            let message = try fixture.message(threads: threads, cpus: cpus)
            #expect(message?.contains("--threads") == true)
        }
    }

    @Test
    func bundleRejectsACorruptSileroFileBeforeLoadingAnyModel() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanUp() }
        let configuration = try fixture.resolve()
        #expect(throws: (any Error).self) {
            try PortableSessionEngineBundle(configuration: configuration, usageCounter: DecisionUsageCounter())
        }
    }
}
