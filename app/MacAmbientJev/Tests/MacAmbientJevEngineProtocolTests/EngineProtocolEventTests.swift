import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolEventTests {
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

        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":"1","event":"ready","payload":{"capabilities":{"sources":["microphone"],"asr_sizes":["0.6b"],"execution_providers":[{"kind":"cpu"}],"maximum_threads":1,"automatic_input_volume":"none","thermal_monitoring":"none"},"state":{"revision":"1","screen":"idle","setup":"ready","profile_setup":{"evaluation":null},"resource_protection":{"hold_reasons":[]},"recovery":"completed","recording":null,"queue":[],"failures":[],"presentation":{"recording_status_text":"待機中","recording_tone":"neutral","preparation_phase":"ready","preparation_status_text":null,"recovery_status_text":null,"processing_status_text":null,"live_failure_notices":[],"silence_warning_active":false,"silence_warning_text":null,"audio_gap_count":0,"audio_gap_text":null,"processing_indicator":"idle"}}}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"accepted","payload":{"command":"hello"}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":null,"event":"completed","payload":{"command":"models.prepare","result":{}}}"#))
        #expect(decodingFails(EngineOutput.self, from: #"{"version":1,"sequence":"1","request_id":"1","event":"error","payload":{"code":"busy","message":"busy","stage":"capture","request_id":"2","session_id":null,"severity":"error","recovery_action":"retry","details":[],"cleanup_errors":[]}}"#))
    }

    @Test func newCommandOutputsRejectMismatchedCommandsAndInvalidNestedPayloads() throws {
        let diagnosticsOutput = try EngineOutput(
            version: 1,
            sequence: engineID(60),
            requestID: engineID(61),
            event: .completed(.diagnosticsGet(try sampleAvailableDiagnosticsResult()))
        )
        let modelsOutput = try EngineOutput(
            version: 1,
            sequence: engineID(62),
            requestID: engineID(63),
            event: .completed(.modelsInspect(EngineModelsInspection(clauseTagger: .validated(try sampleModelIdentity()))))
        )

        var diagnosticsObject = try jsonObject(encoder().encode(diagnosticsOutput))
        var diagnosticsEnvelope = try #require(diagnosticsObject["payload"] as? [String: Any])
        diagnosticsEnvelope["command"] = EngineCommandName.modelsInspect.rawValue
        diagnosticsObject["payload"] = diagnosticsEnvelope
        #expect(decodingFails(EngineOutput.self, from: try objectData(diagnosticsObject)))

        var modelsObject = try jsonObject(encoder().encode(modelsOutput))
        var modelsEnvelope = try #require(modelsObject["payload"] as? [String: Any])
        modelsEnvelope["command"] = EngineCommandName.diagnosticsGet.rawValue
        modelsObject["payload"] = modelsEnvelope
        #expect(decodingFails(EngineOutput.self, from: try objectData(modelsObject)))

    }

}

private func sampleAvailableDiagnosticsResult() throws -> EngineDiagnosticsResult {
    let boundaryRequests = try EngineDecisionRequestUsage(sendCount: 2, inputTokens: 11, successCount: 1, failureCount: 1)
    let priorityRequests = try EngineDecisionRequestUsage(sendCount: 2, inputTokens: 17, successCount: 1, failureCount: 1)
    let snapshot = try EngineDecisionUsageSnapshot(
        sendCount: 4,
        inputTokens: 28,
        successCount: 2,
        failureCount: 2,
        pendingBoundarySegmentCount: 2,
        pendingPriorityClauseCount: 3,
        boundaryRequests: boundaryRequests,
        priorityRequests: priorityRequests
    )
    return EngineDiagnosticsResult(
        scope: .engineProcess,
        decisionUsage: .available(snapshot),
        automaticInputVolume: .none,
        thermalMonitoring: .none
    )
}

private func sampleModelIdentity() throws -> EngineClauseTaggerIdentity {
    try EngineClauseTaggerIdentity(
        backend: "coreml",
        modelID: "clause-tagger-v1",
        revision: String(repeating: "a", count: 64),
        tokenizerSHA256: String(repeating: "b", count: 64)
    )
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
        profileSetup: .init(evaluation: nil),
        resourceProtection: try .init(holdReasons: []),
        recovery: .completed,
        recording: nil,
        queue: [],
        failures: [],
        presentation: try engineTestPresentation()
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

private func objectData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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
