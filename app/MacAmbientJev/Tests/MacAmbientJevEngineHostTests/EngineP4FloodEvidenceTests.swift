import Foundation
import Testing
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

@Suite struct EngineP4FloodEvidenceTests {
    @Test func productionStdoutReliableRecordBound() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let sink = ScriptedSink(blocked: true)
            let transport = EngineTransport(source: ScriptedSource(), sink: sink, limits: .production)
            transport.start()
            defer { transport.close() }

            let successful = SuccessfulSendCount()
            let producer = Task(executorPreference: executor) {
                for rawID in 1...1_000 {
                    let id = try EngineID(UInt64(rawID))
                    try await transport.send(
                        .accepted(EngineAcceptedPayload(command: .stateGet)), requestID: id
                    )
                    successful.increment()
                }
            }

            try await waitUntil("production writer to enter blocked stdout") { sink.enteredWrites == 1 }
            let blockedAt = DispatchTime.now().uptimeNanoseconds
            try await waitUntil("129 reliable sends at the production record bound") { successful.value == 129 }
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(successful.value == 129)
            #expect(sink.received.isEmpty)
            let blockedSeconds = Double(DispatchTime.now().uptimeNanoseconds - blockedAt) / 1_000_000_000
            #expect(blockedSeconds < 5)

            sink.release()
            try await producer.value
            await transport.drain()

            let outputs = try sink.outputs()
            let expectedIDs = (1...1_000).map(String.init)
            #expect(successful.value == 1_000)
            #expect(outputs.count == 1_000)
            #expect(outputs.map { $0.requestID?.rawValue } == expectedIDs)
            #expect(outputs.map { $0.sequence.rawValue } == expectedIDs)
            #expect(outputs.allSatisfy { if case .accepted = $0.event { true } else { false } })

