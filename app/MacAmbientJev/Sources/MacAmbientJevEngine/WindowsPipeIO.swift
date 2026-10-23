import Foundation
import WinSDK
import MacAmbientJevEngineHost

enum WindowsPipeError: Error, LocalizedError {
    case standardHandleUnavailable(String)
    case duplicateFailed(DWORD)
    case stdoutCRTDescriptorRedirectFailed(Int32)
    case stdoutStandardHandleRedirectFailed(DWORD)

    var errorDescription: String? {
        switch self {
        case let .standardHandleUnavailable(name): "標準ハンドルを取得できません: \(name)"
        case let .duplicateFailed(code): "標準出力ハンドルを複製できません (Win32 \(code))"
        case let .stdoutCRTDescriptorRedirectFailed(code): "CRT 標準出力を stderr にリダイレクトできません (errno \(code))"
        case let .stdoutStandardHandleRedirectFailed(code): "標準出力ハンドルを stderr にリダイレクトできません (Win32 \(code))"
        }
    }
}

/// The engine's stdout: `WriteFile` on the inherited pipe handle, one bounded chunk per call, so a reader that stops
/// draining is noticed by the transport's no-progress deadline. `cancelBlockedWrite()` interrupts a write blocked on
/// a full pipe with `CancelSynchronousIo` on the writer thread, so a stuck reader cannot prevent shutdown.
final class WindowsPipeByteSink: EngineByteSink, @unchecked Sendable {
    /// Bytes per `WriteFile`. A blocking write returns only when all of its bytes are buffered or read, so a small
    /// chunk keeps every block short enough for progress to be observable.
    static let chunkBytes = 4096
    private static let cancelRetryInterval: TimeInterval = 0.005
    private static let cancelAttempts = 400

    private let handle: HANDLE
    private let condition = NSCondition()
    private var writerThread: HANDLE?
    private var writing = false
    private var cancelled = false
    private var closed = false
    private var handleClosed = false

    init(handle: HANDLE) {
        self.handle = handle
    }

    deinit {
        if let writerThread { CloseHandle(writerThread) }
    }

    /// Takes over the process's stdout: returns a private duplicate for the transport and points every other stdout
    /// user, the standard handle and the C runtime's fd 1, at stderr. Nothing but NDJSON records reaches the pipe.
    static func claimStandardOutput() throws -> HANDLE {
        guard let original = GetStdHandle(DWORD(bitPattern: -11)), original != INVALID_HANDLE_VALUE else {
            throw WindowsPipeError.standardHandleUnavailable("stdout")
        }
        var duplicate: HANDLE?
        guard DuplicateHandle(
            GetCurrentProcess(), original, GetCurrentProcess(), &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)
        ), let duplicate else {
            throw WindowsPipeError.duplicateFailed(GetLastError())
        }
        var transferred = false
        defer {
            if !transferred { CloseHandle(duplicate) }
        }
        guard let standardError = GetStdHandle(DWORD(bitPattern: -12)), standardError != INVALID_HANDLE_VALUE else {
            throw WindowsPipeError.standardHandleUnavailable("stderr")
        }
        guard _dup2(2, 1) == 0 else {
            let code = errno
            throw WindowsPipeError.stdoutCRTDescriptorRedirectFailed(Int32(code))
        }
        // _dup2 can update the OS standard handle as well, so set it after the CRT descriptor redirection.
        guard SetStdHandle(DWORD(bitPattern: -11), standardError) else {
            let code = GetLastError()
            throw WindowsPipeError.stdoutStandardHandleRedirectFailed(code)
        }
        transferred = true
        return duplicate
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        precondition(bytes.count > 0, "empty write")
        condition.lock()
        if cancelled || closed {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        if writerThread == nil {
            var duplicate: HANDLE?
            let process = GetCurrentProcess()
            guard DuplicateHandle(process, GetCurrentThread(), process, &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)),
                  let duplicate else {
                let code = GetLastError()
                condition.unlock()
                throw EngineSinkError.failed("DuplicateHandle(thread) failed (Win32 \(code))")
            }
            writerThread = duplicate
        }
        writing = true
        condition.unlock()
        defer {
            condition.lock()
            writing = false
            condition.broadcast()
            condition.unlock()
        }

