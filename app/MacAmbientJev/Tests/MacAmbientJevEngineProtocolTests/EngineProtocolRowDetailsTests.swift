import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolRowDetailsTests {
    @Test func rowDetailsRoundTrip() throws {
        let revision = try EngineID(1)
        let page = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: "r", clauseState: .awaitingNextSegment,
            clauseStateText: "発話文: 続き待ち"
        )
        #expect(try roundTrip(page) == page)
    }

    @Test func codecRejectsOversizedFullRowDetailsEnvelope() throws {
        let revision = try EngineID(1)
        let oversizedRowID = String(repeating: "x", count: EngineLineFramer.maxLineBytes)
        let oversizedPage = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: oversizedRowID, clauseState: .classified,
            clauseStateText: "発話文: 判定済み"
        )
        let output = try EngineOutput(
            version: 1, sequence: EngineID(2), requestID: EngineID(1),
            event: .completed(.transcriptRowDetails(oversizedPage))
        )
        #expect(throws: (any Error).self) { try EngineCodec.encodeOutput(output) }

        let oversizedEnvelope = try jsonData([
            "version": 1,
            "sequence": "2",
            "request_id": "1",
            "event": "completed",
            "payload": [
                "command": "transcript.row_details",
                "result": [
                    "session_id": "s",
                    "revision": "1",
                    "row_id": oversizedRowID,
                    "clause_state": "classified",
                    "clause_state_text": "発話文: 判定済み",
                ],
            ],
        ])
        #expect(oversizedEnvelope.count > EngineLineFramer.maxLineBytes)
        #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(oversizedEnvelope) }
    }
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
