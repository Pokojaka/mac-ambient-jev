import Foundation
import Testing
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

private func collect(_ transport: EngineTransport, count: Int) async -> [EngineTransportEvent] {
    var events: [EngineTransportEvent] = []
    for await event in transport.events {
        events.append(event)
        if case .line = event { transport.lineHandled() }
        if events.count == count { break }
    }
    return events
}

private func lines(_ events: [EngineTransportEvent]) -> [String] {
    events.compactMap { event in
        if case let .line(data) = event { String(decoding: data, as: UTF8.self) } else { nil }
    }
}

@Suite struct EngineTransportInputTests {
    private func makeTransport(_ source: ScriptedSource, limits: EngineTransportLimits = testLimits()) -> EngineTransport {
        let transport = EngineTransport(source: source, sink: ScriptedSink(), limits: limits)
        transport.start()
        return transport
    }

    @Test func fragmentedInputIsReassembledIntoRecords() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        let record = requestLine(1, "hello")
        for byte in record.utf8 { source.feed(Data([byte])) }
        source.finish()
        let events = await collect(transport, count: 2)
        #expect(lines(events) == [String(record.dropLast())])
        #expect(events.last == .endOfInput)
    }

    @Test func coalescedRecordsAndCRLFAreSplit() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        source.feed(requestLine(1, "hello") + String(requestLine(2, "state.get").dropLast()) + "\r\n" + String(requestLine(3, "state.get").prefix(10)))
        source.feed(String(requestLine(3, "state.get").dropFirst(10)))
        source.finish()
        let events = await collect(transport, count: 4)
        let actualLines: [String] = lines(events)
        let expectedHello: String = String(requestLine(1, "hello").dropLast())
        let expectedSecondState: String = String(requestLine(2, "state.get").dropLast())
        let expectedThirdState: String = String(requestLine(3, "state.get").dropLast())
        let expectedLines: [String] = [expectedHello, expectedSecondState, expectedThirdState]
        #expect(actualLines == expectedLines)
        #expect(events.last == .endOfInput)
    }

    @Test func bytesAreNotTextTranslated() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        let payload = "{\"input_path\":\"C:\\\\録音\\\\会議.wav\"}"
        let record = requestLine(2, "session.import", payload: payload)
        source.feed(Data(record.utf8))
        let events = await collect(transport, count: 1)
        guard case let .line(data) = events[0] else { Issue.record("no line"); return }
        let request = try EngineCodec.decodeRequest(data)
        guard case let .sessionImport(import_) = request.command else { Issue.record("wrong command"); return }
        #expect(import_.inputPath == "C:\\録音\\会議.wav")
    }

    @Test func partialFinalLineIsAProtocolViolation() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        source.feed(requestLine(1, "hello"))
        source.feed("{\"version\":1")
        source.finish()
        let events = await collect(transport, count: 2)
        #expect(lines(events).count == 1)
        #expect(events.last == .protocolViolation(.partialFinalLine))
    }

    @Test func recordsBeforeABadLineAreStillDelivered() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        source.feed(requestLine(1, "hello") + "{\"a\":1,\"a\":2}\n" + requestLine(2, "state.get"))
        let events = await collect(transport, count: 2)
        #expect(lines(events) == [String(requestLine(1, "hello").dropLast())])
        #expect(events.last == .protocolViolation(.duplicateKey("a")))
    }

    @Test func readFailureIsReported() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source)
        defer { transport.close() }
        source.fail("pipe reset")
        let events = await collect(transport, count: 1)
        guard case let .readFailed(reason) = events[0] else { Issue.record("no failure"); return }
        #expect(reason.contains("pipe reset"))
    }

    @Test func inputLaneBlocksWhenLinesAreNotHandled() async throws {
        let source = ScriptedSource()
        let transport = makeTransport(source, limits: testLimits(pendingLines: 2))
        defer { transport.close() }
        var all = ""
        for id in 1...5 { all += requestLine(UInt64(id), "state.get") }
        source.feed(all)
        var iterator = transport.events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        // Two credits are spent; the third line must wait for lineHandled().
        let third = Task { await iterator.next() }
        try await Task.sleep(nanoseconds: 150_000_000)
        transport.lineHandled()
        let event = await third.value
        guard case .line = event else { Issue.record("third line missing"); return }
    }
}
