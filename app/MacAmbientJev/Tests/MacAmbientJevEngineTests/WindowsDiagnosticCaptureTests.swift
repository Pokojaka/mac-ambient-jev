import Foundation
import Testing
import WinSDK
import ucrt
import MacAmbientJevEngineHost
import MacAmbientJevTestSupport
@testable import MacAmbientJevEngine

private struct DiagnosticPipeTestError: Error, CustomStringConvertible {
    let description: String
}

private func makeDiagnosticPipe(bufferBytes: DWORD) throws -> (read: HANDLE, write: HANDLE) {
    var read: HANDLE?
    var write: HANDLE?
    guard CreatePipe(&read, &write, nil, bufferBytes), let read, let write else {
        throw DiagnosticPipeTestError(description: "CreatePipe failed (Win32 \(GetLastError()))")
    }
    return (read, write)
}

private final class DiagnosticTestHandle: @unchecked Sendable {
    let value: HANDLE
    private let lock = NSLock()
    private var closed = false

    init(_ value: HANDLE) {
        self.value = value
    }

    func close() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()
        if shouldClose { _ = CloseHandle(value) }
    }
}

private final class DiagnosticTestLatch: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var completed = false
    private var byteCount = 0
    private var failure: String?

    func finish(byteCount: Int, failure: String?) {
        lock.lock()
        self.byteCount = byteCount
        self.failure = failure
        completed = true
        lock.unlock()
        changes.signal()
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    var result: (byteCount: Int, failure: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (byteCount, failure)
    }

    func waitUntilComplete(_ description: String) async throws {
        try await changes.wait(description) { isComplete }
    }
}

private final class DiagnosticPipeReader: @unchecked Sendable {
    let changes = ChangeSignal()
    private let handle: HANDLE
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false

    init(handle: HANDLE) {
        self.handle = handle
        Thread.detachNewThread { [self] in readToEnd() }
    }

    private func readToEnd() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var count: DWORD = 0
            let succeeded = buffer.withUnsafeMutableBytes {
                ReadFile(handle, $0.baseAddress, DWORD($0.count), &count, nil)
            }
            guard succeeded, count > 0 else { break }
            lock.lock()
            storage.append(contentsOf: buffer[..<Int(count)])
            lock.unlock()
        }
        _ = CloseHandle(handle)
        lock.lock()
        finished = true
        lock.unlock()
        changes.signal()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func waitUntilFinished() async throws {
        try await changes.wait("the diagnostic egress reader to finish") { isFinished }
    }
}

private func closeCaptureOffThread(_ capture: WindowsDiagnosticCapture) -> DiagnosticTestLatch {
    let latch = DiagnosticTestLatch()
    Thread.detachNewThread {
        capture.close()
        latch.finish(byteCount: 0, failure: nil)
    }
    return latch
}

private func closeWriterOffThread(_ writer: EngineDiagnosticWriter, timeout: TimeInterval) -> DiagnosticTestLatch {
    let latch = DiagnosticTestLatch()
    Thread.detachNewThread {
        writer.close(timeout: timeout)
        latch.finish(byteCount: 0, failure: nil)
    }
    return latch
}