            print("P4_BOUND stdout_records queued=128 inflight=1 attempted=1000 accepted_at_bound=129 final=1000 exactly_once_ordered=true blocked_seconds=\(blockedSeconds)")
        }
    }

    @Test func productionStdoutReliableByteBound() async throws {
        let executor = TransportTestExecutor()
        try await withTaskExecutorPreference(executor) {
            let cap = EngineTransportLimits.production.maxQueuedBytes
            let message = "日本語: " + String(repeating: "x", count: 500_000)

            func failure(requestID: EngineID) throws -> EngineFailure {
                try EngineFailure(
                    code: .internalError, message: message, stage: .maintenance,
                    requestID: requestID, sessionID: nil, severity: .error,
                    recoveryAction: .retry, details: [], cleanupErrors: []
                )
            }

            var encodedSizes: [Int: Int] = [:]
            for rawID in 1...64 {
                let id = try EngineID(UInt64(rawID))
                let output = try EngineOutput(
                    version: 1, sequence: id, requestID: id, event: .error(try failure(requestID: id))
                )
                encodedSizes[rawID] = try EngineCodec.encodeOutput(output).count
            }

            var expectedQueuedBytes = 0
            var expectedQueuedRecords = 0
            var nextRecordBytes = 0
            for rawID in 2...64 {
                let size = try #require(encodedSizes[rawID])
                if expectedQueuedBytes + size > cap {
                    nextRecordBytes = size
                    break
                }
                expectedQueuedBytes += size
                expectedQueuedRecords += 1
            }
            #expect(expectedQueuedRecords > 0)
            #expect(nextRecordBytes > cap - expectedQueuedBytes)

            let sink = ScriptedSink(blocked: true)
            let transport = EngineTransport(source: ScriptedSource(), sink: sink, limits: .production)
            transport.start()
            defer { transport.close() }

            let successful = SuccessfulSendCount()
            let producer = Task(executorPreference: executor) {
                for rawID in 1...64 {
                    let id = try EngineID(UInt64(rawID))
                    try await transport.send(.error(try failure(requestID: id)), requestID: id)
                    successful.increment()
                }
            }

            try await waitUntil("production writer to enter blocked large-record stdout") { sink.enteredWrites == 1 }
            let blockedAt = DispatchTime.now().uptimeNanoseconds
            let expectedSuccessfulAtBound = expectedQueuedRecords + 1
            try await waitUntil("large reliable sends to fill the production byte bound") {
                successful.value == expectedSuccessfulAtBound
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(successful.value == expectedSuccessfulAtBound)
            #expect(sink.received.isEmpty)
            let blockedSeconds = Double(DispatchTime.now().uptimeNanoseconds - blockedAt) / 1_000_000_000
            #expect(blockedSeconds < 5)

            sink.release()
            try await producer.value
            await transport.drain()

            let outputs = try sink.outputs()
            let expectedIDs = (1...64).map(String.init)
            var expectedWireBytes = 0
            for rawID in 1...64 {
                let size = try #require(encodedSizes[rawID])
                expectedWireBytes += size
            }
            #expect(successful.value == 64)
            #expect(outputs.count == 64)
            #expect(outputs.map { $0.requestID?.rawValue } == expectedIDs)
            #expect(outputs.map { $0.sequence.rawValue } == expectedIDs)
            #expect(outputs.allSatisfy {
                guard case let .error(value) = $0.event else { return false }
                return value.message == message && value.requestID == $0.requestID
            })
            #expect(sink.received.count == expectedWireBytes)

            print("P4_BOUND stdout_bytes cap=\(cap) queued_records=\(expectedQueuedRecords) queued_bytes=\(expectedQueuedBytes) next_record_bytes=\(nextRecordBytes) inflight=1 attempted=64 accepted_at_bound=\(expectedSuccessfulAtBound) final=64 intact=true blocked_seconds=\(blockedSeconds)")
        }
    }

    @Test func stdinFramerEnforcesExactMaximumLineBytes() throws {
        let limit = EngineLineFramer.maxLineBytes
        let validRequest = Data(String(requestLine(1, "hello").dropLast()).utf8)
        var paddedLine = validRequest
        paddedLine.append(contentsOf: repeatElement(UInt8(0x20), count: limit - validRequest.count))
        #expect(paddedLine.count == limit)

        var framer = EngineLineFramer()
        var peakBufferedBytes = 0
        var records: [Data] = []
        var offset = 0
        while offset < paddedLine.count {
            let end = min(offset + 4_096, paddedLine.count)
            records += try framer.append(Data(paddedLine[offset..<end]))
            peakBufferedBytes = max(peakBufferedBytes, framer.bufferedByteCount)
            #expect(framer.bufferedByteCount <= limit)
            offset = end
        }
        #expect(records.isEmpty)
        #expect(framer.bufferedByteCount == limit)
        records += try framer.append(Data([0x0A]))
        #expect(framer.bufferedByteCount == 0)
        #expect(records.count == 1)
        let decoded = try EngineCodec.decodeRequest(try #require(records.first))
        #expect(decoded.requestID.value == 1)
        #expect(decoded.command.name == .hello)

        var overflowingFramer = EngineLineFramer()
        offset = 0
        while offset < paddedLine.count {
            let end = min(offset + 4_096, paddedLine.count)
            _ = try overflowingFramer.append(Data(paddedLine[offset..<end]))
            peakBufferedBytes = max(peakBufferedBytes, overflowingFramer.bufferedByteCount)
            #expect(overflowingFramer.bufferedByteCount <= limit)
            offset = end
        }
        #expect(overflowingFramer.bufferedByteCount == limit)
        do {
            _ = try overflowingFramer.append(Data([0x20]))
            Issue.record("the byte beyond the maximum line size must fail")
        } catch let error as EngineProtocolError {
            #expect(error == .lineTooLong)
        }
        #expect(overflowingFramer.bufferedByteCount == 0)
        do {
            _ = try overflowingFramer.append(Data([0x20]))
            Issue.record("an overlong line must leave the framer closed")
        } catch let error as EngineProtocolError {
            #expect(error == .closedFramer)
        }

        #expect(peakBufferedBytes == limit)
        print("P4_BOUND stdin_line_bytes limit=\(limit) peak=\(peakBufferedBytes) attempted=\(limit + 1) complete_valid_requests=1 overflow=lineTooLong poisoned=true")
    }

    @MainActor
    @Test func productionAdmissionBoundsFloodAndReservesControls() async throws {
        let harness = EngineHarness(limits: .production, admission: .production)
        harness.fake.heldCommands = ["state.get", "recording.stop"]
        harness.start()
        harness.send(1, "hello")
        try await harness.waitForOutputs("hello completed before admission flood") { outputs in
            outputs.contains { $0.requestID?.value == 1 && { if case .completed = $0.event { true } else { false } }($0) }
        }

        for id in 2...1_001 {
            harness.send(UInt64(id), "state.get")
        }
        let sink = harness.sink
        try await waitUntil("every flood request to receive its admission reply") {
            sink.received.filter { $0 == 0x0A }.count >= 1_003
        }
        try await waitOnMain("14 admitted state handlers held") { harness.fake.heldCount == 14 }

        let floodOutputs = try harness.outputs.filter {
            guard let requestID = $0.requestID?.value else { return false }
            return (2...1_001).contains(Int(requestID))
        }
        let acceptedFloodIDs = Set(floodOutputs.compactMap { output -> UInt64? in
            if case .accepted = output.event { output.requestID?.value } else { nil }
        })
        let busyFloodIDs = Set(floodOutputs.compactMap { output -> UInt64? in
            if case let .error(failure) = output.event, failure.code == .busy { output.requestID?.value } else { nil }
        })
        #expect(acceptedFloodIDs.count == 14)
        #expect(busyFloodIDs.count == 986)
        #expect(acceptedFloodIDs.isDisjoint(with: busyFloodIDs))
        #expect(acceptedFloodIDs.union(busyFloodIDs) == Set((2...1_001).map(UInt64.init)))
        #expect(harness.fake.calls.filter { $0 == "state.get" }.count == 14)

        harness.send(1_002, "recording.stop", payload: "{\"session_id\":\"session-1\"}")
        try await waitOnMain("reserved recording.stop handler held") { harness.fake.heldCount == 15 }
        try await waitUntil("reserved recording.stop acceptance to reach stdout") {
            sink.received.filter { $0 == 0x0A }.count >= 1_004
        }
        let maximumHeldHandlers = harness.fake.heldCount
        #expect(maximumHeldHandlers == 15)

        harness.send(1_003, "shutdown")
        let exit = await harness.exit()
        #expect(exit == .shutdownRequested)
        #expect(exit.processExitCode == 0)
        #expect(harness.fake.shutdownReasons == [.requested])

        func requestEvents(_ outputs: [EngineOutput]) -> [UInt64: [String]] {
            var events: [UInt64: [String]] = [:]
            for output in outputs {
                guard let id = output.requestID?.value else { continue }
                switch output.event {
                case .accepted:
                    events[id, default: []].append("accepted")
                case .completed:
                    events[id, default: []].append("completed")
                case let .error(failure):
                    events[id, default: []].append("error:\(failure.code.rawValue)")
                case .progress, .state, .ready, .rows:
                    break
                }
            }
            return events
        }

        let afterShutdown = try harness.outputs
        let shutdownEvents = requestEvents(afterShutdown)
        #expect(shutdownEvents[1] == ["accepted", "completed"])
        for rawID in 2...1_001 {
            let id = UInt64(rawID)
            if acceptedFloodIDs.contains(id) {
                #expect(shutdownEvents[id] == ["accepted", "error:cancelled"])
            } else {
                #expect(shutdownEvents[id] == ["error:busy"])
            }
        }
        #expect(shutdownEvents[1_002] == ["accepted", "error:cancelled"])
        #expect(shutdownEvents[1_003] == ["accepted", "completed"])

        harness.fake.heldCommands = []
        harness.fake.releaseAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterRelease = try harness.outputs
        let releaseEvents = requestEvents(afterRelease)
        for id in acceptedFloodIDs {
            #expect(releaseEvents[id] == ["accepted", "error:cancelled"])
        }
        #expect(releaseEvents[1_002] == ["accepted", "error:cancelled"])
        let lateCompleted = afterRelease.filter { output in
            guard let id = output.requestID?.value else { return false }
            return (acceptedFloodIDs.contains(id) || id == 1_002) && {
                if case .completed = output.event { true } else { false }
            }()
        }
        #expect(lateCompleted.isEmpty)

        print("P4_BOUND admission attempted=1000 accepted_state=14 busy=986 held_state=14 reserved_stop=accepted held_total=\(maximumHeldHandlers) shutdown=accepted exit=\(exit.processExitCode) admitted_envelopes_at_shutdown=16 max_handler_concurrent=\(maximumHeldHandlers) cancelled_terminals=15 late_completed=0")
    }
}
