import Foundation
import Testing
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

private func makeTransport(_ sink: ScriptedSink, limits: EngineTransportLimits = testLimits()) -> EngineTransport {
    let transport = EngineTransport(source: ScriptedSource(), sink: sink, limits: limits)
    transport.start()
    return transport
}

private func blockedWriter(_ sink: ScriptedSink) async throws {
    try await waitUntil("the writer to block in the sink") { sink.enteredWrites >= 1 }
}

private func accepted(_ command: EngineCommandName = .stateGet) -> EngineEvent {
    .accepted(EngineAcceptedPayload(command: command))
}

private func firstWriteFailure(_ transport: EngineTransport) async -> EngineWriteFailure? {
    for await event in transport.events {
        if case let .writeFailed(failure) = event { return failure }
    }
    return nil
}

@Suite struct EngineTransportOutputTests {
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
            let sink = ScriptedSink(blocked: true)
            let transport = makeTransport(sink)
            defer { transport.close() }
            for revision in 1...200 {
                try transport.sendReplaceable(try stateEvent(revision: UInt64(revision)), requestID: nil)
            }
            try await transport.send(accepted(), requestID: EngineID(1))
            sink.release()
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
            let sink = ScriptedSink(blocked: true)
            let transport = makeTransport(sink)
            defer { transport.close() }
            try transport.sendReplaceable(try progressEvent(session: "a", stage: .asr, completed: 1), requestID: nil)
            try await blockedWriter(sink)
            for completed in 2...50 {
                try transport.sendReplaceable(try progressEvent(session: "a", stage: .asr, completed: UInt64(completed)), requestID: nil)
                try transport.sendReplaceable(try progressEvent(session: "b", stage: .asr, completed: UInt64(completed)), requestID: nil)
            }
            sink.release()
            await transport.drain()
            let progress = try sink.outputs().compactMap { output -> (String?, UInt64)? in
                if case let .progress(payload) = output.event { (payload.sessionID, payload.completedUnits) } else { nil }
            }
            #expect(progress.filter { $0.0 == "b" }.map(\.1) == [50])
            #expect(progress.filter { $0.0 == "a" }.last?.1 == 50)
            #expect(progress.count <= 3)
        }
    }

    @Test func rowChangesBeyondTheReplaceableBudgetBecomeOneReloadRequired() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink(blocked: true)
            let transport = makeTransport(sink, limits: testLimits(maxRecords: 10, reservedRecords: 4))
            defer { transport.close() }
            // The first record is taken by the blocked writer; the next ones fill the 6-record budget.
            try transport.sendReplaceable(try rowsEvent(session: "s", revision: 1, rowIDs: ["r0"]), requestID: nil)
            try await blockedWriter(sink)
            for revision in 2...20 {
                try transport.sendReplaceable(try rowsEvent(session: "s", revision: UInt64(revision), rowIDs: ["r\(revision)"]), requestID: nil)
            }
            sink.release()
            await transport.drain()
            let rows = try sink.outputs().compactMap { output -> EngineRowsPayload? in
                if case let .rows(payload) = output.event { payload } else { nil }
            }
            #expect(rows.count <= 7)
            #expect(rows.contains { $0.kind == .reloadRequired && $0.rows.isEmpty })
            #expect(rows.last?.revision.value == 20)
        }
    }

    @Test func terminalRepliesAreNeverCoalescedOrDroppedAndKeepOrder() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink(blocked: true)
            let transport = makeTransport(sink)
            defer { transport.close() }
            for id in 1...16 {
                try await transport.send(accepted(), requestID: EngineID(UInt64(id)))
                for revision in 1...20 {
                    try transport.sendReplaceable(try stateEvent(revision: UInt64(id * 100 + revision)), requestID: nil)
                }
                try await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
            }
            sink.release()
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
            let sink = ScriptedSink(blocked: true)
            let transport = makeTransport(sink, limits: testLimits(maxRecords: 6, reservedRecords: 2))
            defer { transport.close() }
            let successfulSends = SuccessfulSendCount()
            let sender = Task(executorPreference: executor) {
                for id in 1...20 {
                    try await transport.send(accepted(), requestID: EngineID(UInt64(id)))
                    successfulSends.increment()
                }
            }
            try await blockedWriter(sink)
            try await waitUntil("seven reliable sends to complete") { successfulSends.value == 7 }
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(successfulSends.value == 7)
            #expect(sink.received.isEmpty)
            sink.release()
            try await sender.value
            await transport.drain()
            #expect(successfulSends.value == 20)
            #expect(try sink.outputs().map { $0.requestID?.rawValue } == (1...20).map(String.init))
        }
    }

    @Test func aBlockedWriteFailsAfterTheDeadlineAndCancelsTheSink() async throws {
        let sink = ScriptedSink(blocked: true)
        let transport = makeTransport(sink, limits: testLimits(deadline: 0.2))
        defer { transport.close() }
        try await transport.send(accepted(), requestID: EngineID(1))
        #expect(await firstWriteFailure(transport) == .deadlineExceeded)
        #expect(sink.cancelCount >= 1)
        #expect(sink.closed)
        await #expect(throws: EngineTransportError.writeFailed(.deadlineExceeded)) {
            try await transport.send(accepted(), requestID: EngineID(2))
        }
    }

    @Test func progressInsideAWriteResetsTheDeadline() async throws {
        let sink = ScriptedSink(acceptPerCall: 8, delayPerCall: 0.05)
        let transport = makeTransport(sink, limits: testLimits(deadline: 0.4))
        defer { transport.close() }
        try await transport.send(accepted(), requestID: EngineID(1))
        await transport.drain()
        #expect(try sink.outputs().count == 1)
        #expect(!sink.closed)
    }

    @Test func aBrokenPipeIsReported() async throws {
        let sink = ScriptedSink()
        sink.failNextWrites(with: .brokenPipe)
        let transport = makeTransport(sink)
        defer { transport.close() }
        try await transport.send(accepted(), requestID: EngineID(1))
        #expect(await firstWriteFailure(transport) == .brokenPipe)
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
