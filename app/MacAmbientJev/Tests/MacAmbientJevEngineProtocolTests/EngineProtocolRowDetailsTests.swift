import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolRowDetailsTests {
    @Test func payloadSpanAndPageRoundTripWithRequiredNullableCursors() throws {
        let revision = try EngineID(7)
        let payloadWithoutCursor = try EngineTranscriptRowDetailsPayload(
            sessionID: "session-1", revision: revision, rowID: "row-1", cursor: nil, limit: 200
        )
        let payloadWithCursor = try EngineTranscriptRowDetailsPayload(
            sessionID: "session-1", revision: revision, rowID: "row-1", cursor: "cursor-2", limit: 1
        )
        let firstSpan = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-internal-42", displayLabel: "司会者", startMS: 12, endMS: 34
        )
        let overlappingSpan = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-internal-42", displayLabel: "司会者", startMS: 20, endMS: 50
        )
        let pageWithoutCursors = try EngineTranscriptRowDetailsPage(
            sessionID: "session-1", revision: revision, rowID: "row-1",
            clauseState: .boundaryPending, clauseStateText: "発話文: 境界判定を保留中",
            speakers: [firstSpan, overlappingSpan], nextCursor: nil, previousCursor: nil
        )
        let pageWithCursors = try EngineTranscriptRowDetailsPage(
            sessionID: "session-1", revision: revision, rowID: "row-1",
            clauseState: .classified, clauseStateText: "発話文: 判定済み",
            speakers: [firstSpan], nextCursor: "next-page", previousCursor: "previous-page"
        )

        #expect(try roundTrip(payloadWithoutCursor) == payloadWithoutCursor)
        #expect(try roundTrip(payloadWithCursor) == payloadWithCursor)
        #expect(try roundTrip(firstSpan) == firstSpan)
        #expect(try roundTrip(pageWithoutCursors) == pageWithoutCursors)
        #expect(try roundTrip(pageWithCursors) == pageWithCursors)
        #expect(EngineClauseState.allCases.map(\.rawValue) == [
            "awaiting_next_segment", "boundary_pending", "priority_pending", "classified"
        ])
        let payloadNullObject = try jsonObject(JSONEncoder().encode(payloadWithoutCursor))
        #expect(Set(payloadNullObject.keys) == ["session_id", "revision", "row_id", "cursor", "limit"])
        #expect(payloadNullObject["revision"] as? String == "7")
        #expect(payloadNullObject["cursor"] is NSNull)
        let payloadCursorObject = try jsonObject(JSONEncoder().encode(payloadWithCursor))
        #expect(payloadCursorObject["cursor"] as? String == "cursor-2")

        let pageNullObject = try jsonObject(JSONEncoder().encode(pageWithoutCursors))
        #expect(Set(pageNullObject.keys) == [
            "session_id", "revision", "row_id", "clause_state", "clause_state_text", "speakers",
            "next_cursor", "previous_cursor"
        ])
        #expect(pageNullObject["next_cursor"] is NSNull)
        #expect(pageNullObject["previous_cursor"] is NSNull)
        let pageCursorObject = try jsonObject(JSONEncoder().encode(pageWithCursors))
        #expect(pageCursorObject["next_cursor"] as? String == "next-page")
        #expect(pageCursorObject["previous_cursor"] as? String == "previous-page")
        let spanObject = try jsonObject(JSONEncoder().encode(firstSpan))
        #expect(Set(spanObject.keys) == ["speaker_id", "display_label", "start_ms", "end_ms"])
        #expect(spanObject["display_label"] as? String == "司会者")
    }

    @Test func everyObjectRejectsUnknownMissingNullAndWrongTypeKeys() throws {
        let revision = try EngineID(3)
        let payload = try EngineTranscriptRowDetailsPayload(
            sessionID: "s", revision: revision, rowID: "r", cursor: "c", limit: 5
        )
        let payloadObject = try jsonObject(JSONEncoder().encode(payload))
        try assertStrictKeyMutations(
            EngineTranscriptRowDetailsPayload.self,
            object: payloadObject,
            keys: ["session_id", "revision", "row_id", "cursor", "limit"],
            nullableKeys: ["cursor"]
        )

        let span = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-a", displayLabel: "表示名", startMS: 0, endMS: 8
        )
        let spanObject = try jsonObject(JSONEncoder().encode(span))
        try assertStrictKeyMutations(
            EngineTranscriptSpeakerSpan.self,
            object: spanObject,
            keys: ["speaker_id", "display_label", "start_ms", "end_ms"]
        )

        let page = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: "r", clauseState: .classified,
            clauseStateText: "発話文: 判定済み", speakers: [span], nextCursor: "next", previousCursor: "previous"
        )
        let pageObject = try jsonObject(JSONEncoder().encode(page))
        try assertStrictKeyMutations(
            EngineTranscriptRowDetailsPage.self,
            object: pageObject,
            keys: [
                "session_id", "revision", "row_id", "clause_state", "clause_state_text", "speakers",
                "next_cursor", "previous_cursor"
            ],
            nullableKeys: ["next_cursor", "previous_cursor"]
        )

        var nestedSpans = try #require(pageObject["speakers"] as? [[String: Any]])
        var nestedSpan = nestedSpans[0]
        nestedSpan["unknown"] = true
        nestedSpans[0] = nestedSpan
        var pageWithUnknownNestedKey = pageObject
        pageWithUnknownNestedKey["speakers"] = nestedSpans
        #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: pageWithUnknownNestedKey))

        for key in ["speaker_id", "display_label", "start_ms", "end_ms"] {
            var missingSpan = try #require(pageObject["speakers"] as? [[String: Any]])[0]
            missingSpan.removeValue(forKey: key)
            var changedSpans = try #require(pageObject["speakers"] as? [[String: Any]])
            changedSpans[0] = missingSpan
            var changedPage = pageObject
            changedPage["speakers"] = changedSpans
            #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: changedPage))

            var nullSpan = try #require(pageObject["speakers"] as? [[String: Any]])[0]
            nullSpan[key] = NSNull()
            changedSpans = try #require(pageObject["speakers"] as? [[String: Any]])
            changedSpans[0] = nullSpan
            changedPage = pageObject
            changedPage["speakers"] = changedSpans
            #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: changedPage))

            var wrongTypeSpan = try #require(pageObject["speakers"] as? [[String: Any]])[0]
            wrongTypeSpan[key] = false
            changedSpans = try #require(pageObject["speakers"] as? [[String: Any]])
            changedSpans[0] = wrongTypeSpan
            changedPage = pageObject
            changedPage["speakers"] = changedSpans
            #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: changedPage))
        }
    }

    @Test func stringsRevisionsAndClauseEnumsAreValidatedDuringDecode() throws {
        let revision = try EngineID(9)
        let payload = try EngineTranscriptRowDetailsPayload(
            sessionID: "s", revision: revision, rowID: "r", cursor: "c", limit: 5
        )
        let payloadObject = try jsonObject(JSONEncoder().encode(payload))
        for key in ["session_id", "row_id", "cursor"] {
            var object = payloadObject
            object[key] = ""
            #expect(try decodingFails(EngineTranscriptRowDetailsPayload.self, object: object))
        }
        try assertInvalidRevisions(EngineTranscriptRowDetailsPayload.self, object: payloadObject)

        let span = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-a", displayLabel: "Label", startMS: 1, endMS: 2
        )
        let spanObject = try jsonObject(JSONEncoder().encode(span))
        for key in ["speaker_id", "display_label"] {
            var object = spanObject
            object[key] = ""
            #expect(try decodingFails(EngineTranscriptSpeakerSpan.self, object: object))
        }

        let page = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: "r", clauseState: .classified,
            clauseStateText: "発話文: 判定済み", speakers: [span], nextCursor: "next", previousCursor: "previous"
        )
        let pageObject = try jsonObject(JSONEncoder().encode(page))
        for key in ["session_id", "row_id", "clause_state_text", "next_cursor", "previous_cursor"] {
            var object = pageObject
            object[key] = ""
            #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: object))
        }
        try assertInvalidRevisions(EngineTranscriptRowDetailsPage.self, object: pageObject)
        var unknownClauseState = pageObject
        unknownClauseState["clause_state"] = "pending"
        #expect(try decodingFails(EngineTranscriptRowDetailsPage.self, object: unknownClauseState))
    }

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

    @Test func requestAndCompletedRowDetailsRoundTripThroughFullCodec() throws {
        let revision = try EngineID(7)
        let requests = [
            try EngineRequest(
                version: 1, requestID: EngineID(21),
                command: .transcriptRowDetails(try EngineTranscriptRowDetailsPayload(
                    sessionID: "session-1", revision: revision, rowID: "row-1", cursor: nil, limit: 200
                ))
            ),
            try EngineRequest(
                version: 1, requestID: EngineID(22),
                command: .transcriptRowDetails(try EngineTranscriptRowDetailsPayload(
                    sessionID: "session-1", revision: revision, rowID: "row-1", cursor: "cursor-2", limit: 1
                ))
            ),
        ]
        for request in requests {
            let line = try EngineCodec.encodeRequest(request)
            #expect(line.last == 0x0A)
            #expect(try EngineCodec.decodeRequest(Data(line.dropLast())) == request)
        }

        let speakers = [
            try EngineTranscriptSpeakerSpan(
                speakerID: "speaker-internal-42", displayLabel: "司会者・主話者", startMS: 12, endMS: 34
            ),
            try EngineTranscriptSpeakerSpan(
                speakerID: "speaker-internal-42", displayLabel: "司会者・主話者", startMS: 20, endMS: 50
            ),
        ]
        let examples: [(EngineClauseState, String, String?, String?)] = [
            (.awaitingNextSegment, "発話文: 続き待ち", "next-1", nil),
            (.boundaryPending, "発話文: 境界判定を保留中", nil, "previous-2"),
            (.priorityPending, "発話文: 優先度判定を待っています", "next-3", "previous-3"),
            (.classified, "発話文: 判定済み", nil, nil),
        ]
        for (index, example) in examples.enumerated() {
            let page = try EngineTranscriptRowDetailsPage(
                sessionID: "session-1", revision: revision, rowID: "row-1",
                clauseState: example.0, clauseStateText: example.1, speakers: speakers,
                nextCursor: example.2, previousCursor: example.3
            )
            let requestID = try EngineID(UInt64(31 + index))
            let output = try EngineOutput(
                version: 1, sequence: try EngineID(UInt64(41 + index)), requestID: requestID,
                event: .completed(.transcriptRowDetails(page))
            )
            let line = try EngineCodec.encodeOutput(output)
            #expect(line.last == 0x0A)
            #expect(try EngineCodec.decodeOutput(Data(line.dropLast())) == output)

            let outputObject = try jsonObject(Data(line.dropLast()))
            let outputPayload = try #require(outputObject["payload"] as? [String: Any])
            let result = try #require(outputPayload["result"] as? [String: Any])
            #expect(result["clause_state"] as? String == example.0.rawValue)
            #expect(result["clause_state_text"] as? String == example.1)
            let encodedSpeakers = try #require(result["speakers"] as? [[String: Any]])
            #expect(encodedSpeakers.map { $0["speaker_id"] as? String } == [
                "speaker-internal-42", "speaker-internal-42"
            ])
            #expect(encodedSpeakers.map { $0["display_label"] as? String } == [
                "司会者・主話者", "司会者・主話者"
            ])
            #expect(encodedSpeakers[0]["start_ms"] as? Int == 12)
            #expect(encodedSpeakers[0]["end_ms"] as? Int == 34)
            #expect(encodedSpeakers[1]["start_ms"] as? Int == 20)
            #expect(encodedSpeakers[1]["end_ms"] as? Int == 50)
        }

        let emptySpeakersPage = try EngineTranscriptRowDetailsPage(
            sessionID: "session-1", revision: revision, rowID: "row-1", clauseState: .classified,
            clauseStateText: "発話文: 判定済み", speakers: [], nextCursor: nil, previousCursor: nil
        )
        let emptySpeakersOutput = try EngineOutput(
            version: 1, sequence: EngineID(45), requestID: EngineID(35),
            event: .completed(.transcriptRowDetails(emptySpeakersPage))
        )
        let emptySpeakersLine = try EngineCodec.encodeOutput(emptySpeakersOutput)
        #expect(try EngineCodec.decodeOutput(Data(emptySpeakersLine.dropLast())) == emptySpeakersOutput)
        let emptySpeakersObject = try jsonObject(Data(emptySpeakersLine.dropLast()))
        let emptySpeakersPayload = try #require(emptySpeakersObject["payload"] as? [String: Any])
        let emptySpeakersResult = try #require(emptySpeakersPayload["result"] as? [String: Any])
        #expect((emptySpeakersResult["speakers"] as? [Any])?.isEmpty == true)
        #expect(emptySpeakersResult["next_cursor"] is NSNull)
        #expect(emptySpeakersResult["previous_cursor"] is NSNull)
    }

    @Test func codecRejectsInvalidRowDetailsEnvelopes() throws {
        let revision = try EngineID(3)
        let request = try EngineRequest(
            version: 1, requestID: EngineID(1),
            command: .transcriptRowDetails(try EngineTranscriptRowDetailsPayload(
                sessionID: "s", revision: revision, rowID: "r", cursor: "cursor", limit: 5
            ))
        )
        let validRequestObject = try jsonObject(EngineCodec.encodeRequest(request))

        var nullRequestRevision = validRequestObject
        var nullRequestPayload = try #require(nullRequestRevision["payload"] as? [String: Any])
        nullRequestPayload["revision"] = NSNull()
        nullRequestRevision["payload"] = nullRequestPayload
        #expect(throws: (any Error).self) {
            try EngineCodec.decodeRequest(jsonData(nullRequestRevision))
        }

        var missingRequestCursor = validRequestObject
        var requestPayloadWithoutCursor = try #require(missingRequestCursor["payload"] as? [String: Any])
        requestPayloadWithoutCursor.removeValue(forKey: "cursor")
        missingRequestCursor["payload"] = requestPayloadWithoutCursor
        #expect(throws: (any Error).self) {
            try EngineCodec.decodeRequest(jsonData(missingRequestCursor))
        }

        let speaker = try EngineTranscriptSpeakerSpan(
            speakerID: "speaker-a", displayLabel: "表示名", startMS: 12, endMS: 34
        )
        let page = try EngineTranscriptRowDetailsPage(
            sessionID: "s", revision: revision, rowID: "r", clauseState: .classified,
            clauseStateText: "発話文: 判定済み", speakers: [speaker], nextCursor: "next", previousCursor: "previous"
        )
        let output = try EngineOutput(
            version: 1, sequence: EngineID(2), requestID: EngineID(1),
            event: .completed(.transcriptRowDetails(page))
        )
        let validOutputObject = try jsonObject(Data(EngineCodec.encodeOutput(output).dropLast()))
        let validOutputPayload = try #require(validOutputObject["payload"] as? [String: Any])
        let validResult = try #require(validOutputPayload["result"] as? [String: Any])

        var nullOutputRevision = validOutputObject
        var nullOutputPayload = try #require(nullOutputRevision["payload"] as? [String: Any])
        var nullOutputResult = try #require(nullOutputPayload["result"] as? [String: Any])
        nullOutputResult["revision"] = NSNull()
        nullOutputPayload["result"] = nullOutputResult
        nullOutputRevision["payload"] = nullOutputPayload
        #expect(throws: (any Error).self) {
            try EngineCodec.decodeOutput(jsonData(nullOutputRevision))
        }

        var unknownNestedKey = validOutputObject
        var unknownPayload = try #require(unknownNestedKey["payload"] as? [String: Any])
        var unknownResult = try #require(unknownPayload["result"] as? [String: Any])
        var unknownSpeakers = try #require(unknownResult["speakers"] as? [[String: Any]])
        unknownSpeakers[0]["future"] = true
        unknownResult["speakers"] = unknownSpeakers
        unknownPayload["result"] = unknownResult
        unknownNestedKey["payload"] = unknownPayload
        #expect(throws: (any Error).self) {
            try EngineCodec.decodeOutput(jsonData(unknownNestedKey))
        }

        for key in ["next_cursor", "previous_cursor"] {
            var missingNullableKey = validOutputObject
            var missingPayload = try #require(missingNullableKey["payload"] as? [String: Any])
            var missingResult = try #require(missingPayload["result"] as? [String: Any])
            missingResult.removeValue(forKey: key)
            missingPayload["result"] = missingResult
            missingNullableKey["payload"] = missingPayload
            #expect(throws: (any Error).self) {
                try EngineCodec.decodeOutput(jsonData(missingNullableKey))
            }
        }

        var wrongResultShape = validOutputObject
        var wrongShapePayload = try #require(wrongResultShape["payload"] as? [String: Any])
        wrongShapePayload["result"] = ["not", "an", "object"]
        wrongResultShape["payload"] = wrongShapePayload
        #expect(throws: (any Error).self) {
            try EngineCodec.decodeOutput(jsonData(wrongResultShape))
        }

        #expect(validResult["next_cursor"] as? String == "next")
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

private func assertStrictKeyMutations<Value: Decodable>(
    _ type: Value.Type,
    object: [String: Any],
    keys: [String],
    nullableKeys: Set<String> = []
) throws {
    for key in keys {
        var missing = object
        missing.removeValue(forKey: key)
        #expect(try decodingFails(type, object: missing))

        var nullValue = object
        nullValue[key] = NSNull()
        if nullableKeys.contains(key) {
            #expect(try decodingFails(type, object: nullValue) == false)
        } else {
            #expect(try decodingFails(type, object: nullValue))
        }

        var wrongType = object
        wrongType[key] = false
        #expect(try decodingFails(type, object: wrongType))
    }

    var unknown = object
    unknown["unknown_field"] = true
    #expect(try decodingFails(type, object: unknown))
}

private func assertInvalidRevisions<Value: Decodable>(
    _ type: Value.Type,
    object: [String: Any]
) throws {
    for invalidRevision: Any in ["", "0", "01", "+1", "1 ", "18446744073709551616", NSNull(), 1] {
        var invalidObject = object
        invalidObject["revision"] = invalidRevision
        #expect(try decodingFails(type, object: invalidObject))
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
