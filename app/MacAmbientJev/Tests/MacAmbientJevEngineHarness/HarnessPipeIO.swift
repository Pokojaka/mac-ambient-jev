import Foundation
import MacAmbientJevEngineHost

#if os(Windows)
import WinSDK

private enum HarnessWindowsPipeError: Error, LocalizedError {
    case standardHandleUnavailable(String)
    case duplicateFailed(DWORD)
    case invalidDuplicatedHandle
    case invalidByteCount(Int)
    case readFailed(DWORD)

    var errorDescription: String? {
        switch self {
        case .standardHandleUnavailable(let name): "Windows standard handle is unavailable: \(name)"
        case .duplicateFailed(let code): "DuplicateHandle failed (Win32 \(code))"
        case .invalidDuplicatedHandle: "DuplicateHandle returned an invalid handle"
        case .invalidByteCount(let count): "Pipe byte count must be positive: \(count)"
        case .readFailed(let code): "ReadFile failed (Win32 \(code))"
        }
    }
}

/// Borrowed stdin handle. Closing the source interrupts its synchronous read without closing
/// the process-owned standard handle.
private final class HarnessWindowsByteSource: EngineByteSource, @unchecked Sendable {
    private static let chunkBytes = 4096
    private static let cancelRetryInterval: TimeInterval = 0.005
    private static let cancelAttempts = 400

    private let handle: HANDLE
    private let condition = NSCondition()
    private var readerThread: HANDLE?
    private var reading = false
    private var closed = false

    init(handle: HANDLE) {
        self.handle = handle
    }

    deinit {
        if let readerThread, !CloseHandle(readerThread) {
            EngineLog.write("CloseHandle(reader thread) failed (Win32 \(GetLastError()))")
        }
    }

    func read(maxByteCount: Int) throws -> Data {
        guard maxByteCount > 0 else { throw HarnessWindowsPipeError.invalidByteCount(maxByteCount) }

        condition.lock()
        guard !closed else {
            condition.unlock()
            return Data()
        }
        if readerThread == nil {
            var duplicate: HANDLE?
            let process = GetCurrentProcess()
            guard DuplicateHandle(
                process, GetCurrentThread(), process, &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)
            ) else {
                let code = GetLastError()
                condition.unlock()
                throw HarnessWindowsPipeError.duplicateFailed(code)
            }
            guard let duplicate, duplicate != INVALID_HANDLE_VALUE else {
                condition.unlock()
                throw HarnessWindowsPipeError.invalidDuplicatedHandle
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

        var buffer = [UInt8](repeating: 0, count: min(maxByteCount, Self.chunkBytes))
        var count: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes {
            ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        guard succeeded else {
            let code = GetLastError()
            if code == DWORD(ERROR_BROKEN_PIPE) { return Data() }
            if code == DWORD(ERROR_OPERATION_ABORTED) {
                condition.lock()
                let wasClosed = closed
                condition.unlock()
                if wasClosed { return Data() }
            }
            throw HarnessWindowsPipeError.readFailed(code)
        }
        return Data(buffer[..<Int(count)])
    }

    func close() {
        condition.lock()
        closed = true
        var attempts = 0
        while reading, let thread = readerThread, attempts < Self.cancelAttempts {
            _ = CancelSynchronousIo(thread)
            _ = condition.wait(until: Date(timeIntervalSinceNow: Self.cancelRetryInterval))
            attempts += 1
        }
        condition.unlock()
        // The standard input handle is inherited and remains open until process exit.
    }
}

/// Owns a duplicate of stdout, so transport shutdown can close it without changing the process
/// standard handle. Writes and cancellation match the production synchronous-pipe semantics.
private final class HarnessWindowsByteSink: EngineByteSink, @unchecked Sendable {
    private static let chunkBytes = 4096
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
        close()
        if let writerThread, !CloseHandle(writerThread) {
            EngineLog.write("CloseHandle(writer thread) failed (Win32 \(GetLastError()))")
        }
    }

    static func standardOutput() throws -> HarnessWindowsByteSink {
        guard let original = GetStdHandle(DWORD(bitPattern: -11)), original != INVALID_HANDLE_VALUE else {
            throw HarnessWindowsPipeError.standardHandleUnavailable("stdout")
        }
        var duplicate: HANDLE?
        let process = GetCurrentProcess()
        guard DuplicateHandle(
            process, original, process, &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)
        ) else {
            throw HarnessWindowsPipeError.duplicateFailed(GetLastError())
        }
        guard let duplicate, duplicate != INVALID_HANDLE_VALUE else {
            throw HarnessWindowsPipeError.invalidDuplicatedHandle
        }
        return HarnessWindowsByteSink(handle: duplicate)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        guard bytes.count > 0 else { throw EngineSinkError.failed("WriteFile received an empty buffer") }

        condition.lock()
        guard !cancelled, !closed else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        if writerThread == nil {
            var duplicate: HANDLE?
            let process = GetCurrentProcess()
            guard DuplicateHandle(
                process, GetCurrentThread(), process, &duplicate, 0, false, DWORD(DUPLICATE_SAME_ACCESS)
            ) else {
                let code = GetLastError()
                condition.unlock()
                throw EngineSinkError.failed("DuplicateHandle(thread) failed (Win32 \(code))")
            }
            guard let duplicate, duplicate != INVALID_HANDLE_VALUE else {
                condition.unlock()
                throw EngineSinkError.failed("DuplicateHandle(thread) returned an invalid handle")
            }
            writerThread = duplicate
        }
        writing = true
        condition.unlock()
        defer { finishWrite() }

        var written: DWORD = 0
        let count = DWORD(min(bytes.count, Self.chunkBytes))
        if WriteFile(handle, bytes.baseAddress, count, &written, nil) {
            guard written > 0 else {
                throw EngineSinkError.failed("WriteFile succeeded without accepting bytes")
            }
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
        let closeNow = !writing && !handleClosed
        if closeNow { handleClosed = true }
        condition.unlock()
        if closeNow { closeOwnedHandle() }
    }

    private func finishWrite() {
        condition.lock()
        writing = false
        condition.broadcast()
        let closeNow = closed && !handleClosed
        if closeNow { handleClosed = true }
        condition.unlock()
        if closeNow { closeOwnedHandle() }
    }

    private func closeOwnedHandle() {
        if !CloseHandle(handle) {
            EngineLog.write("CloseHandle(stdout duplicate) failed (Win32 \(GetLastError()))")
        }
    }
}

enum HarnessPipeIO {
    static func makeSource() throws -> any EngineByteSource {
        guard let handle = GetStdHandle(DWORD(bitPattern: -10)), handle != INVALID_HANDLE_VALUE else {
            throw HarnessWindowsPipeError.standardHandleUnavailable("stdin")
        }
        return HarnessWindowsByteSource(handle: handle)
    }

    static func makeSink() throws -> any EngineByteSink {
        try HarnessWindowsByteSink.standardOutput()
    }
}

#else
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HarnessPipeIO {
    static func makeSource() throws -> any EngineByteSource {
        FileHandleByteSource(handle: .standardInput)
    }

    static func makeSink() throws -> any EngineByteSink {
        PosixByteSink(fileDescriptor: Int32(STDOUT_FILENO))
    }
}
#endif
