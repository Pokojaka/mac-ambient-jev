import Foundation
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevTestSupport

struct TestTimeout: Error, CustomStringConvertible {
    let description: String
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
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
        changes.signal()
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

/// In-memory sink with a blockable gate and cancellation like a real pipe.
/// `changes` signals after every write call enters, after every accepted write, and on cancel and close.
final class ScriptedSink: EngineByteSink, @unchecked Sendable {
    let changes = ChangeSignal()
    private let condition = NSCondition()
    private var storage = Data()
    private var blocked: Bool
    private var cancelled = false
    private var isClosed = false
    private var failure: EngineSinkError?
    private var cancels = 0
    private var entered = 0
    init(blocked: Bool = false) {
        self.blocked = blocked
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        condition.lock()
        entered += 1
        changes.signal()
        while blocked && !cancelled && !isClosed { condition.wait() }
        if cancelled || isClosed {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        if let failure {
            condition.unlock()
            throw failure
        }
        let count = bytes.count
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
        condition.broadcast()
        condition.unlock()
        changes.signal()
        return count
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
        cancels += 1
        condition.broadcast()
        condition.unlock()
        changes.signal()
    }

    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
        changes.signal()
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
        recording: nil, queue: [], failures: [],
        presentation: try EnginePresentationState(
            recordingStatusText: "待機中", recordingTone: .neutral, preparationPhase: .ready,
            preparationStatusText: nil, recoveryStatusText: nil, processingStatusText: nil,
            liveFailureNotices: [], silenceWarningActive: false, silenceWarningText: nil,
            audioGapCount: 0, audioGapText: nil, processingIndicator: .idle
        )
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

final class ManualWriteDeadlineClock: EngineWriteDeadlineClock, @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var time: UInt64 = 0
    private var lastObservedTime: UInt64 = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func wait(on condition: NSCondition, remainingNanoseconds: UInt64) {
        lock.lock()
        lastObservedTime = time
        lock.unlock()
        changes.signal()
        condition.wait()
    }

    func advance(by nanoseconds: UInt64) {
        lock.lock()
        time &+= nanoseconds
        lock.unlock()
    }

    var observedTime: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return lastObservedTime
    }
}
