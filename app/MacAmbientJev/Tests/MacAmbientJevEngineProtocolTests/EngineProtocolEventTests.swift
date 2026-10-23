import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolEventTests {
    @Test func allCommandResultsRoundTripWithExactKeys() throws {
        let state = try sampleState()
        let ready = EngineReadyPayload(capabilities: try sampleCapabilities(), state: state)
        let session = try EngineSessionPayload(sessionID: "session-1")
        let settingsResult = EngineSettingsResult(revision: try engineID(2), settings: try sampleSettings())
        let row = try sampleRow()
        let page = try EngineTranscriptPage(sessionID: "session-1", revision: engineID(3), rows: [row], nextCursor: nil, previousCursor: nil)
        let inspectedSummary = try sampleSessionSummary()
        let results: [(EngineCommandName, EngineResult, Set<String>)] = [
            (.hello, .hello(ready), ["capabilities", "state"]),
            (.stateGet, .stateGet(state), ["revision", "screen", "setup", "recovery", "recording", "queue", "failures"]),
            (.devicesList, .devicesList(try EngineDevicesResult(source: .microphone, devices: [], defaultDeviceID: nil)), ["source", "devices", "default_device_id"]),
            (.recordingStart, .recordingStart(session), ["session_id"]),
            (.recordingStop, .recordingStop(session), ["session_id"]),
            (.sessionImport, .sessionImport(session), ["session_id"]),
            (.sessionInspect, .sessionInspect(inspectedSummary), [
                "folder_id", "session_id", "status", "error", "display_name", "status_text", "folder_path",
                "export_path", "can_reprocess", "can_retry_decisions", "can_export", "metadata"
            ]),
            (.sessionReprocess, .sessionReprocess(session), ["session_id"]),
            (.sessionRetryDecisions, .sessionRetryDecisions(session), ["session_id"]),
            (.sessionList, .sessionList(try EngineSessionListResult(sessions: [], nextCursor: nil, previousCursor: nil)), ["sessions", "next_cursor", "previous_cursor"]),
            (.transcriptRead, .transcriptRead(page), ["session_id", "revision", "rows", "next_cursor", "previous_cursor"]),
            (.transcriptWatch, .transcriptWatch(page), ["session_id", "revision", "rows", "next_cursor", "previous_cursor"]),
            (.sessionExport, .sessionExport(try EngineExportResult(sessionID: "session-1", destinationPath: "/published/bundle")), ["session_id", "destination_path"]),
            (.settingsGet, .settingsGet(settingsResult), ["revision", "settings"]),
            (.settingsReplace, .settingsReplace(settingsResult), ["revision", "settings"]),
            (.modelsPrepare, .modelsPrepare, []),
            (.shutdown, .shutdown, [])
        ]

        #expect(results.count == 17)
        #expect(EngineCommandName.allCases == results.map(\.0))

        for (command, result, resultKeys) in results {
            let data = try encoder().encode(result)
            let object = try jsonObject(data)
            #expect(Set(object.keys) == ["command", "result"])
            #expect(object["command"] as? String == command.rawValue)
            let resultObject = try #require(object["result"] as? [String: Any])
            #expect(Set(resultObject.keys) == resultKeys)
            #expect(try JSONDecoder().decode(EngineResult.self, from: data) == result)
            if command == .modelsPrepare || command == .shutdown {
                #expect(resultObject.isEmpty)
            }
        }

        #expect(EngineResult.sessionImport(session).command == .sessionImport)
        #expect(EngineResult.sessionInspect(inspectedSummary).command == .sessionInspect)
    }

    @Test func sessionInspectRoundTripsThroughFullCodecRequestAndOutput() throws {
        let requestID = try engineID(21)
        let request = try EngineRequest(
            version: 1,
            requestID: requestID,
            command: .sessionInspect(try EngineSessionInspectPayload(folderID: "folder-inspected"))
        )
        let requestLine = try EngineCodec.encodeRequest(request)
        #expect(try EngineCodec.decodeRequest(Data(requestLine.dropLast())) == request)

        let output = try EngineOutput(
            version: 1,
            sequence: engineID(22),
            requestID: requestID,
            event: .completed(.sessionInspect(try sampleSessionSummary()))
        )
        let outputLine = try EngineCodec.encodeOutput(output)
        #expect(try EngineCodec.decodeOutput(Data(outputLine.dropLast())) == output)
    }

    @Test func allEventCasesRoundTripWithExactDiscriminatorAndPayload() throws {
        let state = try sampleState()
        let row = try sampleRow()
        let failure = try sampleFailure(requestID: nil)
        let events: [(EngineEvent, EngineEventName, Set<String>)] = [
            (.ready(EngineReadyPayload(capabilities: try sampleCapabilities(), state: state)), .ready, ["capabilities", "state"]),
            (.state(state), .state, ["revision", "screen", "setup", "recovery", "recording", "queue", "failures"]),
            (.accepted(EngineAcceptedPayload(command: .recordingStop)), .accepted, ["command"]),
            (.completed(.modelsPrepare), .completed, ["command", "result"]),
            (.progress(try EngineProgressPayload(stage: .asr, completedUnits: 2, totalUnits: nil, sessionID: "session-1")), .progress, ["stage", "completed_units", "total_units", "session_id"]),
            (.rows(try EngineRowsPayload(sessionID: "session-1", revision: engineID(3), kind: .snapshot, rows: [row], removedRowIDs: [], nextCursor: "next")), .rows, ["session_id", "revision", "kind", "rows", "removed_row_ids", "next_cursor"]),
            (.error(failure), .error, ["code", "message", "stage", "request_id", "session_id", "severity", "recovery_action", "details", "cleanup_errors"])
        ]

        #expect(events.count == EngineEventName.allCases.count)
        #expect(EngineEventName.allCases == events.map(\.1))
        for (event, name, payloadKeys) in events {
            let data = try encoder().encode(event)
            let object = try jsonObject(data)
            #expect(Set(object.keys) == ["event", "payload"])
            #expect(object["event"] as? String == name.rawValue)
            let payload = try #require(object["payload"] as? [String: Any])
            #expect(Set(payload.keys) == payloadKeys)
            #expect(try JSONDecoder().decode(EngineEvent.self, from: data) == event)
        }
    }

    @Test func outputIsFlatAndRowsKindsRoundTrip() throws {
        let row = try sampleRow()
        let cases: [(EngineRowsKind, [EngineTranscriptRow], [String], String?)] = [
            (.snapshot, [row], [], "next"),
            (.changes, [row], ["removed-row"], nil),
            (.reloadRequired, [], [], nil)
        ]
        for (kind, rows, removed, cursor) in cases {
            let payload = try EngineRowsPayload(
                sessionID: "session-1",
                revision: engineID(4),
                kind: kind,
                rows: rows,
                removedRowIDs: removed,
                nextCursor: cursor
            )
            let output = try EngineOutput(version: 1, sequence: engineID(10), requestID: nil, event: .rows(payload))
            let data = try encoder().encode(output)
            let object = try jsonObject(data)
            #expect(Set(object.keys) == ["version", "sequence", "request_id", "event", "payload"])
            #expect(object["version"] as? Int == 1)
            #expect(object["sequence"] as? String == "10")
            #expect(object["request_id"] is NSNull)
            #expect(object["event"] as? String == "rows")
            let payloadObject = try #require(object["payload"] as? [String: Any])
            #expect(payloadObject["kind"] as? String == kind.rawValue)
            #expect(try JSONDecoder().decode(EngineOutput.self, from: data) == output)
        }
    }

    @Test func outputCorrelationAndVersionAreValidatedByInitializerAndDecoder() throws {
        let id = try engineID(7)
        let accepted = EngineEvent.accepted(EngineAcceptedPayload(command: .hello))
        let completed = EngineEvent.completed(.modelsPrepare)
        let ready = EngineEvent.ready(EngineReadyPayload(capabilities: try sampleCapabilities(), state: try sampleState()))
        let matchingFailure = try sampleFailure(requestID: id)
        let mismatchedFailure = try sampleFailure(requestID: engineID(8))

        #expect(throws: (any Error).self) { try EngineOutput(version: 1, sequence: id, requestID: id, event: ready) }
        #expect(throws: (any Error).self) { try EngineOutput(version: 1, sequence: id, requestID: nil, event: accepted) }
        #expect(throws: (any Error).self) { try EngineOutput(version: 1, sequence: id, requestID: nil, event: completed) }
        #expect(throws: (any Error).self) { try EngineOutput(version: 1, sequence: id, requestID: id, event: .error(mismatchedFailure)) }
        #expect(try EngineOutput(version: 1, sequence: id, requestID: id, event: .accepted(EngineAcceptedPayload(command: .hello))).requestID == id)
        #expect(try EngineOutput(version: 1, sequence: id, requestID: id, event: .completed(.modelsPrepare)).requestID == id)
        #expect(try EngineOutput(version: 1, sequence: id, requestID: id, event: .error(matchingFailure)).requestID == id)
        #expect(try EngineOutput(version: 1, sequence: id, requestID: nil, event: .error(try sampleFailure(requestID: nil))).requestID == nil)
        #expect(throws: (any Error).self) { try EngineOutput(version: 2, sequence: id, requestID: nil, event: .state(try sampleState())) }

        #expect(decodingEngineError(#"{"version":2,"sequence":"1","request_id":null,"event":"state","payload":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[]}}"#) == .unsupportedVersion(2))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":true,"sequence":"1","request_id":null,"event":"state","payload":{}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","event":"state","payload":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[]}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":false,"event":"state","payload":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[]}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"state","payload":null}"#))

        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":"1","event":"ready","payload":{"capabilities":{"sources":["microphone"],"asr_sizes":["0.6b"],"execution_providers":["cpu"],"maximum_threads":1,"automatic_input_volume":"none","thermal_monitoring":"none"},"state":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[]}}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"accepted","payload":{"command":"hello"}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"completed","payload":{"command":"models.prepare","result":{}}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":"1","event":"error","payload":{"code":"busy","message":"busy","stage":"capture","request_id":"2","session_id":null,"severity":"error","recovery_action":"retry","details":[],"cleanup_errors":[]}}"#))
    }

    @Test func unknownNamesUnknownEnumsAndRecursiveUnknownFieldsAreRejected() throws {
        #expect(decodingFails(EngineEventName.self, from: Data(#""future""#.utf8)))
        #expect(decodingFails(EngineResult.self, from: #"{"command":"future.command","result":{}}"#))
        #expect(decodingFails(EngineEvent.self, from: #"{"event":"future.event","payload":{}}"#))
        #expect(decodingFails(EngineEvent.self, from: #"{"event":"error","payload":{"code":"future_code","message":"error","stage":"capture","request_id":null,"session_id":null,"severity":"error","recovery_action":"none","details":[],"cleanup_errors":[]}}"#))

        #expect(decodingFails(EngineResult.self, from: #"{"command":"models.prepare","result":{},"extra":true}"#))
        #expect(decodingFails(EngineResult.self, from: #"{"command":"models.prepare","result":{"extra":true}}"#))
        #expect(decodingFails(EngineResult.self, from: #"{"command":"session.export","result":{"session_id":"s","destination_path":"/published","extra":true}}"#))
        #expect(decodingFails(EngineEvent.self, from: #"{"event":"accepted","payload":{"command":"hello","extra":true}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"rows","payload":{"session_id":"s","revision":"1","kind":"snapshot","rows":[{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":[],"clause_state":null,"extra":true}],"removed_row_ids":[],"next_cursor":null}}"#))
    }

    @Test func exportResultRequiresNonemptyStringsAndExactKeys() throws {
        let export = try EngineExportResult(sessionID: "session-1", destinationPath: "/published/bundle")
        let object = try jsonObject(encoder().encode(export))
        #expect(Set(object.keys) == ["session_id", "destination_path"])
        #expect(try JSONDecoder().decode(EngineExportResult.self, from: encoder().encode(export)) == export)
        #expect(throws: (any Error).self) { try EngineExportResult(sessionID: "", destinationPath: "/published") }
        #expect(throws: (any Error).self) { try EngineExportResult(sessionID: "session-1", destinationPath: "") }
        #expect(decodingFails(EngineExportResult.self, from: #"{"session_id":"","destination_path":"/published"}"#))
        #expect(decodingFails(EngineExportResult.self, from: #"{"session_id":"session-1","destination_path":null}"#))
    }
}

