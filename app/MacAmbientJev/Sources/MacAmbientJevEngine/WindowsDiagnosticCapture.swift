import Foundation
import WinSDK
import ucrt

/// Drains native stdout bytes away from the client pipe and hands bounded UTF-8 chunks to a queue.
final class WindowsDiagnosticCapture: @unchecked Sendable {
    private static let chunkBytes = 4096
    private static let closeWait: TimeInterval = 2

    private let readHandle: HANDLE
    private let source: WindowsPipeByteSource
    private let onChunk: @Sendable (String) -> Void
    private let condition = NSCondition()

    // State below is protected by condition.
    private var readerFinished = false
    private var closeRequested = false
    private var readHandleClosed = false

    init(readHandle: HANDLE, onChunk: @escaping @Sendable (String) -> Void) {
        self.readHandle = readHandle
        self.source = WindowsPipeByteSource(handle: readHandle)
        self.onChunk = onChunk
        Thread.detachNewThread { [self] in drain() }
    }

    deinit {
        condition.lock()
        let shouldCloseHandle = readerFinished && !readHandleClosed
        readHandleClosed = true
        condition.unlock()
        if shouldCloseHandle { _ = CloseHandle(readHandle) }
    }

    /// Redirects the process's CRT and Win32 stdout to a private anonymous pipe.
    /// The CRT owns the transferred write handle after `_open_osfhandle` succeeds.
    static func redirectStandardOutput(
        onChunk: @escaping @Sendable (String) -> Void
    ) throws -> WindowsDiagnosticCapture {
        var readHandle: HANDLE?
        var writeHandle: HANDLE?
        guard CreatePipe(&readHandle, &writeHandle, nil, 65_536) else {
            let code = GetLastError()
            throw win32Error("CreatePipe", code: code)
        }
        guard let readHandle, let writeHandle else {
            preconditionFailure("CreatePipe succeeded without valid pipe handles")
        }

        var captureOwnsReadHandle = true
        defer {
            if captureOwnsReadHandle { _ = CloseHandle(readHandle) }
        }

        let descriptor = _open_osfhandle(Int(bitPattern: writeHandle), _O_BINARY | _O_WRONLY)
        guard descriptor >= 0 else {
            let code = Int32(errno)
            _ = CloseHandle(writeHandle)
            throw crtError("_open_osfhandle", code: code)
        }

        var descriptorCloseAttempted = false
        defer {
            if !descriptorCloseAttempted { _ = _close(descriptor) }
        }

        guard _dup2(descriptor, 1) == 0 else {
            let code = Int32(errno)
            throw crtError("_dup2(stdout)", code: code)
        }

        descriptorCloseAttempted = true
        guard _close(descriptor) == 0 else {
            let code = Int32(errno)
            throw crtError("_close(temporary stdout)", code: code)
        }

        let standardOutputValue = _get_osfhandle(1)
        guard standardOutputValue != -1,
              let standardOutputHandle = HANDLE(bitPattern: standardOutputValue) else {
            let code = Int32(errno)
            throw crtError("_get_osfhandle(stdout)", code: code)
        }
        guard SetStdHandle(DWORD(bitPattern: -11), standardOutputHandle) else {
            let code = GetLastError()
            throw win32Error("SetStdHandle(stdout)", code: code)
        }

        captureOwnsReadHandle = false
        return WindowsDiagnosticCapture(readHandle: readHandle, onChunk: onChunk)
    }

    /// Cancels a pending read and closes the owned read handle only after its reader has stopped.
    func close() {
        condition.lock()
        let shouldCancelSource = !closeRequested
        closeRequested = true
        condition.unlock()

        if shouldCancelSource { source.close() }

        let deadline = Date().addingTimeInterval(Self.closeWait)
        condition.lock()
        while !readerFinished {
            if !condition.wait(until: deadline) { break }
        }
        let shouldCloseHandle = readerFinished && !readHandleClosed
        if shouldCloseHandle { readHandleClosed = true }
        condition.unlock()

        // If a synchronous read is still pending, the reader thread retains this object and closes
        // the handle after it eventually returns; closing it here could leave live I/O on a reused handle.
        if shouldCloseHandle { _ = CloseHandle(readHandle) }
    }

    private func drain() {
        do {
            while true {
                let bytes = try source.read(maxByteCount: Self.chunkBytes)
                guard !bytes.isEmpty else { break }
                onChunk(String(decoding: bytes, as: UTF8.self))
            }
        } catch {
            onChunk(Self.readFailureDiagnostic(error))
        }

        condition.lock()
        readerFinished = true
        condition.broadcast()
        condition.unlock()
    }

    private static func readFailureDiagnostic(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "WindowsPipeByteSource.ReadFile" {
            return "Windows diagnostic capture ReadFile failed (Win32 \(nsError.code))"
        }
        return "Windows diagnostic capture read failed (\(nsError.domain) code \(nsError.code)): \(nsError.localizedDescription)"
    }

    private static func win32Error(_ operation: String, code: DWORD) -> NSError {
        NSError(
            domain: "WindowsDiagnosticCapture.\(operation)",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (Win32 \(code))"]
        )
    }

    private static func crtError(_ operation: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (errno \(code))"]
        )
    }
}
