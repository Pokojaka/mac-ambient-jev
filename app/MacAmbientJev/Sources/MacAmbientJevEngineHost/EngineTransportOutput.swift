import Foundation
import MacAmbientJevEngineProtocol

public enum EngineWriteFailure: Error, Equatable, Sendable {
    case deadlineExceeded
    case brokenPipe
    case failed(String)
}

public enum EngineTransportError: Error, Equatable, Sendable {
    /// The transport was closed on purpose.
    case closed
    /// The writer failed; the engine must stop capture and exit non-zero.
    case writeFailed(EngineWriteFailure)
    /// Replaceable events could not be queued within their budget and no older one could be coalesced.
    case replaceableOverflow
    case encoding(String)
}

/// The single stdout writer: one dedicated thread writes one LF record at a time, handling partial
/// writes, while a watchdog thread enforces the no-progress write deadline.
///
/// Capacity: `maxQueuedRecords` / `maxQueuedBytes` in total. Replaceable events (`state`, `progress`,
/// `rows`) may occupy only the part not reserved for terminal and control messages. When that part is
/// full the oldest `progress` is dropped, then the oldest session's queued `rows` become one
/// `reload_required` record. `accepted`, `completed`, `error` and `ready` are never coalesced or
/// dropped; a sender that finds the queue full suspends until the writer frees room.
final class EngineOutputChannel: @unchecked Sendable {
    private enum Kind: Equatable {
        case reliable
        case state
        case progress(key: String)
        case rows(session: String, revision: EngineID, isReload: Bool)

        var isReplaceable: Bool {
            if case .reliable = self { return false }
            return true
        }
    }

    private struct Record {
        let data: Data
        let kind: Kind

        func isRows(of session: String) -> Bool {
            if case let .rows(queued, _, _) = kind { return queued == session }
            return false
        }
    }

    private let sink: EngineByteSink
    private let limits: EngineTransportLimits
    private let onFailure: @Sendable (EngineWriteFailure) -> Void
    private let condition = NSCondition()

    private var records: [Record] = []
    private var queuedBytes = 0
    private var sequence = EngineSequenceGenerator()
    private var writing = false
    private var progressAt: UInt64 = 0
    private var failure: EngineWriteFailure?
    private var stopped = false
    private var started = false
    private var spaceWaiters: [CheckedContinuation<Bool, Error>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(sink: EngineByteSink, limits: EngineTransportLimits, onFailure: @escaping @Sendable (EngineWriteFailure) -> Void) {
        self.sink = sink
        self.limits = limits
        self.onFailure = onFailure
    }

    func start() {
        condition.lock()
        precondition(!started, "output channel already started")
        started = true
        condition.unlock()
        Thread.detachNewThread { [self] in writerLoop() }
        Thread.detachNewThread { [self] in watchdogLoop() }
    }

    // MARK: Sending

    func sendReliable(_ event: EngineEvent, requestID: EngineID?) async throws {
        while true {
            let appended = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                appendOrWait(event, requestID: requestID, continuation: continuation)
            }
            if appended { return }
        }
    }

    func sendReplaceable(_ event: EngineEvent, requestID: EngineID?) throws {
        condition.lock()
        defer { condition.unlock() }
        try throwIfClosedLocked()
        switch event {
        case .state:
            removeLocked { $0.kind == .state }
            guard try appendReplaceableLocked(event, requestID: requestID, kind: .state) else {
                throw EngineTransportError.replaceableOverflow
            }
        case let .progress(payload):
            let key = "\(payload.sessionID ?? "-")/\(payload.stage.rawValue)"
            removeLocked { $0.kind == .progress(key: key) }
            guard try appendReplaceableLocked(event, requestID: requestID, kind: .progress(key: key)) else {
                throw EngineTransportError.replaceableOverflow
            }
        case let .rows(payload):
            try sendRowsLocked(payload, event: event, requestID: requestID)
        case .ready, .accepted, .completed, .error:
            preconditionFailure("\(event.name) is not replaceable")
        }
        condition.broadcast()
    }

