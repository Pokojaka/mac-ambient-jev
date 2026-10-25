import Foundation
import Testing
import WinSDK
import ucrt
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevTestSupport
@testable import MacAmbientJevEngine

private struct ProcessTestError: Error, CustomStringConvertible {
    let description: String
}

/// The built engine executable as a child process, speaking NDJSON on its standard streams. `changes` signals after
/// every stdout or stderr chunk, when either stream ends and when the process exits.
private final class EngineChild: @unchecked Sendable {
    private let changes = ChangeSignal()
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var endedStreamCount = 0
    private var nextRequestID: UInt64 = 1
    private var processHandle: HANDLE?

    init(arguments: [String]) throws {
        process.executableURL = try Self.executableURL()
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // `Process.isRunning` only advances while a run loop runs, so the exit is read from the process handle.
        guard let handle = OpenProcess(DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(process.processIdentifier)) else {
            throw ProcessTestError(description: "OpenProcess failed (Win32 \(GetLastError()))")
        }
        processHandle = handle
        guard let exitHandle = OpenProcess(DWORD(SYNCHRONIZE), false, DWORD(process.processIdentifier)) else {
            throw ProcessTestError(description: "OpenProcess failed (Win32 \(GetLastError()))")
        }
        let exitHandleBits = Int(bitPattern: exitHandle)
        let changes = self.changes
        Thread.detachNewThread {
            let exitHandle = HANDLE(bitPattern: exitHandleBits)
            _ = WaitForSingleObject(exitHandle, INFINITE)
            CloseHandle(exitHandle)
            changes.signal()
        }
        Self.drain(stdout.fileHandleForReading, onChunk: { [self] in append(&stdoutData, $0) }, onEnd: { [self] in endStream() })
        Self.drain(stderr.fileHandleForReading, onChunk: { [self] in append(&stderrData, $0) }, onEnd: { [self] in endStream() })
    }

    private func endStream() {
        lock.lock()
        endedStreamCount += 1
        lock.unlock()
        changes.signal()
    }