@Suite(.timeLimit(.minutes(10))) struct WindowsDiagnosticCaptureTests {
    @Test func waitingForNeverFinishedLatchThrowsWhenCancelled() async {
        let latch = DiagnosticTestLatch()
        let waiter = Task {
            try await latch.waitUntilComplete("a never-finished diagnostic operation")
        }
        waiter.cancel()

        await #expect(throws: WaitCancelled.self) {
            try await waiter.value
        }
    }

    @Test func stalledClientStderrDoesNotStopNativeStdoutDiagnosticIngress() async throws {
        let ingress = try makeDiagnosticPipe(bufferBytes: 4096)
        let ingressWrite = DiagnosticTestHandle(ingress.write)
        let egress = try makeDiagnosticPipe(bufferBytes: 4096)
        let writer = EngineDiagnosticWriter(
            sink: WindowsPipeByteSink(handle: egress.write),
            maxRecords: 128,
            maxBytes: 262_144,
            maxRecordBytes: 16_384
        )
        let capture = WindowsDiagnosticCapture(readHandle: ingress.read) { [writer] chunk in
            writer.write(chunk)
        }
        var pipeReader: DiagnosticPipeReader?
        defer {
            ingressWrite.close()
            if pipeReader == nil { _ = CloseHandle(egress.read) }
            _ = closeCaptureOffThread(capture)
            _ = closeWriterOffThread(writer, timeout: 0.1)
        }

        let payloadBytes = 3 * 1_048_576
        let producer = DiagnosticTestLatch()
        Thread.detachNewThread {
            let bytes = [UInt8](repeating: 0x41, count: payloadBytes)
            var offset = 0
            var failure: String?
            while offset < bytes.count {
                let requested = min(4096, bytes.count - offset)
                var written: DWORD = 0
                let succeeded = bytes.withUnsafeBytes { buffer in
                    WriteFile(
                        ingressWrite.value,
                        buffer.baseAddress!.advanced(by: offset),
                        DWORD(requested),
                        &written,
                        nil
                    )
                }
                guard succeeded, written > 0, Int(written) <= requested else {
                    failure = "WriteFile failed (Win32 \(GetLastError()))"
                    break
                }
                offset += Int(written)
            }
            ingressWrite.close()
            producer.finish(byteCount: offset, failure: failure)
        }

        try await producer.waitUntilComplete("the native stdout producer to finish")
        let producerResult = producer.result
        #expect(producerResult.failure == nil)
        #expect(producerResult.byteCount == payloadBytes)

        // No egress reader exists yet: the bounded diagnostic queue must absorb/drop records rather
        // than making the native stdout writer wait for the external client's stderr reader.
        let captureClose = closeCaptureOffThread(capture)
        try await captureClose.waitUntilComplete("diagnostic capture shutdown")
        #expect(captureClose.result.failure == nil)
        let snapshot = writer.snapshot
        #expect(snapshot.droppedRecords > 0)
        #expect(snapshot.droppedBytes > 0)
        #expect(snapshot.queuedRecords <= 128)
        #expect(snapshot.queuedBytes <= 262_144)

        let reader = DiagnosticPipeReader(handle: egress.read)
        pipeReader = reader
        let writerClose = closeWriterOffThread(writer, timeout: 3)
        try await writerClose.waitUntilComplete("bounded diagnostic writer shutdown")
        try await reader.waitUntilFinished()

        let output = String(decoding: reader.data, as: UTF8.self)
        #expect(output.contains("engine diagnostics overflow: dropped_records="))
    }

    @Test func fatalErrorAfterRedirectRemainsOnOriginalStandardError() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let originalCRTStandardError = _get_osfhandle(2)
            let originalWin32StandardError = GetStdHandle(DWORD(bitPattern: -12))
            let reservedStdout = try WindowsPipeByteSink.claimStandardOutput()
            let capture = try WindowsDiagnosticCapture.redirectStandardOutput(onChunk: { _ in })
            precondition(
                _get_osfhandle(2) == originalCRTStandardError,
                "CRT fd 2 changed before fatal error"
            )
            precondition(
                GetStdHandle(DWORD(bitPattern: -12)) == originalWin32StandardError,
                "Win32 STD_ERROR_HANDLE changed before fatal error"
            )
            _ = reservedStdout
            _ = capture
            fatalError("fatal_error_after_stdout_redirect_marker")
        }

        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(stderr.contains("fatal_error_after_stdout_redirect_marker"))
    }

    @Test func preconditionFailureAfterRedirectRemainsOnOriginalStandardError() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let originalCRTStandardError = _get_osfhandle(2)
            let originalWin32StandardError = GetStdHandle(DWORD(bitPattern: -12))
            let reservedStdout = try WindowsPipeByteSink.claimStandardOutput()
            let capture = try WindowsDiagnosticCapture.redirectStandardOutput(onChunk: { _ in })
            precondition(
                _get_osfhandle(2) == originalCRTStandardError,
                "CRT fd 2 changed before precondition failure"
            )
            precondition(
                GetStdHandle(DWORD(bitPattern: -12)) == originalWin32StandardError,
                "Win32 STD_ERROR_HANDLE changed before precondition failure"
            )
            _ = reservedStdout
            _ = capture
            preconditionFailure("precondition_failure_after_stdout_redirect_marker")
        }

        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(stderr.contains("precondition_failure_after_stdout_redirect_marker"))
    }

    @Test func stdoutPollutionIsCapturedAndBothStderrHandlesRemainUntouched() async {
        let result = await #expect(
            processExitsWith: .success,
            observing: [\.standardOutputContent, \.standardErrorContent]
        ) {
            let originalCRTStandardError = _get_osfhandle(2)
            let originalWin32StandardError = GetStdHandle(DWORD(bitPattern: -12))
            let reservedStdout = try WindowsPipeByteSink.claimStandardOutput()
            let capturedStdout = DiagnosticChunkBuffer()
            let capture = try WindowsDiagnosticCapture.redirectStandardOutput { chunk in
                capturedStdout.append(chunk)
            }
            defer {
                capture.close()
                _ = CloseHandle(reservedStdout)
            }

            precondition(
                _get_osfhandle(2) == originalCRTStandardError,
                "CRT fd 2 changed during stdout redirect"
            )
            precondition(
                GetStdHandle(DWORD(bitPattern: -12)) == originalWin32StandardError,
                "Win32 STD_ERROR_HANDLE changed during stdout redirect"
            )

            let crtStderr = "CRT_STDERR_NATIVE_MARKER\n"
            let win32Stderr = "WIN32_STDERR_NATIVE_MARKER\n"
            let crtStdout = "CRT_STDOUT_POLLUTION_MARKER\n"
            let win32Stdout = "WIN32_STDOUT_POLLUTION_MARKER\n"
            #expect(writeCRT(crtStderr, descriptor: 2) == Int32(crtStderr.utf8.count))
            #expect(writeWin32(win32Stderr, to: originalWin32StandardError))
            #expect(writeCRT(crtStdout, descriptor: 1) == Int32(crtStdout.utf8.count))
            #expect(writeWin32(win32Stdout, to: GetStdHandle(DWORD(bitPattern: -11))))

            try await capturedStdout.waitUntilContains([crtStdout, win32Stdout])
            #expect(capturedStdout.text.contains(crtStdout))
            #expect(capturedStdout.text.contains(win32Stdout))
        }

        let stdout = result?.standardOutputContent ?? []
        let stdoutText = String(decoding: stdout, as: UTF8.self)
        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        #expect(result?.exitStatus == .exitCode(0))
        // Swift Testing may emit a 32-byte child bootstrap before the body; EngineProcessTests
        // independently validates all stdout as NDJSON.
        #expect(!stdoutText.contains("CRT_STDOUT_POLLUTION_MARKER"))
        #expect(!stdoutText.contains("WIN32_STDOUT_POLLUTION_MARKER"))
        #expect(stderr.contains("CRT_STDERR_NATIVE_MARKER"))
        #expect(stderr.contains("WIN32_STDERR_NATIVE_MARKER"))
        #expect(!stderr.contains("CRT_STDOUT_POLLUTION_MARKER"))
        #expect(!stderr.contains("WIN32_STDOUT_POLLUTION_MARKER"))
    }

    @Test func closingAnIdleCaptureReturnsWithoutChangingStandardError() async throws {
        let originalStandardError = GetStdHandle(DWORD(bitPattern: -12))
        let pipe = try makeDiagnosticPipe(bufferBytes: 4096)
        let writeHandle = DiagnosticTestHandle(pipe.write)
        let receivedChunks = DiagnosticChunkCounter()
        let capture = WindowsDiagnosticCapture(readHandle: pipe.read) { chunk in
            receivedChunks.add(chunk)
        }
        defer { writeHandle.close() }

        let closeLatch = closeCaptureOffThread(capture)
        try await closeLatch.waitUntilComplete("idle diagnostic capture cancellation")
        #expect(closeLatch.result.failure == nil)
        #expect(GetStdHandle(DWORD(bitPattern: -12)) == originalStandardError)
        #expect(receivedChunks.count == 0)

        // Ensure a reader whose cancellation needed the pipe close can still finish safely.
        writeHandle.close()
        let secondClose = closeCaptureOffThread(capture)
        try await secondClose.waitUntilComplete("idle diagnostic reader completion")
        #expect(GetStdHandle(DWORD(bitPattern: -12)) == originalStandardError)
    }
}

private func writeCRT(_ text: String, descriptor: Int32) -> Int32 {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBytes {
        ucrt._write(descriptor, $0.baseAddress, UInt32($0.count))
    }
}

private func writeWin32(_ text: String, to handle: HANDLE?) -> Bool {
    guard let handle, handle != INVALID_HANDLE_VALUE else { return false }
    let bytes = Array(text.utf8)
    var written: DWORD = 0
    let succeeded = bytes.withUnsafeBytes {
        WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
    }
    return succeeded && written == DWORD(bytes.count)
}

private final class DiagnosticChunkBuffer: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var storage = ""

    func append(_ chunk: String) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
        changes.signal()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func waitUntilContains(_ expectedChunks: [String]) async throws {
        try await changes.wait("diagnostic chunks \(expectedChunks)") {
            let contents = text
            return expectedChunks.allSatisfy { contents.contains($0) }
        }
    }
}

private final class DiagnosticChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    func add(_ chunk: String) {
        lock.lock()
        storedCount += 1
        lock.unlock()
        _ = chunk
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }
}
