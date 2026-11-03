import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCommandTests {
    @Test func settingsRequireEveryFieldAndRemainPortableUntilExplicitValidation() throws {
        let settings = try sampleSettings(threads: 4, automaticExport: true, exportDestinationPath: nil)
        let encoded = try encoder().encode(settings)
        let object = try jsonObject(encoded)
        #expect(Set(object.keys) == [
            "schema_version", "source", "device", "asr_size", "execution_provider", "threads",
            "low_heat", "decisions_enabled", "automatic_export", "export_destination_path"
        ])
        #expect(object["export_destination_path"] is NSNull)
        #expect(object["execution_provider"] as? [String: String] == ["kind": "cpu"])
        #expect(try JSONDecoder().decode(EngineSettings.self, from: encoded) == settings)
        try settings.validate(logicalCPUCount: 4)
        #expect(capturedEngineError { try settings.validate(logicalCPUCount: 2) } == .invalidJSON("threads exceed logical CPU limit"))
        #expect(capturedEngineError { try settings.validate(logicalCPUCount: 0) } == .invalidJSON("logicalCPUCount must be positive"))

        var missing = object
        missing.removeValue(forKey: "execution_provider")
        #expect(decodingFails(EngineSettings.self, object: missing))
        var null = object
        null["export_destination_path"] = NSNull()
        #expect(decodingSucceeds(EngineSettings.self, object: null))
        null.removeValue(forKey: "export_destination_path")
        #expect(decodingFails(EngineSettings.self, object: null))
    }

    @Test func settingsAndPaginationLimitsAreEnforced() throws {
        for limit in [1, 100] {
            _ = try EngineSessionListPayload(cursor: nil, limit: limit)
        }
        for limit in [0, 101] {
            #expect(capturedEngineError { _ = try EngineSessionListPayload(cursor: nil, limit: limit) } != nil)
        }
        for limit in [1, 200] {
            _ = try EngineTranscriptReadPayload(sessionID: "s", revision: nil, cursor: nil, limit: limit)
        }
        for limit in [0, 201] {
            #expect(capturedEngineError { _ = try EngineTranscriptReadPayload(sessionID: "s", revision: nil, cursor: nil, limit: limit) } != nil)
        }
        for threads in [1, 4] {
            _ = try sampleSettings(threads: threads)
        }
        for threads in [0, 5] {
            #expect(capturedEngineError { _ = try sampleSettings(threads: threads) } != nil)
        }
        #expect(capturedEngineError { _ = try sampleSettings(schemaVersion: 1) } == .invalidJSON("schema_version must be 2"))
    }

    @Test func emptyStringsAndInvalidIDsAreRejected() throws {
        #expect(capturedEngineError { _ = try EngineSessionPayload(sessionID: "") } != nil)
        #expect(capturedEngineError { _ = try EngineImportPayload(inputPath: "") } != nil)
        #expect(capturedEngineError { _ = try EngineSessionListPayload(cursor: "", limit: 1) } != nil)
        #expect(capturedEngineError { _ = try EngineTranscriptReadPayload(sessionID: "", revision: nil, cursor: nil, limit: 1) } != nil)
        #expect(capturedEngineError { _ = try EngineTranscriptReadPayload(sessionID: "s", revision: nil, cursor: "", limit: 1) } != nil)
        #expect(capturedEngineError { _ = try EngineExportPayload(sessionID: "s", destinationPath: "") } != nil)
        #expect(capturedEngineError { _ = try EngineExportPayload(sessionID: "", destinationPath: "/export") } != nil)
        #expect(capturedEngineError { _ = try EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings(exportDestinationPath: "")) } != nil)
        #expect(capturedEngineError { _ = try JSONEncoder().encode(EngineDevice.id("")) } != nil)

        for value in ["", "0", "00", "01", "+1", "-1", " 1", "18446744073709551616"] {
            #expect(capturedEngineError { _ = try EngineID(decimal: value) } == .invalidID)
            let request = #"{"version":1,"request_id":""# + value + #"","command":"hello","payload":{}}"#
            #expect(decodingFails(EngineRequest.self, from: Data(request.utf8)))
        }
        #expect(decodingFails(EngineRequest.self, from: Data(#"{"version":1,"request_id":1,"command":"hello","payload":{}}"#.utf8)))
    }

    @Test func deviceAndEnumWireShapesRejectInvalidValues() throws {
        #expect(decodingFails(EngineDevice.self, from: Data(#"{"kind":"default","id":"x"}"#.utf8)))
        #expect(decodingFails(EngineDevice.self, from: Data(#"{"kind":"id","id":""}"#.utf8)))
        #expect(decodingFails(EngineDevice.self, from: Data(#"{"kind":"id"}"#.utf8)))
        #expect(decodingFails(EngineDevice.self, from: Data(#"{"kind":"other"}"#.utf8)))
        #expect(decodingFails(EngineSource.self, from: Data("\"future\"".utf8)))
        #expect(decodingFails(EngineASRSize.self, from: Data("\"future\"".utf8)))
        #expect(decodingFails(EngineExecutionProvider.self, from: Data(#"{"kind":"future"}"#.utf8)))
    }
}

private func sampleSettings(
    schemaVersion: Int = 2,
    threads: Int = 2,
    automaticExport: Bool = false,
    exportDestinationPath: String? = "/exports"
) throws -> EngineSettings {
    try EngineSettings(
        schemaVersion: schemaVersion,
        source: .microphone,
        device: .default,
        asrSize: .small,
        executionProvider: .cpu,
        threads: threads,
        lowHeat: true,
        decisionsEnabled: false,
        automaticExport: automaticExport,
        exportDestinationPath: exportDestinationPath
    )
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func objectData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodingFails<T: Decodable>(_ type: T.Type, from data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}

private func decodingFails<T: Decodable>(_ type: T.Type, object: [String: Any]) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: objectData(object))
        return false
    } catch {
        return true
    }
}

private func decodingSucceeds<T: Decodable>(_ type: T.Type, from data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: data)
        return true
    } catch {
        return false
    }
}

private func decodingSucceeds<T: Decodable>(_ type: T.Type, object: [String: Any]) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: objectData(object))
        return true
    } catch {
        return false
    }
}

private func capturedEngineError(_ operation: () throws -> Void) -> EngineProtocolError? {
    do {
        try operation()
        return nil
    } catch let error as EngineProtocolError {
        return error
    } catch {
        return nil
    }
}
