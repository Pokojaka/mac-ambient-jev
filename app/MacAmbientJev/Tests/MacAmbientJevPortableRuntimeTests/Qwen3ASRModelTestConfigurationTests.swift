import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRModelTestConfigurationTests {
    @Test
    func requiresModelDirectoryEnvironmentVariable() {
        let message = configurationErrorDescription(environment: [
            Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "0.6b"
        ])
        #expect(message?.contains(Qwen3ASRModelTestConfiguration.directoryEnvironmentKey) == true)
    }

    @Test
    func requiresModelSizeEnvironmentVariable() throws {
        try withTemporaryDirectory { directory in
            let message = configurationErrorDescription(environment: [
                Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: directory.path
            ])
            #expect(message?.contains(Qwen3ASRModelTestConfiguration.sizeEnvironmentKey) == true)
        }
    }

    @Test
    func rejectsEmptyModelDirectory() {
        let message = configurationErrorDescription(environment: [
            Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: "",
            Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "0.6b"
        ])
        #expect(message?.contains(Qwen3ASRModelTestConfiguration.directoryEnvironmentKey) == true)
    }

    @Test
    func rejectsInvalidModelSize() throws {
        try withTemporaryDirectory { directory in
            let message = configurationErrorDescription(environment: [
                Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: directory.path,
                Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "0.6B"
            ])
            #expect(message?.contains(Qwen3ASRModelTestConfiguration.sizeEnvironmentKey) == true)
        }
    }

    @Test
    func rejectsRelativeModelDirectory() {
        let message = configurationErrorDescription(environment: [
            Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: "relative/model-directory",
            Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "0.6b"
        ])
        #expect(message?.contains(Qwen3ASRModelTestConfiguration.directoryEnvironmentKey) == true)
    }

    @Test
    func rejectsNonexistentModelDirectory() throws {
        try withTemporaryDirectory { parent in
            let missingDirectory = parent.appendingPathComponent("does-not-exist", isDirectory: true)
            let message = configurationErrorDescription(environment: [
                Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: missingDirectory.path,
                Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "0.6b"
            ])
            #expect(message?.contains(Qwen3ASRModelTestConfiguration.directoryEnvironmentKey) == true)
        }
    }

    @Test
    func rejectsFileAsModelDirectory() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("not-a-directory")
            try Data("model file".utf8).write(to: file)
            let message = configurationErrorDescription(environment: [
                Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: file.path,
                Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: "1.7b"
            ])
            #expect(message?.contains(Qwen3ASRModelTestConfiguration.directoryEnvironmentKey) == true)
        }
    }

    @Test
    func acceptsBothExactModelSizesForAnExistingDirectory() throws {
        try withTemporaryDirectory { directory in
            for size in Qwen3ASRModelSize.allCases {
                let configuration = try Qwen3ASRModelTestConfiguration(environment: [
                    Qwen3ASRModelTestConfiguration.directoryEnvironmentKey: directory.path,
                    Qwen3ASRModelTestConfiguration.sizeEnvironmentKey: size.rawValue
                ])
                #expect(configuration.directory == directory)
                #expect(configuration.size == size)
            }
        }
    }
}

private func configurationErrorDescription(environment: [String: String]) -> String? {
    do {
        _ = try Qwen3ASRModelTestConfiguration(environment: environment)
        return nil
    } catch {
        return error.localizedDescription
    }
}

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let name = "Qwen3ASRModelTestConfigurationTests-\(UUID().uuidString)"
    let directory = fileManager.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    let verifiedCleanupTarget = directory.standardizedFileURL.resolvingSymlinksInPath()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)

    defer {
        let resolvedCleanupTarget = directory.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedCleanupTarget == verifiedCleanupTarget,
           resolvedCleanupTarget.deletingLastPathComponent() == temporaryRoot,
           resolvedCleanupTarget.lastPathComponent == name
        {
            try? fileManager.removeItem(at: resolvedCleanupTarget)
        }
    }

    return try body(directory)
}
