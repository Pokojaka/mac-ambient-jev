import Foundation
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

struct TestTimeout: Error, CustomStringConvertible {
    let description: String
}

func waitUntil(timeout: TimeInterval = 5, _ what: String, _ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TestTimeout(description: "timed out waiting for \(what)") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
func waitOnMain(timeout: TimeInterval = 5, _ what: String, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw TestTimeout(description: "timed out waiting for \(what)") }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// Serial task executor for tests whose producer tasks must not depend on the cooperative pool.
final class TransportTestExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "TransportTestExecutor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

/// Counts only sends that returned successfully from EngineTransport.send.
final class SuccessfulSendCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

func testLimits(
    maxRecords: Int = 128,
    maxBytes: Int = 8 * 1_048_576,
    reservedRecords: Int = 32,
    reservedBytes: Int = 2 * 1_048_576,
    pendingLines: Int = 32,
    deadline: TimeInterval = 5
) -> EngineTransportLimits {
    EngineTransportLimits(
        maxQueuedRecords: maxRecords,
        maxQueuedBytes: maxBytes,
        reservedControlRecords: reservedRecords,
        reservedControlBytes: reservedBytes,
        maxPendingInputLines: pendingLines,
        readChunkBytes: 4096,
        writeDeadlineNanoseconds: UInt64(deadline * 1_000_000_000)
    )
}

/// In-memory sink with scripted partial writes, a blockable gate and cancellation like a real pipe.
final class ScriptedSink: EngineByteSink, @unchecked Sendable {
    private let condition = NSCondition()
    private var storage = Data()
    private var blocked: Bool
    private var cancelled = false
    private var isClosed = false
    private var failure: EngineSinkError?
    private var cancels = 0
    private var entered = 0
    private let acceptPerCall: Int
    private let delayPerCall: TimeInterval

    init(acceptPerCall: Int = Int.max, delayPerCall: TimeInterval = 0, blocked: Bool = false) {
        self.acceptPerCall = acceptPerCall
        self.delayPerCall = delayPerCall
        self.blocked = blocked
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        condition.lock()
        entered += 1
        while blocked && !cancelled && !isClosed { condition.wait() }
        if cancelled || isClosed {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        if let failure {
            condition.unlock()
            throw failure
        }
        let count = min(bytes.count, acceptPerCall)
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
        condition.broadcast()
        condition.unlock()
        if delayPerCall > 0 { Thread.sleep(forTimeInterval: delayPerCall) }
        return count
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        cancels += 1
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    func block() { setBlocked(true) }
    func release() { setBlocked(false) }

    func failNextWrites(with error: EngineSinkError) {
        condition.lock()
        failure = error
        condition.unlock()
    }

    private func setBlocked(_ value: Bool) {
        condition.lock()
        blocked = value
        condition.broadcast()
        condition.unlock()
    }

    var received: Data {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    /// Calls that reached the sink, including one still blocked.
    var enteredWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var cancelCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return cancels
    }

    var closed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isClosed
    }

    /// Complete LF-terminated records decoded through the strict codec. Fails if any byte is not NDJSON.
    func outputs() throws -> [EngineOutput] {
        try ScriptedSink.decodeOutputs(received)
    }

    static func decodeOutputs(_ data: Data) throws -> [EngineOutput] {
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw TestTimeout(description: "output does not end with LF") }
        var outputs: [EngineOutput] = []
        for line in data.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false) {
            outputs.append(try EngineCodec.decodeOutput(Data(line)))
        }
        return outputs
    }
}

final class ScriptedSource: EngineByteSource, @unchecked Sendable {
    private enum Item {
        case chunk(Data)
        case end
        case failure(String)
    }

    struct ReadFailure: Error { let reason: String }

    private let condition = NSCondition()
    private var items: [Item] = []
    private var isClosed = false

    func feed(_ data: Data) { push(.chunk(data)) }
    func feed(_ text: String) { push(.chunk(Data(text.utf8))) }
    func finish() { push(.end) }
    func fail(_ reason: String) { push(.failure(reason)) }

    private func push(_ item: Item) {
        condition.lock()
        items.append(item)
        condition.broadcast()
        condition.unlock()
    }

    func read(maxByteCount: Int) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while items.isEmpty && !isClosed { condition.wait() }
        if isClosed && items.isEmpty { return Data() }
        switch items.removeFirst() {
        case let .chunk(data): return data
        case .end: return Data()
        case let .failure(reason): throw ReadFailure(reason: reason)
        }
    }

    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }
}

func requestLine(_ id: UInt64, _ command: String, payload: String = "{}") -> String {
    "{\"version\":1,\"request_id\":\"\(id)\",\"command\":\"\(command)\",\"payload\":\(payload)}\n"
}

func stateEvent(revision: UInt64) throws -> EngineEvent {
    .state(try sampleState(revision: revision))
}

func sampleState(revision: UInt64) throws -> EngineState {
    try EngineState(
        revision: EngineID(revision), screen: .idle, setup: .ready, recovery: .completed,
        recording: nil, queue: [], failures: []
    )
}

func sampleReady() throws -> EngineReadyPayload {
    EngineReadyPayload(
        capabilities: try EngineCapabilities(
            sources: [.microphone, .systemAudio], asrSizes: [.small, .large], executionProviders: [.cpu],
            maximumThreads: 4, automaticInputVolume: .none, thermalMonitoring: .none
        ),
        state: try sampleState(revision: 1)
    )
}

func progressEvent(session: String, stage: EngineStage, completed: UInt64) throws -> EngineEvent {
    .progress(try EngineProgressPayload(stage: stage, completedUnits: completed, totalUnits: nil, sessionID: session))
}

func sampleRow(_ id: String, text: String = "テキスト") throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: id, startMS: 0, endMS: 10, text: text, headings: [], clauseState: nil)
}

func rowsEvent(session: String, revision: UInt64, rowIDs: [String], text: String = "テキスト") throws -> EngineEvent {
    .rows(try EngineRowsPayload(
        sessionID: session, revision: EngineID(revision), kind: .changes,
        rows: rowIDs.map { try sampleRow($0, text: text) }, removedRowIDs: [], nextCursor: nil
    ))
}