private func sampleCapabilities() throws -> EngineCapabilities {
    try EngineCapabilities(
        sources: [.microphone, .systemAudio],
        asrSizes: [.small, .large],
        executionProviders: [.cpu],
        maximumThreads: 4,
        automaticInputVolume: .none,
        thermalMonitoring: .none
    )
}

private func sampleState() throws -> EngineState {
    try EngineState(
        revision: engineID(1),
        screen: .idle,
        setup: .ready,
        recovery: .completed,
        recording: nil,
        queue: [],
        failures: []
    )
}

private func sampleFailure(requestID: EngineID?) throws -> EngineFailure {
    try EngineFailure(
        code: .busy,
        message: "operation is busy",
        stage: .capture,
        requestID: requestID,
        sessionID: nil,
        severity: .error,
        recoveryAction: .retry,
        details: [],
        cleanupErrors: []
    )
}

private func sampleRow() throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: "row-1", startMS: 12, endMS: 34, text: "日本語の文字起こし", headings: [.speaker1], clauseState: nil)
}

private func sampleSessionSummary() throws -> EngineSessionSummary {
    try EngineSessionSummary(
        folderID: "folder-inspected",
        sessionID: "session-inspected",
        status: .finalized,
        error: nil,
        displayName: "Inspected recording",
        statusText: "Finalized",
        folderPath: "/sessions/folder-inspected",
        exportPath: nil,
        canReprocess: true,
        canRetryDecisions: true,
        canExport: true,
        metadata: .readable(
            createdAt: 1_700_000_000,
            source: .imported(originalFilename: "meeting.wav"),
            audio: .available,
            hasTranscript: true
        )
    )
}

private func sampleSettings() throws -> EngineSettings {
    try EngineSettings(
        schemaVersion: 1,
        source: .microphone,
        device: .default,
        asrSize: .small,
        executionProvider: .cpu,
        threads: 2,
        lowHeat: true,
        decisionsEnabled: false,
        automaticExport: false,
        exportDestinationPath: nil
    )
}

private func engineID(_ value: UInt64) throws -> EngineID {
    try EngineID(value)
}

private func encoder() -> JSONEncoder {
    let value = JSONEncoder()
    value.outputFormatting = [.sortedKeys]
    return value
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, from string: String) -> Bool {
    decodingFails(type, from: Data(string.utf8))
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, from data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}

private func decodingEngineError(_ string: String) -> EngineProtocolError? {
    do {
        _ = try JSONDecoder().decode(EngineOutput.self, from: Data(string.utf8))
        return nil
    } catch let error as EngineProtocolError {
        return error
    } catch {
        return nil
    }
}