        var written: DWORD = 0
        let count = DWORD(min(bytes.count, Self.chunkBytes))
        if WriteFile(handle, bytes.baseAddress, count, &written, nil) {
            return Int(written)
        }
        let code = GetLastError()
        switch code {
        case DWORD(ERROR_OPERATION_ABORTED):
            throw EngineSinkError.cancelled
        case DWORD(ERROR_BROKEN_PIPE), DWORD(ERROR_NO_DATA), DWORD(ERROR_PIPE_NOT_CONNECTED):
            throw EngineSinkError.brokenPipe
        default:
            throw EngineSinkError.failed("WriteFile failed (Win32 \(code))")
        }
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        // The write may not have entered WriteFile yet, so cancel until it has left.
        var attempts = 0
        while writing, let thread = writerThread, attempts < Self.cancelAttempts {
            _ = CancelSynchronousIo(thread)
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.cancelRetryInterval))
            attempts += 1
        }
        condition.unlock()
    }

    func close() {
        cancelBlockedWrite()
        condition.lock()
        closed = true
        // A write that could not be cancelled still owns the handle; the process is exiting.
        let closeNow = !writing && !handleClosed
        if closeNow { handleClosed = true }
        condition.unlock()
        if closeNow { CloseHandle(handle) }
    }
}

/// The engine's stdin: `ReadFile` on the inherited pipe handle. `close()` cancels a read that is blocked waiting for
/// the client, because `CloseHandle` on a handle with a pending synchronous read would not return, and the engine
/// closes its input while the client is still connected when a `shutdown` request arrives.
final class WindowsPipeByteSource: EngineByteSource, @unchecked Sendable {
    private let handle: HANDLE
    private let condition = NSCondition()
    private var readerThread: HANDLE?
    private var reading = false
    private var closed = false

    init(handle: HANDLE) {
        self.handle = handle
    }

    deinit {
        if let readerThread { CloseHandle(readerThread) }
    }

    static func standardInput() throws -> HANDLE {
        guard let handle = GetStdHandle(DWORD(bitPattern: -10)), handle != INVALID_HANDLE_VALUE else {
            throw WindowsPipeError.standardHandleUnavailable("stdin")
        }
        return handle
    }

    func read(maxByteCount: Int) throws -> Data {
        condition.lock()
        if closed {
            condition.unlock()
            return Data()
        }
        if readerThread == nil {
            var duplicate: HANDLE?
            let process = GetCurrentProcess()
            guard DuplicateHandle(process, GetCurrentThread(), process, &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)),
                  let duplicate else {
                let code = GetLastError()
                condition.unlock()
                throw WindowsPipeError.duplicateFailed(code)
            }
            readerThread = duplicate
        }
        reading = true
        condition.unlock()
        defer {
            condition.lock()
            reading = false
            condition.broadcast()
            condition.unlock()
        }

        var buffer = [UInt8](repeating: 0, count: maxByteCount)
        var count: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes {
            ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        guard succeeded else {
            let code = GetLastError()
            switch code {
            case DWORD(ERROR_BROKEN_PIPE), DWORD(ERROR_OPERATION_ABORTED):
                return Data()
            default:
                throw NSError(domain: "WindowsPipeByteSource.ReadFile", code: Int(code))
            }
        }
        return Data(buffer[..<Int(count)])
    }

    func close() {
        condition.lock()
        closed = true
        var attempts = 0
        while reading, let thread = readerThread, attempts < 400 {
            _ = CancelSynchronousIo(thread)
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.005))
            attempts += 1
        }
        condition.unlock()
        // The handle itself stays open until the process exits.
    }
}
