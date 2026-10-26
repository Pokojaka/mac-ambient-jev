import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolKindErrorTests {
    @Test func unknownKindsProduceSpecificProtocolErrors() {
        expectUnknownKind(EngineDevice.self, reason: "unknown device kind")
        expectUnknownKind(EngineDecisionUsage.self, reason: "unknown decision usage kind: future")
        expectUnknownKind(EngineSessionSource.self, reason: "unknown session source kind: future")
        expectUnknownKind(EngineSessionAudio.self, reason: "unknown session audio kind: future")
        expectUnknownKind(EngineSessionMetadata.self, reason: "unknown session metadata kind: future")
        expectUnknownKind(EngineClauseTaggerInspection.self, reason: "unknown clause tagger inspection kind")
    }

    @Test func recordingStartUnknownDeviceKindHasStableSerializedReason() {
        let request = #"{"version":1,"request_id":"1","command":"recording.start","payload":{"source":"microphone","device":{"kind":"future"}}}"#
        let data = Data(request.utf8)

        #expect(throws: EngineProtocolError.invalidJSON("unknown device kind")) {
            try EngineCodec.decodeRequest(data)
        }
        #expect(thrownErrorDescription { _ = try EngineCodec.decodeRequest(data) } == #"invalidJSON("unknown device kind")"#)
    }
}

private func expectUnknownKind<Value: Decodable>(_ type: Value.Type, reason: String) {
    let data = Data(#"{"kind":"future"}"#.utf8)
    #expect(throws: EngineProtocolError.invalidJSON(reason)) {
        try JSONDecoder().decode(type, from: data)
    }
}

private func thrownErrorDescription(_ body: () throws -> Void) -> String? {
    do {
        _ = try body()
        return nil
    } catch {
        return String(describing: error)
    }
}
