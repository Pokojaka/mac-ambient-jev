import Foundation
import Testing
@testable import MacAmbientJevEngineHost

private final class GatedDiagnosticSink: EngineByteSink, @unchecked Sendable {
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
        while blocked && !cancelled && !closed { condition.wait() }
        guard !cancelled, !closed else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        let accepted = min(bytes.count, maxBytesPerWrite)
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[..<accepted]))
        condition.broadcast()
        condition.unlock()
        return accepted
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        cancelCalls += 1
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func release() {
        condition.lock()
        blocked = false
        condition.broadcast()
        condition.unlock()
    }

    func waitForWrite(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while entered == 0 {
            if !condition.wait(until: deadline) { return false }
        }
        return true
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

private final class CompletionLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var isComplete = false

    func signal() {
        condition.lock()
        isComplete = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !isComplete {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

@Suite struct EngineDiagnosticWriterTests {
    @Test func blockedSinkDoesNotBlockProducerAndReportsExactOverflowBeforeRecords() {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 7, maxBytes: 14, maxRecordBytes: 64)
        writer.write("seed")
        #expect(sink.waitForWrite())

        let completed = CompletionLatch()
        Thread.detachNewThread {
            for _ in 0..<10_000 { writer.write("x") }
            completed.signal()
        }
        #expect(completed.wait(timeout: 2), "producer must finish while the sink remains blocked")

        let beforeRelease = writer.snapshot
        #expect(beforeRelease.queuedRecords == 7)
        #expect(beforeRelease.queuedBytes == 14)
        #expect(beforeRelease.droppedRecords == 9_993)
        #expect(beforeRelease.droppedBytes == 19_986)

        sink.release()
        writer.close(timeout: 3)
        let output = String(decoding: sink.received, as: UTF8.self)
        #expect(output.hasPrefix("seed\nengine diagnostics overflow: dropped_records=9993 dropped_bytes=19986\n"))
        #expect(output.hasSuffix(String(repeating: "x\n", count: 7)))
        #expect(sink.isClosed)
    }

    @Test func oversizedMessagesAreCountedWithoutTruncationAndPartialWritesComplete() {
        let sink = GatedDiagnosticSink(blocked: false, maxBytesPerWrite: 1)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 4, maxBytes: 128, maxRecordBytes: 8)
        writer.write(String(repeating: "é", count: 20))
        writer.write("ok")
        writer.close(timeout: 3)

        let expected = "engine diagnostics overflow: dropped_records=1 dropped_bytes=41\nok\n"
        #expect(String(decoding: sink.received, as: UTF8.self) == expected)
        #expect(writer.snapshot.droppedRecords == 1)
        #expect(writer.snapshot.droppedBytes == 41)
    }

    @Test func maxRecordBytesIncludesTheLineFeed() {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 4, maxBytes: 32, maxRecordBytes: 4)
        writer.write("a")
        #expect(sink.waitForWrite())
        writer.write("abc")
        writer.write("abcd")
        sink.release()
        writer.close(timeout: 3)

        let expected = "a\nengine diagnostics overflow: dropped_records=1 dropped_bytes=5\nabc\n"
        #expect(String(decoding: sink.received, as: UTF8.self) == expected)
        #expect(writer.snapshot.droppedRecords == 1)
        #expect(writer.snapshot.droppedBytes == 5)
    }

    @Test func zeroProgressSinkStopsAndAccountsForQueuedRecords() {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: 0)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 3, maxBytes: 32, maxRecordBytes: 16)
        writer.write("first")
        #expect(sink.waitForWrite())
        writer.write("x")
        writer.write("yz")

        sink.release()
        writer.close(timeout: 3)

        let snapshot = writer.snapshot
        #expect(snapshot.queuedRecords == 0)
        #expect(snapshot.queuedBytes == 0)
        #expect(snapshot.droppedRecords == 3)
        #expect(snapshot.droppedBytes == 11)
        #expect(sink.received.isEmpty)
        #expect(sink.isClosed)
    }

    @Test func closeCancelsAFullBlockedSinkWithinItsDeadline() {
        let sink = GatedDiagnosticSink(blocked: true, maxBytesPerWrite: Int.max)
        let writer = EngineDiagnosticWriter(sink: sink, maxRecords: 2, maxBytes: 8, maxRecordBytes: 8)
        writer.write("busy")
        #expect(sink.waitForWrite())
        writer.write("a")
        writer.write("b")

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