    /// Returns when everything queued before the call has been written, or the writer failed.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            condition.lock()
            if failure != nil || stopped || (records.isEmpty && !writing) {
                condition.unlock()
                continuation.resume()
            } else {
                drainWaiters.append(continuation)
                condition.unlock()
            }
        }
    }

    /// Stops both threads and closes the sink. Queued records that were not written are discarded.
    func close() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        let (space, drains) = takeWaitersLocked()
        records.removeAll()
        queuedBytes = 0
        condition.broadcast()
        condition.unlock()
        sink.cancelBlockedWrite()
        sink.close()
        for waiter in space { waiter.resume(throwing: EngineTransportError.closed) }
        for waiter in drains { waiter.resume() }
    }

    // MARK: Queue mutation (condition held)

    private func appendOrWait(_ event: EngineEvent, requestID: EngineID?, continuation: CheckedContinuation<Bool, Error>) {
        condition.lock()
        do {
            try throwIfClosedLocked()
            let (data, next) = try encode(event, requestID: requestID)
            if records.count < limits.maxQueuedRecords, queuedBytes + data.count <= limits.maxQueuedBytes || records.isEmpty {
                sequence = next
                commitLocked(Record(data: data, kind: .reliable))
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: true)
            } else {
                spaceWaiters.append(continuation)
                condition.unlock()
            }
        } catch {
            condition.unlock()
            continuation.resume(throwing: error)
        }
    }

    private func sendRowsLocked(_ payload: EngineRowsPayload, event: EngineEvent, requestID: EngineID?) throws {
        let session = payload.sessionID
        if payload.kind == .reloadRequired {
            removeLocked { $0.isRows(of: session) }
            guard try appendReplaceableLocked(event, requestID: requestID, kind: .rows(session: session, revision: payload.revision, isReload: true)) else {
                throw EngineTransportError.replaceableOverflow
            }
            return
        }
        if try appendReplaceableLocked(event, requestID: requestID, kind: .rows(session: session, revision: payload.revision, isReload: false)) {
            return
        }
        try replaceRowsWithReloadLocked(session: session, newestRevision: payload.revision, requestID: requestID)
    }

    /// Frees room for one more replaceable record, then appends it. Returns false when nothing could be evicted.
    private func appendReplaceableLocked(_ event: EngineEvent, requestID: EngineID?, kind: Kind) throws -> Bool {
        let estimate = try encode(event, requestID: requestID).0.count + 32
        while !replaceableFitsLocked(extraBytes: estimate) {
            guard try evictOneLocked() else { return false }
        }
        let data = try encodeLocked(event, requestID: requestID)
        commitLocked(Record(data: data, kind: kind))
        return true
    }

    private func replaceableFitsLocked(extraBytes: Int) -> Bool {
        var count = 0
        var bytes = 0
        for record in records where record.kind.isReplaceable {
            count += 1
            bytes += record.data.count
        }
        return count + 1 <= limits.replaceableRecordLimit && bytes + extraBytes <= limits.replaceableByteLimit
    }

    private func evictOneLocked() throws -> Bool {
        if let index = records.firstIndex(where: { if case .progress = $0.kind { true } else { false } }) {
            queuedBytes -= records[index].data.count
            records.remove(at: index)
            return true
        }
        if let session = records.compactMap({ record -> String? in
            if case let .rows(session, _, isReload) = record.kind, !isReload { return session }
            return nil
        }).first {
            let revision = records.compactMap { record -> EngineID? in
                if case let .rows(queued, revision, _) = record.kind, queued == session { return revision }
                return nil
            }.max()!
            try replaceRowsWithReloadLocked(session: session, newestRevision: revision, requestID: nil)
            return true
        }
        return false
    }

    private func replaceRowsWithReloadLocked(session: String, newestRevision: EngineID, requestID: EngineID?) throws {
        removeLocked { $0.isRows(of: session) }
        let reload: EngineRowsPayload
        do {
            reload = try EngineRowsPayload(
                sessionID: session,
                revision: newestRevision,
                kind: .reloadRequired,
                rows: [],
                removedRowIDs: [],
                nextCursor: nil
            )
        } catch {
            throw EngineTransportError.encoding(String(describing: error))
        }
        let event = EngineEvent.rows(reload)
        let data = try encodeLocked(event, requestID: requestID)
        commitLocked(Record(data: data, kind: .rows(session: session, revision: newestRevision, isReload: true)))
    }

    private func removeLocked(where matches: (Record) -> Bool) {
        var kept: [Record] = []
        kept.reserveCapacity(records.count)
        for record in records {
            if matches(record) {
                queuedBytes -= record.data.count
            } else {
                kept.append(record)
            }
        }
        records = kept
    }

    private func commitLocked(_ record: Record) {
        records.append(record)
        queuedBytes += record.data.count
    }

    /// Encodes with the next sequence without consuming it; the caller assigns the returned generator on commit.
    private func encode(_ event: EngineEvent, requestID: EngineID?) throws -> (Data, EngineSequenceGenerator) {
        var candidate = sequence
        do {
            let output = try EngineOutput(version: 1, sequence: try candidate.next(), requestID: requestID, event: event)
            return (try EngineCodec.encodeOutput(output), candidate)
        } catch {
            throw EngineTransportError.encoding(String(describing: error))
        }
    }

    private func encodeLocked(_ event: EngineEvent, requestID: EngineID?) throws -> Data {
        let (data, next) = try encode(event, requestID: requestID)
        sequence = next
        return data
    }

    private func throwIfClosedLocked() throws {
        if let failure { throw EngineTransportError.writeFailed(failure) }
        if stopped { throw EngineTransportError.closed }
    }

    private func takeWaitersLocked() -> ([CheckedContinuation<Bool, Error>], [CheckedContinuation<Void, Never>]) {
        let space = spaceWaiters
        let drains = drainWaiters
        spaceWaiters = []
        drainWaiters = []
        return (space, drains)
    }

    // MARK: Writer and watchdog

    private func writerLoop() {
        while true {
            condition.lock()
            while records.isEmpty && !stopped && failure == nil {
                condition.wait()
            }
            if stopped || failure != nil {
                condition.unlock()
                return
            }
            let record = records.removeFirst()
            queuedBytes -= record.data.count
            writing = true
            progressAt = Self.now()
            let space = spaceWaiters
            spaceWaiters = []
            condition.broadcast()
            condition.unlock()
            for waiter in space { waiter.resume(returning: false) }

            do {
                try write(record.data)
            } catch let error as EngineSinkError {
                switch error {
                case .cancelled:
                    condition.lock()
                    let intentional = stopped || failure != nil
                    condition.unlock()
                    if !intentional { fail(.failed("write cancelled unexpectedly")) }
                case .brokenPipe:
                    fail(.brokenPipe)
                case let .failed(reason):
                    fail(.failed(reason))
                }
                return
            } catch {
                fail(.failed(String(describing: error)))
                return
            }

            condition.lock()
            writing = false
            let idle = records.isEmpty
            let drains = idle ? drainWaiters : []
            if idle { drainWaiters = [] }
            condition.broadcast()
            condition.unlock()
            for waiter in drains { waiter.resume() }
        }
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = try data.withUnsafeBytes { buffer in
                try sink.write(UnsafeRawBufferPointer(rebasing: buffer[offset...]))
            }
            guard written > 0, offset + written <= data.count else {
                throw EngineSinkError.failed("sink reported \(written) bytes written")
            }
            offset += written
            condition.lock()
            progressAt = Self.now()
            condition.broadcast()
            condition.unlock()
        }
    }

    private func watchdogLoop() {
        condition.lock()
        while !stopped && failure == nil {
            guard writing else {
                condition.wait()
                continue
            }
            let elapsed = Self.now() &- progressAt
            if elapsed >= limits.writeDeadlineNanoseconds {
                condition.unlock()
                fail(.deadlineExceeded)
                return
            }
            let remaining = Double(limits.writeDeadlineNanoseconds - elapsed) / 1_000_000_000
            _ = condition.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        condition.unlock()
    }

    /// The first failure wins. Cancels the blocked write, closes the connection and tells the transport owner.
    private func fail(_ reason: EngineWriteFailure) {
        condition.lock()
        guard failure == nil, !stopped else {
            condition.unlock()
            return
        }
        failure = reason
        records.removeAll()
        queuedBytes = 0
        let (space, drains) = takeWaitersLocked()
        condition.broadcast()
        condition.unlock()
        sink.cancelBlockedWrite()
        sink.close()
        for waiter in space { waiter.resume(throwing: EngineTransportError.writeFailed(reason)) }
        for waiter in drains { waiter.resume() }
        onFailure(reason)
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
