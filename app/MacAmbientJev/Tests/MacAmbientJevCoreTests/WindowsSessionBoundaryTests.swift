#if os(Windows)
import Foundation
import Testing
@testable import MacAmbientJevCore

private func makeJunction(_ link: URL, to destination: URL) throws {
    let systemRoot = try #require(ProcessInfo.processInfo.environment["SystemRoot"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: systemRoot).appending(path: "System32/cmd.exe")
    func native(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
    process.arguments = ["/d", "/c", "mklink", "/J", native(link), native(destination)]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    _ = try output.fileHandleForReading.readToEnd()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

@Test func windowsJunctionsCannotRedirectSessionOperations() throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appending(path: "session")
    let outside = temporary.appending(path: "outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appending(path: "sentinel")
    let bytes = Data("outside".utf8)
    try bytes.write(to: sentinel)
    let junction = root.appending(path: "audio")
    try makeJunction(junction, to: outside)
    let redirected = junction.appending(path: "sentinel")
    #expect(throws: CocoaError.self) { _ = try SessionFileAccess.read(redirected, relativeTo: root) }
    #expect(throws: CocoaError.self) { try SessionFileAccess.writeAtomically(Data(), to: redirected, relativeTo: root) }
    #expect(throws: CocoaError.self) { _ = try SessionFileAccess.contentsOfDirectory(junction, relativeTo: root) }
    #expect(throws: CocoaError.self) { try SessionFileAccess.removeIfPresent(junction, relativeTo: root) }
    #expect(throws: CocoaError.self) { _ = try SessionFileAccess.read(redirected, relativeTo: junction) }
    #expect(try Data(contentsOf: sentinel) == bytes)
}

@Test func windowsDefaultPathsUseLocalStorageWithoutMacContainers() throws {
    let paths = try AppPaths.systemDefault(fileManager: .default)
    #expect(paths.applicationSupportURL.isFileURL)
    #expect(!paths.applicationSupportURL.path.isEmpty)
    #expect(paths.protectedSessionsRoots.count == 2)
    #expect(!paths.protectedSessionsRoots.contains { $0.path.contains("Containers/app.mac-ambient-jev") })
}
#endif
