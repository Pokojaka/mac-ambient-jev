import Foundation

public struct EngineDiagnosticSnapshot: Sendable {
    public let queuedRecords: Int
    public let queuedBytes: Int
    public let droppedRecords: UInt64
    public let droppedBytes: UInt64

    fileprivate init(queuedRecords: Int, queuedBytes: Int, droppedRecords: UInt64, droppedBytes: UInt64) {
        self.queuedRecords = queuedRecords
        self.queuedBytes = queuedBytes
        self.droppedRecords = droppedRecords
        self.droppedBytes = droppedBytes
    }
}

/// A bounded stderr diagnostics queue with one dedicated, blocking writer thread.
public final class EngineDiagnosticWriter: @unchecked Sendable {
    private struct Record {
        let bytes: Data
    }

    private enum Work {
        case record(Data)
        case overflow(Data)

        var bytes: Data {
            switch self {
            case let .record(bytes), let .overflow(bytes): bytes
            }
        }
    }

    private let sink: any EngineByteSink
    private let maxRecords: Int
    private let maxBytes: Int
    private let maxRecordBytes: Int
    private let condition = NSCondition()

    // All state below is protected by condition.
    private var records: [Record] = []
    private var queuedBytes = 0
    private var droppedRecords: UInt64 = 0
    private var droppedBytes: UInt64 = 0
    private var pendingDroppedRecords: UInt64 = 0
    private var pendingDroppedBytes: UInt64 = 0
    private var accepting = true
    private var closeRequested = false
    private var forcedClose = false
    private var sinkCloseClaimed = false
    private var workerFinished = false

    public init(sink: any EngineByteSink, maxRecords: Int, maxBytes: Int, maxRecordBytes: Int) {
        precondition(maxRecords > 0, "maxRecords must be positive")
        precondition(maxBytes > 0, "maxBytes must be positive")
        precondition(maxRecordBytes > 0, "maxRecordBytes must be positive")
        self.sink = sink
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
        self.maxRecordBytes = maxRecordBytes
        Thread.detachNewThread { [self] in writerLoop() }
    }

    /// Queues one LF-terminated diagnostic record, or counts it as dropped when it cannot fit.
    public func write(_ message: String) {
        let messageByteCount = message.utf8.count
        let fullRecordByteCount = UInt64(messageByteCount) + 1
        guard messageByteCount < maxRecordBytes else {
            condition.lock()
            if accepting { accountDropLocked(bytes: fullRecordByteCount) }
            condition.unlock()
            return
        }

        var bytes = Data(message.utf8)
        bytes.append(0x0A)
        guard bytes.count <= maxBytes else {
            condition.lock()
            if accepting { accountDropLocked(bytes: fullRecordByteCount) }
            condition.unlock()
            return
        }

        condition.lock()
        guard accepting else {
            condition.unlock()
            return
        }
        guard records.count < maxRecords, bytes.count <= maxBytes - queuedBytes else {
            accountDropLocked(bytes: fullRecordByteCount)
            condition.unlock()
            return
        }
        records.append(Record(bytes: bytes))
        queuedBytes += bytes.count
        condition.signal()
        condition.unlock()
    }

    /// Stops admission and drains until the deadline, then cancels any blocked sink write.
    public func close(timeout: TimeInterval) {
        precondition(timeout.isFinite && timeout >= 0, "timeout must be finite and nonnegative")
        let deadline = Date().addingTimeInterval(timeout)

        condition.lock()
        if workerFinished || forcedClose {
            condition.unlock()
            return
        }
        accepting = false
        closeRequested = true
        condition.broadcast()
        while !workerFinished {
            if !condition.wait(until: deadline) { break }
        }
        if workerFinished {
            condition.unlock()
            return
        }

        if forcedClose {
            condition.unlock()
            return
        }
        forcedClose = true
        discardQueuedRecordsLocked()
        let shouldCloseSink = !sinkCloseClaimed
        sinkCloseClaimed = true
        condition.broadcast()
        condition.unlock()

        sink.cancelBlockedWrite()
        if shouldCloseSink { sink.close() }
    }

    public var snapshot: EngineDiagnosticSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return EngineDiagnosticSnapshot(
            queuedRecords: records.count,
            queuedBytes: queuedBytes,
            droppedRecords: droppedRecords,
            droppedBytes: droppedBytes
        )
    }

    private func writerLoop() {
        while true {
            condition.lock()
            while records.isEmpty && pendingDroppedRecords == 0 && !closeRequested && !forcedClose {
                condition.wait()
            }
            if forcedClose {
                condition.unlock()
                finishWorker()
                return
            }

            let work: Work
            if pendingDroppedRecords > 0 {
                let marker = Self.overflowMarker(
                    droppedRecords: pendingDroppedRecords,
                    droppedBytes: pendingDroppedBytes
                )
                pendingDroppedRecords = 0
                pendingDroppedBytes = 0
                work = .overflow(marker)
            } else if !records.isEmpty {
                let record = records.removeFirst()
                queuedBytes -= record.bytes.count
                work = .record(record.bytes)
            } else {
                // Closing was requested and both ordinary records and overflow reports drained.
                condition.unlock()
                finishWorker()
                return
            }
            condition.unlock()

            do {
                try writeCompletely(work.bytes)
            } catch {
                handleWriteFailure(work)
                finishWorker()
                return
            }
        }
    }

    private func writeCompletely(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let written = try bytes.withUnsafeBytes { buffer in
                try sink.write(UnsafeRawBufferPointer(rebasing: buffer[offset...]))
            }
            let remaining = bytes.count - offset
            guard written > 0, written <= remaining else {
                throw EngineSinkError.failed("sink reported \(written) bytes written")
            }
            offset += written
        }
    }

    private func handleWriteFailure(_ work: Work) {
        condition.lock()
        accepting = false
        closeRequested = true
        forcedClose = true
        if case let .record(bytes) = work {
            accountDropLocked(bytes: UInt64(bytes.count))
        }
        discardQueuedRecordsLocked()
        condition.broadcast()
        condition.unlock()
    }

    private func finishWorker() {
        condition.lock()
        let shouldCloseSink = !sinkCloseClaimed
        sinkCloseClaimed = true
        condition.unlock()

        if shouldCloseSink { sink.close() }

        condition.lock()
        workerFinished = true
        condition.broadcast()
        condition.unlock()
    }

    private func discardQueuedRecordsLocked() {
        for record in records { accountDropLocked(bytes: UInt64(record.bytes.count)) }
        records.removeAll(keepingCapacity: false)
        queuedBytes = 0
    }

    private func accountDropLocked(bytes: UInt64) {
        droppedRecords = Self.saturatingAdd(droppedRecords, 1)
        droppedBytes = Self.saturatingAdd(droppedBytes, bytes)
        pendingDroppedRecords = Self.saturatingAdd(pendingDroppedRecords, 1)
        pendingDroppedBytes = Self.saturatingAdd(pendingDroppedBytes, bytes)
        condition.signal()
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func overflowMarker(droppedRecords: UInt64, droppedBytes: UInt64) -> Data {
        Data("engine diagnostics overflow: dropped_records=\(droppedRecords) dropped_bytes=\(droppedBytes)\n".utf8)
    }
}
