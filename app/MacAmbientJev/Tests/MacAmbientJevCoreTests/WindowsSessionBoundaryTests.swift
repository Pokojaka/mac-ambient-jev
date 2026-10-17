#if os(Windows)
import Foundation
import Testing
@testable import MacAmbientJevCore

private func systemTool(_ name: String, arguments: [String]) throws -> String {
    let systemRoot = try #require(ProcessInfo.processInfo.environment["SystemRoot"])
    let process = Process()
    process.executableURL = URL(fileURLWithPath: systemRoot).appending(path: "System32/\(name).exe")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    try #require(process.terminationStatus == 0, "\(name): \(text)")
    return text
}

private func setDirectoryWriteDenial(_ directory: URL, deny: Bool) throws {
    // The process token's SID avoids machine/domain account-name resolution.
    let identity = try systemTool("whoami", arguments: ["/user", "/fo", "csv", "/nh"])
    let field = try #require(identity.split(separator: ",").last)
    let sid = field.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    try #require(sid.hasPrefix("S-1-"))
    let account = "*" + sid
    let path = directory.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    _ = try systemTool("icacls", arguments: [path, deny ? "/deny" : "/remove:d",
                                           deny ? "\(account):(WD,AD,WEA,WA)" : account])
}

@Test func windowsReadOnlyBoundaryAllowsReadsAndRejectsWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionWriter(sessionURL: root)
    try await writer.append(EventDraft(eventType: "test", sessionID: UUID(), payload: "read-only"))
    let events = root.appending(path: "events.jsonl")
    let bytes = try SessionFileAccess.read(events, relativeTo: root)
    try setDirectoryWriteDenial(root, deny: true)
    defer {
        do { try setDirectoryWriteDenial(root, deny: false) }
        catch { Issue.record(error) }
    }
    #expect(try SessionFileAccess.read(events, relativeTo: root) == bytes)
    #expect(try SessionWriter.readDurableLog(eventsURL: events) == bytes)
    #expect(try SessionFileAccess.fileSize(events, relativeTo: root) == bytes.count)
    #expect(try SessionFileAccess.contentsOfDirectory(root, relativeTo: root).map(\.lastPathComponent).contains("events.jsonl"))
    #expect(throws: CocoaError.self) { try SessionFileAccess.writeAtomically(Data(), to: events, relativeTo: root) }
    #expect(try SessionFileAccess.read(events, relativeTo: root) == bytes)
}

@Test func windowsLongUnicodeBoundaryRoundTrips() throws {
    let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let root = temporary.appending(path: String(repeating: "x", count: 230) + "講義")
    try SessionFileAccess.createDirectory(root, relativeTo: root)
    let file = root.appending(path: "文字起こし.json")
    let bytes = Data("長いパスの日本語".utf8)
    try SessionFileAccess.writeAtomically(bytes, to: file, relativeTo: root)
    #expect(try SessionFileAccess.read(file, relativeTo: root) == bytes)
}

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
