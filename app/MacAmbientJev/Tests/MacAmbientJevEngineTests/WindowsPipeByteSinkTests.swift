import Foundation
import Testing
import WinSDK
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevCore
import MacAmbientJevTestSupport
@testable import MacAmbientJevEngine

private struct PipeTestError: Error, CustomStringConvertible {
    let description: String
}

/// An anonymous pipe with a small buffer, like the one P5's shell creates.
private func makePipe(bufferBytes: DWORD = 4096) throws -> (read: HANDLE, write: HANDLE) {
    var read: HANDLE?
    var write: HANDLE?
    guard CreatePipe(&read, &write, nil, bufferBytes), let read, let write else {
        throw PipeTestError(description: "CreatePipe failed (Win32 \(GetLastError()))")
    }
    return (read, write)
}

/// Reads the pipe on its own thread, optionally slowly, until the write end closes. `changes` signals after every chunk.
private final class PipeReader: @unchecked Sendable {
    let changes = ChangeSignal()
    private let handle: HANDLE
    private let lock = NSLock()
    private var storage = Data()
    private let pause: TimeInterval

    init(handle: HANDLE, pause: TimeInterval) {
        self.handle = handle
        self.pause = pause
        Thread.detachNewThread { [self] in run() }
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            var count: DWORD = 0
            guard ReadFile(handle, &buffer, DWORD(buffer.count), &count, nil), count > 0 else { break }
            lock.lock()
            storage.append(contentsOf: buffer[..<Int(count)])
            lock.unlock()
            changes.signal()
        }
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Runs a synchronous call that can block, such as cancelling or closing a sink, on its own thread as production does.
private func blocking(_ body: @escaping @Sendable () -> Void) async {
    await Task.detached(executorPreference: BlockingIOExecutor.shared, operation: body).value
}

private func testLimits(deadline: TimeInterval) -> EngineTransportLimits {
    EngineTransportLimits(
        maxQueuedRecords: 128,
        maxQueuedBytes: 8 * 1_048_576,
        reservedControlRecords: 32,
        reservedControlBytes: 2 * 1_048_576,
        maxPendingInputLines: 32,
        readChunkBytes: 4096,
        writeDeadlineNanoseconds: UInt64(deadline * 1_000_000_000)
    )
}

@Suite(.timeLimit(.minutes(10))) struct WindowsPipeByteSinkTests {
    @Test func aWriteBlockedOnAFullPipeIsCancelledFromAnotherThread() async throws {
        let pipe = try makePipe()
        defer { CloseHandle(pipe.read) }
        let sink = WindowsPipeByteSink(handle: pipe.write)
        let outcome = Outcome()
        Thread.detachNewThread {
            let block = [UInt8](repeating: 0x41, count: 65_536)
            do {
                while true {
                    let written = try block.withUnsafeBytes { try sink.write($0) }
                    outcome.add(written)
                }
            } catch {
                outcome.finish(error)
            }
        }
        // 4 KiB fit the pipe buffer; the next write blocks because nobody reads.
        try await outcome.changes.wait("the write to fill the pipe") { outcome.totalBytes >= 4096 }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(outcome.error == nil)

        await blocking { sink.cancelBlockedWrite() }
        try await outcome.changes.wait("the blocked write to return") { outcome.error != nil }
        #expect(outcome.error as? EngineSinkError == .cancelled)
        await blocking { sink.close() }
        // A cancelled sink refuses further writes.
        #expect(throws: EngineSinkError.cancelled) {
            _ = try [UInt8](repeating: 1, count: 4).withUnsafeBytes { try sink.write($0) }
        }
    }

