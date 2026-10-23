import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns a duplicate of the process's stderr handle or descriptor.
final class EngineStandardErrorSink: EngineByteSink, @unchecked Sendable {
    #if os(Windows)
    private static let writeChunkBytes = 4096
    private static let cancelRetryInterval: TimeInterval = 0.005
    private static let cancelAttempts = 400

    private enum Capture {
        case handle(HANDLE)
        case failure(EngineSinkError)
    }

    private let capture: Capture
    private let condition = NSCondition()
    private var writerThread: HANDLE?
    private var writing = false
    private var cancelled = false
    private var closed = false
    private var handleClosed = false

    init() {
        capture = Self.captureStandardError()
    }

    deinit {
        close()
        condition.lock()
        let thread = writerThread
        writerThread = nil
        condition.unlock()
        if let thread { CloseHandle(thread) }
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        precondition(bytes.count > 0, "empty write")
        condition.lock()
        guard !cancelled, !closed else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }

        let handle: HANDLE
        switch capture {
        case let .failure(error):
            condition.unlock()
            throw error
        case let .handle(capturedHandle):
            handle = capturedHandle
        }

        if writerThread == nil {
            var duplicate: HANDLE?
            let process = GetCurrentProcess()
            guard DuplicateHandle(
                process,
                GetCurrentThread(),
                process,
                &duplicate,
                0,
                false,
                DWORD(DUPLICATE_SAME_ACCESS)
            ), let duplicate else {
                let code = GetLastError()
                condition.unlock()
                throw EngineSinkError.failed("DuplicateHandle(thread) failed (Win32 \(code))")
            }
            writerThread = duplicate
        }

        writing = true
        condition.unlock()
        defer { finishWrite() }

        var written: DWORD = 0
        let count = DWORD(min(bytes.count, Self.writeChunkBytes))
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
        var attempts = 0
        while writing, let writerThread, attempts < Self.cancelAttempts {
            _ = CancelSynchronousIo(writerThread)
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
        if closeNow { closeCapturedHandle() }
    }

    private func finishWrite() {
        condition.lock()
        writing = false
        let closeNow = closed && !handleClosed
        if closeNow { handleClosed = true }
        condition.broadcast()
        condition.unlock()
        if closeNow { closeCapturedHandle() }
    }

    private func closeCapturedHandle() {
        if case let .handle(handle) = capture { CloseHandle(handle) }
    }

    private static func captureStandardError() -> Capture {
        guard let original = GetStdHandle(DWORD(bitPattern: -12)), original != INVALID_HANDLE_VALUE else {
            let code = GetLastError()
            return .failure(.failed("GetStdHandle(stderr) failed (Win32 \(code))"))
        }

        var duplicate: HANDLE?
        guard DuplicateHandle(
            GetCurrentProcess(),
            original,
            GetCurrentProcess(),
            &duplicate,
            0,
            false,
            DWORD(DUPLICATE_SAME_ACCESS)
        ), let duplicate else {
            let code = GetLastError()
            return .failure(.failed("DuplicateHandle(stderr) failed (Win32 \(code))"))
        }
        return .handle(duplicate)
    }
    #else
    private enum Capture {
        case posix(PosixByteSink)
        case failure(EngineSinkError)
    }

    private let capture: Capture

    init() {
        let descriptor = dup(STDERR_FILENO)
        guard descriptor >= 0 else {
            let code = errno
            capture = .failure(.failed("dup(stderr) failed (errno \(code): \(String(cString: strerror(code))))"))
            return
        }
        capture = .posix(PosixByteSink(fileDescriptor: descriptor))
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        switch capture {
        case let .posix(sink): try sink.write(bytes)
        case let .failure(error): throw error
        }
    }

    func cancelBlockedWrite() {
        if case let .posix(sink) = capture { sink.cancelBlockedWrite() }
    }

    func close() {
        if case let .posix(sink) = capture { sink.close() }
    }

    deinit {
        close()
    }
    #endif
}
