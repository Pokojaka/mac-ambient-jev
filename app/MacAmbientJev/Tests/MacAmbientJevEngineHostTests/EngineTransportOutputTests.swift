import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevTestSupport

private func makeTransport(_ sink: ScriptedSink, limits: EngineTransportLimits = testLimits()) -> EngineTransport {
    let transport = EngineTransport(source: ScriptedSource(), sink: sink, limits: limits)
    transport.start()
    return transport
}

/// A transport whose writer has not started, so a test can fill its queue without a write in flight: the write
/// deadline measures only a writer that cannot drain, never the test's own pace.
private func makeUnstartedTransport(_ sink: ScriptedSink, limits: EngineTransportLimits = testLimits()) -> EngineTransport {
    EngineTransport(source: ScriptedSource(), sink: sink, limits: limits)
}

private func accepted(_ command: EngineCommandName = .stateGet) -> EngineEvent {
    .accepted(EngineAcceptedPayload(command: command))
}

private final class ReliableWaitObservation: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var count = 0

    func record() {
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

private final class WriteFailureObservation: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var observedFailure: EngineWriteFailure?

    func record(_ failure: EngineWriteFailure) {
        lock.lock()
        observedFailure = failure
        lock.unlock()
        changes.signal()
    }

    var value: EngineWriteFailure? {
        lock.lock()
        defer { lock.unlock() }
        return observedFailure
    }
}

private final class SteppedSink: EngineByteSink, @unchecked Sendable {
    let changes = ChangeSignal()
    private let condition = NSCondition()
    private var storage = Data()
    private var entered = 0
    private var permits = 0
    private var cancelled = false
    private var isClosed = false

    func write(_ bytes: UnsafeRawBufferPointer) throws -> Int {
        condition.lock()
        entered += 1
        condition.broadcast()
        condition.unlock()
        changes.signal()

        condition.lock()
        while permits == 0 && !cancelled && !isClosed {
            condition.wait()
        }
        guard !cancelled && !isClosed else {
            condition.unlock()
            throw EngineSinkError.cancelled
        }
        permits -= 1
        let count = min(bytes.count, 8)
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
        condition.unlock()
        changes.signal()
        return count
    }

    func permitOneWrite() {
        condition.lock()
        permits += 1
        condition.broadcast()
        condition.unlock()
    }

    func cancelBlockedWrite() {
        condition.lock()
        cancelled = true
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

    var received: Data {
        condition.lock()
        defer { condition.unlock() }
        return storage
    }

    var enteredWrites: Int {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }

    var cancelCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return cancelled ? 1 : 0
    }

    var closed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isClosed
    }
}

