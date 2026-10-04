import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func sessionDirectoryLivesUnderApplicationSupport() {
    let support = URL(fileURLWithPath: "/tmp/support")
    let cache = URL(fileURLWithPath: "/tmp/cache")
    let paths = AppPaths(applicationSupportURL: support, cacheURL: cache, sessionsRootOverride: nil)

    #expect(paths.sessionsRoot.path == "/tmp/support/mac-ambient-jev/sessions")
    #expect(paths.modelsRoot.path == "/tmp/support/mac-ambient-jev/models")
}

@Test
func sessionsRootPolicyRejectsProtectedOverlapsAndSymlinkAliases() throws {
    let fileManager = FileManager.default
    let home = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let protected = home.appending(path: "Library/Application Support/mac-ambient-jev")
    let cache = home.appending(path: "Library/Caches/mac-ambient-jev")
    let container = home.appending(path: "Library/Containers/app.mac-ambient-jev/Data/Library")
    let sandbox = container.appending(path: "Application Support/mac-ambient-jev")
    let sandboxCache = container.appending(path: "Caches/mac-ambient-jev")
    let alias = home.appending(path: "alias", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: protected, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: sandboxCache, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(at: alias, withDestinationURL: protected)
    defer { try? fileManager.removeItem(at: home) }
    let protectedRoots = [protected, cache, sandbox, sandboxCache]
    let regularFile = home.appending(path: "not-a-directory")
    try Data().write(to: regularFile)
    for unsafe in [protected, protected.appending(path: "child"),
                   protected.deletingLastPathComponent(), cache, sandbox,
                   URL(fileURLWithPath: protected.path.uppercased()),
                   alias.appending(path: "not-created/yet"), regularFile] {
        #expect(throws: SessionsRootPolicy.Error.unsafeRoot) {
            try SessionsRootPolicy.validated(unsafe, protectedRoots: protectedRoots, fileManager: fileManager)
        }
    }
    let safe = home.appending(path: "scratch/sessions", directoryHint: .isDirectory)
    #expect(try SessionsRootPolicy.validated(safe, protectedRoots: protectedRoots, fileManager: fileManager).path == safe.path)
}