    private var bothStreamsEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return endedStreamCount == 2
    }

    private func append(_ storage: inout Data, _ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
        changes.signal()
    }

    private static func drain(
        _ handle: FileHandle,
        onChunk: @escaping @Sendable (Data) -> Void,
        onEnd: @escaping @Sendable () -> Void
    ) {
        let source = FileHandleByteSource(handle: handle)
        Thread.detachNewThread {
            while let chunk = try? source.read(maxByteCount: 4096), !chunk.isEmpty { onChunk(chunk) }
            onEnd()
        }
    }

    /// `swift test` builds the executable beside the test bundle in the same debug directory.
    static func executableURL() throws -> URL {
        var directories = [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()]
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = package.appending(path: ".build", directoryHint: .isDirectory)
        if let triples = try? FileManager.default.contentsOfDirectory(atPath: build.path) {
            directories += triples.map { build.appending(path: "\($0)/debug", directoryHint: .isDirectory) }
        }
        for directory in directories {
            let candidate = directory.appending(path: "MacAmbientJevEngine.exe")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw ProcessTestError(description: "MacAmbientJevEngine.exe not found in \(directories.map(\.path))")
    }

    var stdoutText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    /// Complete stdout records decoded through the strict codec; throws when stdout holds anything else.
    var outputs: [EngineOutput] {
        get throws {
            lock.lock()
            let data = stdoutData
            lock.unlock()
            guard let end = data.lastIndex(of: 0x0A) else { return [] }
            return try data[...end].dropLast().split(separator: 0x0A, omittingEmptySubsequences: false).map {
                try EngineCodec.decodeOutput(Data($0))
            }
        }
    }

    func send(_ command: String, payload: String = "{}") throws -> UInt64 {
        let id = nextRequestID
        nextRequestID += 1
        try sendRaw("{\"version\":1,\"request_id\":\"\(id)\",\"command\":\"\(command)\",\"payload\":\(payload)}\n")
        return id
    }

    func sendRaw(_ text: String) throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func closeInput() throws {
        try stdin.fileHandleForWriting.close()
    }

    /// Sends a command and returns its terminal event.
    func call(_ command: String, payload: String = "{}") async throws -> EngineEvent {
        let id = try send(command, payload: payload)
        var terminal: EngineEvent?
        try await wait("terminal reply to \(command)") {
            terminal = ((try? self.outputs) ?? []).first {
                $0.requestID?.value == id && { if case .completed = $0.event { true } else if case .error = $0.event { true } else { false } }($0)
            }?.event
            return terminal != nil
        }
        return terminal!
    }

    func wait(_ what: String, _ condition: () -> Bool) async throws {
        do {
            try await changes.wait(what, until: condition)
        } catch let cancelled as WaitCancelled {
            throw ProcessTestError(description: "\(cancelled); stdout: \(stdoutText) stderr: \(stderrText)")
        }
    }

    /// The exit code once the process has ended and both of its output streams have been read to the end.
    func exitCode() async throws -> Int32 {
        var status: Int32?
        try await wait("the engine to exit and its output to end") {
            status = exitStatusIfExited()
            return status != nil && bothStreamsEnded
        }
        return status!
    }

    private func exitStatusIfExited() -> Int32? {
        guard let processHandle, WaitForSingleObject(processHandle, 0) == DWORD(WAIT_OBJECT_0) else { return nil }
        var code: DWORD = 0
        guard GetExitCodeProcess(processHandle, &code) else { return nil }
        return Int32(bitPattern: code)
    }

    func terminate() {
        if exitStatusIfExited() == nil { TerminateProcess(processHandle, 1) }
        if let processHandle { CloseHandle(processHandle) }
        processHandle = nil
    }
}

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "engine-process-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private let settingsPayload = """
{"expected_revision":null,"settings":{"schema_version":1,"source":"microphone","device":{"kind":"default"},\
"asr_size":"0.6b","execution_provider":"cpu","threads":1,"low_heat":false,"decisions_enabled":false,\
"automatic_export":false,"export_destination_path":null}}
"""

/// Serialized: a child inherits every inheritable handle of the test process, so two children started at once would
/// hold each other's pipe ends open and a closed stdin would never reach end of file.
@Suite(.serialized, .timeLimit(.minutes(10))) struct EngineProcessTests {
    @Test func launchOptionsAcceptOnlyAnAbsoluteLocalAppDataFolder() throws {
        #expect(try EngineLaunchOptions.parse([]).localAppData == nil)
        #expect(try EngineLaunchOptions.parse(["--local-app-data", "C:\\data"]).localAppData?.path == URL(fileURLWithPath: "C:\\data").path)
        #expect(throws: EngineLaunchError.self) { try EngineLaunchOptions.parse(["--local-app-data"]) }
        #expect(throws: EngineLaunchError.self) { try EngineLaunchOptions.parse(["--local-app-data", "relative"]) }
        #expect(throws: EngineLaunchError.self) { try EngineLaunchOptions.parse(["--local-app-data", "C:\\a", "--local-app-data", "C:\\b"]) }
        #expect(throws: EngineLaunchError.self) { try EngineLaunchOptions.parse(["--bogus"]) }
    }

    @Test func speaksOnlyNDJSONOnStdoutAndShutsDownCleanly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { child.terminate() }

        try await child.wait("the ready event") { ((try? child.outputs) ?? []).count >= 1 }
        guard case .ready = try child.outputs[0].event else {
            Issue.record("the first record is not ready")
            return
        }

        guard case .completed(.hello) = try await child.call("hello") else {
            Issue.record("hello did not complete")
            return
        }
        guard case let .error(noSettings) = try await child.call("settings.get") else {
            Issue.record("settings.get should fail before setup")
            return
        }
        #expect(noSettings.code == .settingsRequired)

        guard case .completed(.settingsReplace) = try await child.call("settings.replace", payload: settingsPayload) else {
            Issue.record("settings.replace did not complete")
            return
        }
        guard case let .completed(.stateGet(state)) = try await child.call("state.get") else {
            Issue.record("state.get did not complete")
            return
        }
        #expect(state.setup == .modelsRequired)

        // Recording needs prepared models; with none installed the refusal names the recovery.
        guard case let .error(recordingRefused) = try await child.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start should be refused")
            return
        }
        #expect(recordingRefused.code == .modelMissing)
        #expect(recordingRefused.recoveryAction == .prepareModels)

        guard case let .error(modelsMissing) = try await child.call("models.prepare") else {
            Issue.record("models.prepare should fail without installed models")
            return
        }
        #expect(modelsMissing.code == .modelMissing)
        #expect(modelsMissing.message.contains(root.appending(path: "mac-ambient-jev").path))

        guard case let .completed(.sessionList(list)) = try await child.call("session.list", payload: "{\"cursor\":null,\"limit\":10}") else {
            Issue.record("session.list did not complete")
            return
        }
        #expect(list.sessions.isEmpty)

        guard case .completed(.shutdown) = try await child.call("shutdown") else {
            Issue.record("shutdown did not complete")
            return
        }
        #expect(try await child.exitCode() == 0)

        // Every byte of stdout was a strictly valid, LF-terminated record.
        let text = child.stdoutText
        #expect(text.hasSuffix("\n"))
        #expect(try child.outputs.count == text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "mac-ambient-jev/settings.json").path))
    }

    @Test func endOfInputIsASafeDisconnectThatExitsZero() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { child.terminate() }
        try await child.wait("the ready event") { ((try? child.outputs) ?? []).count >= 1 }
        try child.closeInput()
        #expect(try await child.exitCode() == 0)
        #expect((try? child.outputs.count) != nil)
    }

    @Test func aProtocolViolationEndsTheProcessNonZero() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { child.terminate() }
        try await child.wait("the ready event") { ((try? child.outputs) ?? []).count >= 1 }
        try child.sendRaw("this is not json\n")
        #expect(try await child.exitCode() != 0)
        let outputs = try child.outputs
        guard case let .error(failure)? = outputs.last?.event else {
            Issue.record("the violation was not answered with an error")
            return
        }
        #expect(failure.severity == .fatal)
    }

    @Test func aSecondEngineForTheSameUserFailsOnTheLockAndTheFirstIsUnaffected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { first.terminate() }
        try await first.wait("the first engine's ready event") { ((try? first.outputs) ?? []).count >= 1 }

        let second = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { second.terminate() }
        #expect(try await second.exitCode() != 0)
        #expect(second.stdoutText.isEmpty)
        #expect(second.stderrText.contains("別のエンジンが同じアプリケーションフォルダーを使用中です"))

        guard case .completed(.hello) = try await first.call("hello") else {
            Issue.record("the first engine stopped answering")
            return
        }
        guard case .completed(.shutdown) = try await first.call("shutdown") else {
            Issue.record("shutdown did not complete")
            return
        }
        #expect(try await first.exitCode() == 0)

        // The lock died with the first process.
        let third = try EngineChild(arguments: ["--local-app-data", root.path])
        defer { third.terminate() }
        try await third.wait("the third engine's ready event") { ((try? third.outputs) ?? []).count >= 1 }
        try third.closeInput()
        #expect(try await third.exitCode() == 0)
    }

    @Test func startupFailureIsLoggedBeforeTheRootLockIsReleased() async {
        let result = await #expect(processExitsWith: .exitCode(2), observing: [\.standardErrorContent]) {
            _ = EngineLog.snapshot()
            let localAppData = FileManager.default.temporaryDirectory.appending(
                path: "engine-process-exit-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            let paths = AppPaths(
                applicationSupportURL: localAppData,
                cacheURL: localAppData.appending(path: "Caches", directoryHint: .isDirectory),
                sessionsRootOverride: nil
            )
            let exitCode = try await EngineProcess.withLockedRoot(paths: paths) {
                throw EngineLaunchError.startup("with_locked_root_startup_diagnostic_marker")
            }

            let reacquiredLock = try ApplicationRootLock.acquire(paths: paths)
            reacquiredLock.release()
            try FileManager.default.removeItem(at: localAppData)
            ucrt.exit(exitCode)
        }

        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(stderr.contains("with_locked_root_startup_diagnostic_marker"))
    }

    @Test func unknownArgumentsFailBeforeAnyOutput() async throws {
        let child = try EngineChild(arguments: ["--bogus"])
        defer { child.terminate() }
        #expect(try await child.exitCode() != 0)
        #expect(child.stdoutText.isEmpty)
        #expect(child.stderrText.contains("--bogus"))
    }
}