@Suite(.timeLimit(.minutes(10))) struct EngineTransportOutputTests {
    @Test func partialWritesStillProduceWholeLFTerminatedRecords() async throws {
        let sink = ScriptedSink(acceptPerCall: 3)
        let transport = makeTransport(sink)
        defer { transport.close() }
        for id in 1...3 {
            try await transport.send(accepted(), requestID: EngineID(UInt64(id)))
        }
        await transport.drain()
        let outputs = try sink.outputs()
        #expect(outputs.map(\.sequence.rawValue) == ["1", "2", "3"])
        #expect(outputs.map { $0.requestID?.rawValue } == ["1", "2", "3"])
        #expect(sink.received.filter { $0 == 0x0A }.count == 3)
    }

    @Test func replaceableStateIsCoalescedWhileTheConsumerIsSlow() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink()
            let transport = makeUnstartedTransport(sink)
            defer { transport.close() }
            for revision in 1...200 {
                try transport.sendReplaceable(try stateEvent(revision: UInt64(revision)), requestID: nil)
            }
            try await transport.send(accepted(), requestID: EngineID(1))
            transport.start()
            await transport.drain()
            let outputs = try sink.outputs()
            let states = outputs.compactMap { output -> UInt64? in
                if case let .state(state) = output.event { state.revision.value } else { nil }
            }
            #expect(states.count <= 2)
            #expect(states.last == 200)
            #expect(outputs.contains { if case .accepted = $0.event { true } else { false } })
            let sequences = outputs.map(\.sequence.value)
            #expect(sequences == sequences.sorted())
        }
    }

    @Test func progressIsCoalescedPerSessionAndStage() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink()
            let transport = makeUnstartedTransport(sink)
            defer { transport.close() }
            for completed in 1...50 {
                try transport.sendReplaceable(try progressEvent(session: "a", stage: .asr, completed: UInt64(completed)), requestID: nil)
                try transport.sendReplaceable(try progressEvent(session: "b", stage: .asr, completed: UInt64(completed)), requestID: nil)
            }
            transport.start()
            await transport.drain()
            let progress = try sink.outputs().compactMap { output -> (String?, UInt64)? in
                if case let .progress(payload) = output.event { (payload.sessionID, payload.completedUnits) } else { nil }
            }
            #expect(progress.filter { $0.0 == "a" }.map(\.1) == [50])
            #expect(progress.filter { $0.0 == "b" }.map(\.1) == [50])
        }
    }

    @Test func rowChangesBeyondTheReplaceableBudgetBecomeOneReloadRequired() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink()
            let transport = makeUnstartedTransport(sink, limits: testLimits(maxRecords: 10, reservedRecords: 4))
            defer { transport.close() }
            // Twenty row changes exceed the 6-record replaceable budget.
            for revision in 1...20 {
                try transport.sendReplaceable(try rowsEvent(session: "s", revision: UInt64(revision), rowIDs: ["r\(revision)"]), requestID: nil)
            }
            transport.start()
            await transport.drain()
            let rows = try sink.outputs().compactMap { output -> EngineRowsPayload? in
                if case let .rows(payload) = output.event { payload } else { nil }
            }
            #expect(rows.count <= 6)
            #expect(rows.contains { $0.kind == .reloadRequired && $0.rows.isEmpty })
            #expect(rows.last?.revision.value == 20)
        }
    }

    @Test func terminalRepliesAreNeverCoalescedOrDroppedAndKeepOrder() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink()
            let transport = makeUnstartedTransport(sink)
            defer { transport.close() }
            for id in 1...16 {
                try await transport.send(accepted(), requestID: EngineID(UInt64(id)))
                for revision in 1...20 {
                    try transport.sendReplaceable(try stateEvent(revision: UInt64(id * 100 + revision)), requestID: nil)
                }
                try await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
            }
            transport.start()
            await transport.drain()
            let outputs = try sink.outputs()
            let terminals = outputs.compactMap { output -> String? in
                switch output.event {
                case .accepted: "a\(output.requestID!.rawValue)"
                case .completed: "c\(output.requestID!.rawValue)"
                default: nil
                }
            }
            #expect(terminals == (1...16).flatMap { ["a\($0)", "c\($0)"] })
        }
    }

    @Test func aFullQueueSuspendsReliableSendersUntilTheWriterDrains() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink()
            let reliableWaits = ReliableWaitObservation()
            let transport = EngineTransport(
                source: ScriptedSource(),
                sink: sink,
                limits: testLimits(maxRecords: 6, reservedRecords: 2),
                deadlineClock: LiveEngineWriteDeadlineClock(),
                onReliableWait: { reliableWaits.record() }
            )
            defer { transport.close() }
            let successfulSends = SuccessfulSendCount()
            let sender = Task(executorPreference: executor) {
                for id in 1...20 {
                    try await transport.send(accepted(), requestID: EngineID(UInt64(id)))
                    successfulSends.increment()
                }
            }
            try await reliableWaits.changes.wait("a reliable sender waiting on the full queue") { reliableWaits.value > 0 }
            #expect(successfulSends.value == 6)
            #expect(sink.received.isEmpty)
            transport.start()
            try await sender.value
            await transport.drain()
            #expect(successfulSends.value == 20)
            #expect(try sink.outputs().map { $0.requestID?.rawValue } == (1...20).map(String.init))
        }
    }

    @Test func aBlockedWriteFailsAtTheLogicalDeadlineAndCancelsTheSink() async throws {
        let sink = SteppedSink()
        let clock = ManualWriteDeadlineClock()
        let transport = EngineTransport(
            source: ScriptedSource(),
            sink: sink,
            limits: testLimits(deadline: 0.4),
            deadlineClock: clock,
            onReliableWait: {}
        )
        let failure = WriteFailureObservation()
        let failureObserver = Task {
            for await event in transport.events {
                if case let .writeFailed(reason) = event {
                    failure.record(reason)
                    return
                }
            }
        }
        defer {
            transport.close()
            failureObserver.cancel()
        }
        transport.start()
        try await transport.send(accepted(), requestID: EngineID(1))
        try await sink.changes.wait("the blocked sink write to enter") { sink.enteredWrites == 1 }
        transport.advanceWriteDeadlineClock { clock.advance(by: 400_000_000) }
        try await failure.changes.wait("the logical write deadline to fail") { failure.value != nil }
        #expect(failure.value == .deadlineExceeded)
        #expect(sink.cancelCount == 1)
        #expect(sink.closed)
        await #expect(throws: EngineTransportError.writeFailed(.deadlineExceeded)) {
            try await transport.send(accepted(), requestID: EngineID(2))
        }
    }

    @Test func progressInsideAWriteResetsTheDeadline() async throws {
        let sink = SteppedSink()
        let clock = ManualWriteDeadlineClock()
        let deadline: UInt64 = 400_000_000
        let step: UInt64 = 100_000_000
        let transport = EngineTransport(
            source: ScriptedSource(),
            sink: sink,
            limits: testLimits(deadline: 0.4),
            deadlineClock: clock,
            onReliableWait: {}
        )
        defer { transport.close() }
        transport.start()
        try await transport.send(accepted(), requestID: EngineID(1))

        let expectedRecord = try EngineCodec.encodeOutput(
            EngineOutput(version: 1, sequence: EngineID(1), requestID: EngineID(1), event: accepted())
        )
        try await sink.changes.wait("the first stepped write to enter") { sink.enteredWrites == 1 }

        var targetTime: UInt64 = 0
        var currentWrite = 1
        while sink.received.count < expectedRecord.count {
            targetTime += step
            transport.advanceWriteDeadlineClock { clock.advance(by: step) }
            try await clock.changes.wait("the watchdog to observe logical time \(targetTime)") {
                clock.observedTime >= targetTime
            }
            sink.permitOneWrite()
            try await sink.changes.wait("the next stepped write or complete record") {
                sink.enteredWrites > currentWrite || sink.received.count == expectedRecord.count
            }
            currentWrite += 1
        }

        await transport.drain()
        #expect(targetTime > deadline)
        #expect(try ScriptedSink.decodeOutputs(sink.received).count == 1)
        #expect(!sink.closed)
    }

    @Test func aBrokenPipeIsReported() async throws {
        let sink = ScriptedSink()
        sink.failNextWrites(with: .brokenPipe)
        let transport = makeTransport(sink)
        let failure = WriteFailureObservation()
        let failureObserver = Task {
            for await event in transport.events {
                if case let .writeFailed(reason) = event {
                    failure.record(reason)
                    return
                }
            }
        }
        defer {
            transport.close()
            failureObserver.cancel()
        }
        try await transport.send(accepted(), requestID: EngineID(1))
        try await failure.changes.wait("the broken pipe failure") { failure.value != nil }
        #expect(failure.value == .brokenPipe)
        #expect(sink.closed)
    }

    @Test func anOversizedRowIsRejectedWithoutConsumingASequence() async throws {
        let sink = ScriptedSink()
        let transport = makeTransport(sink)
        defer { transport.close() }
        let huge = String(repeating: "あ", count: EngineCodec.maxRowBytes)
        #expect(throws: EngineTransportError.self) {
            try transport.sendReplaceable(try rowsEvent(session: "s", revision: 1, rowIDs: ["r"], text: huge), requestID: nil)
        }
        try await transport.send(accepted(), requestID: EngineID(1))
        await transport.drain()
        #expect(try sink.outputs().map(\.sequence.rawValue) == ["1"])
    }
}