    @Test func aClosedReaderIsABrokenPipe() async throws {
        let pipe = try makePipe()
        let sink = WindowsPipeByteSink(handle: pipe.write)
        CloseHandle(pipe.read)
        defer { sink.close() }
        #expect(throws: EngineSinkError.brokenPipe) {
            _ = try [UInt8](repeating: 1, count: 16).withUnsafeBytes { try sink.write($0) }
        }
    }

    @Test func aDrainingReaderReceivesEveryByteInOrder() async throws {
        let pipe = try makePipe()
        let reader = PipeReader(handle: pipe.read, pause: 0)
        let sink = WindowsPipeByteSink(handle: pipe.write)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let writerDone = Outcome()
        Thread.detachNewThread {
            do {
                var offset = 0
                while offset < payload.count {
                    let written = try payload.withUnsafeBytes { try sink.write(UnsafeRawBufferPointer(rebasing: $0[offset...])) }
                    precondition(written > 0 && written <= WindowsPipeByteSink.chunkBytes)
                    offset += written
                }
                writerDone.finish(nil)
            } catch {
                writerDone.finish(error)
            }
        }
        try await reader.changes.wait("the reader to receive the payload") { reader.data.count >= payload.count }
        #expect(reader.data == payload)
        await blocking { sink.close() }
        CloseHandle(pipe.read)
    }

    @Test func aSlowPipeReaderReceivesEveryTransportRecordIntact() async throws {
        let pipe = try makePipe()
        let reader = PipeReader(handle: pipe.read, pause: 0.0002)
        let transport = EngineTransport(source: IdleSource(), sink: WindowsPipeByteSink(handle: pipe.write), limits: testLimits(deadline: 5))
        transport.start()
        defer { transport.close() }

        let text = String(repeating: "あ", count: 3000)
        for id in 1...40 {
            try await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
            let row = try EngineTranscriptRow(rowID: "r\(id)", startMS: 0, endMS: 10, text: text, headings: [], clauseState: nil)
            try transport.sendReplaceable(
                .rows(try EngineRowsPayload(
                    sessionID: "s", revision: EngineID(UInt64(id)), kind: .changes, rows: [row], removedRowIDs: [], nextCursor: nil
                )),
                requestID: nil
            )
        }
        await transport.drain()
        try await reader.changes.wait("the reader to receive all records") {
            reader.data.last == 0x0A && ((try? decode(reader.data).count) ?? 0) >= 41
        }
        let outputs = try decode(reader.data)
        #expect(outputs.filter { if case .completed = $0.event { true } else { false } }.count == 40)
        #expect(outputs.map(\.sequence.value) == outputs.map(\.sequence.value).sorted())
    }

    @Test func aPipeThatIsNeverReadFailsAtTheDeadlineWithoutHangingTheEngine() async throws {
        let pipe = try makePipe()
        defer { CloseHandle(pipe.read) }
        let transport = EngineTransport(source: IdleSource(), sink: WindowsPipeByteSink(handle: pipe.write), limits: testLimits(deadline: 0.5))
        transport.start()
        defer { transport.close() }
        // Enough records to exceed the pipe buffer, which nobody drains.
        for id in 1...200 {
            do {
                try await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
            } catch {
                break
            }
        }
        var failure: EngineWriteFailure?
        for await event in transport.events {
            if case let .writeFailed(reason) = event {
                failure = reason
                break
            }
        }
        #expect(failure == .deadlineExceeded)
    }
}

private func decode(_ data: Data) throws -> [EngineOutput] {
    guard data.last == 0x0A else { throw PipeTestError(description: "output does not end with LF") }
    return try data.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false).map {
        try EngineCodec.decodeOutput(Data($0))
    }
}

/// What a writer thread did; `changes` signals after every update.
private final class Outcome: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var written = 0
    private var failure: (any Error)?

    func add(_ bytes: Int) {
        lock.lock()
        written += bytes
        lock.unlock()
        changes.signal()
    }

    func finish(_ error: (any Error)?) {
        lock.lock()
        failure = error
        lock.unlock()
        changes.signal()
    }

    var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

/// A source that never delivers anything and ends when closed.
private final class IdleSource: EngineByteSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false

    func read(maxByteCount: Int) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while !closed { condition.wait() }
        return Data()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }
}
