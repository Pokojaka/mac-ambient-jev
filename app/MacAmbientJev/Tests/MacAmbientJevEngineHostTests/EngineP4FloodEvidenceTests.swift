import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevTestSupport

@Suite(.timeLimit(.minutes(10))) struct EngineP4FloodEvidenceTests {
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
            let expectedSuccessfulAtBound = expectedQueuedRecords + 1

            let sink = ScriptedSink(blocked: true)
            let successful = SuccessfulSendCount()
            let waitingAtBound = SuccessfulSendCount()
            let transport = EngineTransport(
                source: ScriptedSource(),
                sink: sink,
                limits: .production,
                deadlineClock: ManualWriteDeadlineClock(),
                onReliableWait: {
                    if successful.value == expectedSuccessfulAtBound { waitingAtBound.increment() }
                }
            )
            transport.start()
            defer { transport.close() }
            let producer = Task(executorPreference: executor) {
                for rawID in 1...64 {
                    let id = try EngineID(UInt64(rawID))
                    try await transport.send(.error(try failure(requestID: id)), requestID: id)
                    successful.increment()
                }
            }
            defer { producer.cancel() }

            try await sink.changes.wait("production writer to enter blocked large-record stdout") {
                sink.enteredWrites == 1
            }
            let blockedAt = DispatchTime.now().uptimeNanoseconds
            try await successful.changes.wait("large reliable sends to fill the production byte bound") {
                successful.value == expectedSuccessfulAtBound
            }
            try await waitingAtBound.changes.wait("a reliable send to suspend at the production byte bound") {
                waitingAtBound.value > 0
            }
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

}
