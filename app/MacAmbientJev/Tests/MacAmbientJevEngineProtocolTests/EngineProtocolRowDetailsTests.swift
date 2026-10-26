import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolRowDetailsTests {
    @Test func limitsSpanIntervalsAndEnumValuesAreValidated() throws {
        let revision = try EngineID(1)
        #expect(try EngineTranscriptRowDetailsPayload(
            sessionID: "s", revision: revision, rowID: "r", cursor: nil, limit: 1
        ).limit == 1)
        #expect(try EngineTranscriptRowDetailsPayload(
            sessionID: "s", revision: revision, rowID: "r", cursor: nil, limit: 200
        ).limit == 200)
        #expect(throws: (any Error).self) {
            try EngineTranscriptRowDetailsPayload(sessionID: "s", revision: revision, rowID: "r", cursor: nil, limit: 0)
        }
        #expect(throws: (any Error).self) {
            try EngineTranscriptRowDetailsPayload(sessionID: "s", revision: revision, rowID: "r", cursor: nil, limit: 201)
        }
        let payload = try EngineTranscriptRowDetailsPayload(
            sessionID: "s", revision: revision, rowID: "r", cursor: nil, limit: 10
        )
        let payloadObject = try jsonObject(JSONEncoder().encode(payload))
        for invalidLimit in [0, 201] {
            var invalidObject = payloadObject
            invalidObject["limit"] = invalidLimit
            #expect(try decodingFails(EngineTranscriptRowDetailsPayload.self, object: invalidObject))
        }

        let span = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-a", displayLabel: "A", startMS: 0, endMS: 10
        )
        #expect(try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-a", displayLabel: "A", startMS: 10, endMS: 10
        ).startMS == 10)
        #expect(throws: (any Error).self) {
            try EngineTranscriptSpeakerSpan(speakerID: "speaker-a", displayLabel: "A", startMS: -1, endMS: 0)
        }
        #expect(throws: (any Error).self) {
            try EngineTranscriptSpeakerSpan(speakerID: "speaker-a", displayLabel: "A", startMS: 0, endMS: -1)
        }
        #expect(throws: (any Error).self) {
            try EngineTranscriptSpeakerSpan(speakerID: "speaker-a", displayLabel: "A", startMS: 2, endMS: 1)
        }
        let spanObject = try jsonObject(JSONEncoder().encode(span))
        for (key, value) in [("start_ms", -1), ("end_ms", -1)] {
            var invalidObject = spanObject
            invalidObject[key] = value
            #expect(try decodingFails(EngineTranscriptSpeakerSpan.self, object: invalidObject))
        }
        var reversedInterval = spanObject
        reversedInterval["start_ms"] = 2
        reversedInterval["end_ms"] = 1
        #expect(try decodingFails(EngineTranscriptSpeakerSpan.self, object: reversedInterval))

        let spans200 = try (0..<200).map { index in
            try EngineTranscriptSpeakerSpan(
                speakerID: "speaker-\(index)", displayLabel: "話者\(index)", startMS: Int64(index), endMS: Int64(index + 1)
            )
        }
        let page = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: "r", clauseState: .awaitingNextSegment,
            clauseStateText: "発話文: 続き待ち", speakers: spans200, nextCursor: nil, previousCursor: nil
        )
        #expect(try roundTrip(page) == page)
        #expect(throws: (any Error).self) {
            try EngineTranscriptRowDetailsPage(
                sessionID: "s", revision: revision, rowID: "r", clauseState: .classified,
                clauseStateText: "発話文: 判定済み", speakers: spans200 + [span], nextCursor: nil, previousCursor: nil
            )
        }
        var oversizedPage = try jsonObject(JSONEncoder().encode(page))
        oversizedPage["speakers"] = try (spans200 + [span]).map { try jsonObject(JSONEncoder().encode($0)) }
        #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: oversizedPage))
    }

    @Test func codecRejectsOversizedFullRowDetailsEnvelope() throws {
        let revision = try EngineID(1)
        let oversizedRowID = String(repeating: "x", count: EngineLineFramer.maxLineBytes)
        let oversizedPage = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: oversizedRowID, clauseState: .classified,
            clauseStateText: "発話文: 判定済み", speakers: [], nextCursor: nil, previousCursor: nil
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
                    "speakers": [],
                    "next_cursor": NSNull(),
                    "previous_cursor": NSNull(),
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

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, object: [String: Any]) throws -> Bool {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    do {
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}
