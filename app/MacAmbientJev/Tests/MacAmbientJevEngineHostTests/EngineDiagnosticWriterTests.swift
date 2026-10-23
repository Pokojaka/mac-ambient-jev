import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevTestSupport
@testable import MacAmbientJevEngineHost

/// `changes` signals when a write enters, after each accepted write, and on cancel and close.
private final class GatedDiagnosticSink: EngineByteSink, @unchecked Sendable {
    let changes = ChangeSignal()
    private let condition = NSCondition()
    private var storage = Data()
    private var blocked: Bool
    private var cancelled = false
    private var closed = false
    private var entered = 0
    private var cancelCalls = 0
    private let maxBytesPerWrite: Int

    init(blocked: Bool, maxBytesPerWrite: Int) {
        self.blocked = blocked
        self.maxBytesPerWrite = maxBytesPerWrite
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        condition.lock()
        entered += 1
        condition.broadcast()
        changes.signal()
        while blocked && !cancelled && !closed { condition.wait() }
        guard !cancelled, !closed else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        let accepted = min(bytes.count, maxBytesPerWrite)
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[..<accepted]))
        condition.broadcast()
        condition.unlock()
        changes.signal()
        return accepted
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        cancelCalls += 1
        condition.broadcast()
        condition.unlock()
        changes.signal()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
        changes.signal()
    }

    func release() {
        condition.lock()
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    func waitForWrite() async throws {
        try await changes.wait("the writer to enter the sink") { enteredWrites > 0 }
    }

    var enteredWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var received: Data {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    var cancelCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return cancelCalls
    }

    var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }
}

/// Set once by a producer thread; `changes` signals when it is set.
private final class CompletionFlag: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var complete = false

    func set() {
        lock.lock()
        complete = true
        lock.unlock()
        changes.signal()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }
}

/// `close` waits for the writer thread, so it runs on its own thread as production runs blocking calls.
private func close(_ writer: EngineDiagnosticWriter, timeout: TimeInterval) async {
    await Task.detached(executorPreference: BlockingIOExecutor.shared) { writer.close(timeout: timeout) }.value
}

@Suite(.timeLimit(.minutes(10))) struct EngineDiagnosticWriterTests {
    @Test func blockedSinkDoesNotBlockProducerAndReportsExactOverflowBeforeRecords() async throws {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 7, maxBytes: 14, maxRecordBytes: 64)
        writer.write("seed")
        try await sink.waitForWrite()

        let completed = CompletionFlag()
        Thread.detachNewThread {
            for _ in 0..<10_000 { writer.write("x") }
            completed.set()
        }
        try await completed.changes.wait("the producer to finish while the sink remains blocked") { completed.isSet }

        let beforeRelease = writer.snapshot
        #expect(beforeRelease.queuedRecords == 7)
        #expect(beforeRelease.queuedBytes == 14)
        #expect(beforeRelease.droppedRecords == 9_993)
        #expect(beforeRelease.droppedBytes == 19_986)

        let expected = "seed\nengine diagnostics overflow: dropped_records=9993 dropped_bytes=19986\n"
            + String(repeating: "x\n", count: 7)
        sink.release()
        try await sink.changes.wait("every record to reach the sink") {
            String(decoding: sink.received, as: UTF8.self) == expected
        }
        await close(writer, timeout: 3)
        #expect(String(decoding: sink.received, as: UTF8.self) == expected)
        #expect(sink.isClosed)
    }

    @Test func oversizedMessagesAreCountedWithoutTruncationAndPartialWritesComplete() async throws {
        let sink = GatedDiagnosticSink(blocked: false, maxBytesPerWrite: 1)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 4, maxBytes: 128, maxRecordBytes: 8)
        writer.write(String(repeating: "é", count: 20))
        writer.write("ok")

        let expected = "engine diagnostics overflow: dropped_records=1 dropped_bytes=41\nok\n"
        try await sink.changes.wait("every record to reach the sink") {
            String(decoding: sink.received, as: UTF8.self) == expected
        }
        await close(writer, timeout: 3)
        #expect(String(decoding: sink.received, as: UTF8.self) == expected)
        #expect(writer.snapshot.droppedRecords == 1)
        #expect(writer.snapshot.droppedBytes == 41)
    }

    @Test func maxRecordBytesIncludesTheLineFeed() async throws {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 4, maxBytes: 32, maxRecordBytes: 4)
        writer.write("a")
        try await sink.waitForWrite()
        writer.write("abc")
        writer.write("abcd")
        sink.release()

        let expected = "a\nengine diagnostics overflow: dropped_records=1 dropped_bytes=5\nabc\n"
        try await sink.changes.wait("every record to reach the sink") {
            String(decoding: sink.received, as: UTF8.self) == expected
        }
        await close(writer, timeout: 3)
        #expect(String(decoding: sink.received, as: UTF8.self) == expected)
        #expect(writer.snapshot.droppedRecords == 1)
        #expect(writer.snapshot.droppedBytes == 5)
    }

    @Test func zeroProgressSinkStopsAndAccountsForQueuedRecords() async throws {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: 0)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 3, maxBytes: 32, maxRecordBytes: 16)
        writer.write("first")
        try await sink.waitForWrite()
        writer.write("x")
        writer.write("yz")

        sink.release()
        // The writer closes the sink only after it has accounted for every dropped record.
        try await sink.changes.wait("the stopped writer to close the sink") { sink.isClosed }
        await close(writer, timeout: 3)

        let snapshot = writer.snapshot
        #expect(snapshot.queuedRecords == 0)
        #expect(snapshot.queuedBytes == 0)
        #expect(snapshot.droppedRecords == 3)
        #expect(snapshot.droppedBytes == 11)
        #expect(sink.received.isEmpty)
    }

    @Test func closeCancelsAFullBlockedSinkWithinItsDeadline() async throws {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 2, maxBytes: 8, maxRecordBytes: 8)
        writer.write("busy")
        try await sink.waitForWrite()
        writer.write("a")
        writer.write("b")

        // A zero timeout never waits, so this close does not block.
        let startedAt = Date()
        writer.close(timeout: 0)
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed < 1)
        #expect(sink.cancelCount == 1)
        #expect(sink.isClosed)
        #expect(writer.snapshot.droppedRecords >= 2)
        #expect(writer.snapshot.droppedBytes >= 4)
        writer.close(timeout: 1)
        #expect(sink.cancelCount == 1)
    }
}
