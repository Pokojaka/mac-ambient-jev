import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public enum EngineSinkError: Error, Equatable, Sendable {
    case brokenPipe
    /// `cancelBlockedWrite()` interrupted the write.
    case cancelled
    case failed(String)
}

/// Raw binary input. No text translation, no code page.
public protocol EngineByteSource: Sendable {
    /// Blocks until at least one byte is available. An empty result is end of input.
    func read(maxByteCount: Int) throws -> Data
    func close()
}

/// Raw binary output. The Windows executable supplies a `WriteFile` sink whose
/// `cancelBlockedWrite()` calls `CancelSynchronousIo` on the writer thread.
public protocol EngineByteSink: Sendable {
    /// Blocks until at least one byte is accepted and returns the count accepted, which may be
    /// fewer than `bytes.count`. Throws `brokenPipe`, `cancelled` or `failed`.
    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int
    /// Called from another thread. Makes a write blocked on a full pipe throw `cancelled`.
    func cancelBlockedWrite()
    /// Closes the client connection. Idempotent. A write in progress must be cancelled first.
    func close()
}

public final class FileHandleByteSource: EngineByteSource, @unchecked Sendable {
    private let handle: FileHandle

    public init(handle: FileHandle) {
        self.handle = handle
    }

    /// A single OS read, so a partial record is delivered as soon as it arrives. `FileHandle.read(upToCount:)`
    /// can wait for the full count on a pipe, which would stall interactive requests.
    public func read(maxByteCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxByteCount)
        #if os(Windows)
        var count: DWORD = 0
        let succeeded = buffer.withUnsafeMutableBytes {
            ReadFile(handle._handle, $0.baseAddress, DWORD($0.count), &count, nil)
        }
        guard succeeded else {
            let code = GetLastError()
            if code == DWORD(ERROR_BROKEN_PIPE) { return Data() }
            throw NSError(domain: "EngineByteSource.ReadFile", code: Int(code))
        }
        return Data(buffer[..<Int(count)])
        #else
        while true {
            let count = Foundation.read(handle.fileDescriptor, &buffer, maxByteCount)
            if count >= 0 { return Data(buffer[..<count]) }
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #endif
    }

    public func close() {
        do {
            try handle.close()
        } catch {
            EngineLog.write("input close failed: \(error)")
        }
    }
}

public enum EngineLog {
    private static let writer = EngineDiagnosticWriter(
        sink: EngineStandardErrorSink(),
        maxRecords: 128,
        maxBytes: 262_144,
        maxRecordBytes: 16_384
    )

    /// Queues a bounded diagnostic record to stderr; stdout remains reserved for NDJSON records.
    public static func write(_ message: String) {
        writer.write(message)
    }

    public static func close(timeout: TimeInterval) {
        writer.close(timeout: timeout)
    }

    public static func snapshot() -> EngineDiagnosticSnapshot {
        writer.snapshot
    }
}

#if !os(Windows)
/// Writes to a POSIX pipe descriptor without changing its file status flags.
///
/// Each write waits for `poll(POLLOUT)` in short slices and then writes at most `PIPE_BUF`
/// (POSIX minimum 512) bytes, which a writable pipe accepts without blocking. That keeps a full
/// pipe cancellable by flag. SIGPIPE is ignored process-wide so a closed reader surfaces as `brokenPipe`.
public final class PosixByteSink: EngineByteSink, @unchecked Sendable {
    private static let atomicChunk = 512
    private static let pollSliceMilliseconds: Int32 = 25

    private let descriptor: Int32
    private let condition = NSCondition()
    private var cancelled = false
    private var closeRequested = false
    private var descriptorClosed = false
    private var writersInside = 0

    public init(fileDescriptor: Int32) {
        _ = signal(SIGPIPE, SIG_IGN)
        descriptor = fileDescriptor
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        precondition(bytes.count > 0, "empty write")
        condition.lock()
        guard !cancelled, !closeRequested else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        writersInside += 1
        condition.unlock()
        defer { leave() }

        let count = min(bytes.count, Self.atomicChunk)
        while true {
            condition.lock()
            let stop = cancelled
            condition.unlock()
            if stop { throw EngineSinkError.cancelled }

            var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&request, 1, Self.pollSliceMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw EngineSinkError.failed(String(cString: strerror(errno)))
            }
            if ready == 0 { continue }
            if request.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw EngineSinkError.brokenPipe
            }
            let written = Foundation.write(descriptor, bytes.baseAddress, count)
            if written < 0 {
                switch errno {
                case EINTR, EAGAIN: continue
                case EPIPE: throw EngineSinkError.brokenPipe
                default: throw EngineSinkError.failed(String(cString: strerror(errno)))
                }
            }
            return written
        }
    }

    public func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        condition.unlock()
    }

    public func close() {
        condition.lock()
        closeRequested = true
        cancelled = true
        let closeNow = writersInside == 0 && !descriptorClosed
        if closeNow { descriptorClosed = true }
        condition.unlock()
        if closeNow { Foundation.close(descriptor) }
    }

    private func leave() {
        condition.lock()
        writersInside -= 1
        let closeNow = writersInside == 0 && closeRequested && !descriptorClosed
        if closeNow { descriptorClosed = true }
        condition.unlock()
        if closeNow { Foundation.close(descriptor) }
    }
}
#endif
