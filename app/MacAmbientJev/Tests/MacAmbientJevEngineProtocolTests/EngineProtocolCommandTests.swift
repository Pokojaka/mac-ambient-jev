import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCommandTests {
    @Test func allCommandsRoundTripWithExactEnvelopeAndPayloadKeys() throws {
        let settings = try sampleSettings()
        let session = try EngineSessionPayload(sessionID: "session-1")
        let commands: [(EngineCommandName, EngineCommand, Set<String>)] = [
            (.hello, .hello, []),
            (.stateGet, .stateGet, []),
            (.devicesList, .devicesList(EngineDevicesListPayload(source: .microphone)), ["source"]),
            (.recordingStart, .recordingStart(try EngineRecordingStartPayload(source: .systemAudio, device: .id("endpoint-1"))), ["source", "device"]),
            (.recordingStop, .recordingStop(session), ["session_id"]),
            (.sessionImport, .sessionImport(try EngineImportPayload(inputPath: "/audio.wav")), ["input_path"]),
            (.sessionInspect, .sessionInspect(try EngineSessionInspectPayload(folderID: "session-folder-1")), ["folder_id"]),
            (.sessionReprocess, .sessionReprocess(session), ["session_id"]),
            (.sessionRetryDecisions, .sessionRetryDecisions(session), ["session_id"]),
            (.sessionList, .sessionList(try EngineSessionListPayload(cursor: nil, limit: 100)), ["cursor", "limit"]),
            (.transcriptRead, .transcriptRead(try EngineTranscriptReadPayload(sessionID: "session-1", revision: nil, cursor: nil, limit: 200)), ["session_id", "revision", "cursor", "limit"]),
            (.transcriptWatch, .transcriptWatch(session), ["session_id"]),
            (.sessionExport, .sessionExport(try EngineExportPayload(sessionID: "session-1", destinationPath: "/export")), ["session_id", "destination_path"]),
            (.settingsGet, .settingsGet, []),
            (.settingsReplace, .settingsReplace(EngineSettingsReplacePayload(expectedRevision: nil, settings: settings)), ["expected_revision", "settings"]),
            (.modelsPrepare, .modelsPrepare, []),
            (.shutdown, .shutdown, [])
        ]
        #expect(commands.count == 17)
        #expect(EngineCommandName.allCases.count == 17)

        for (name, command, payloadKeys) in commands {
            let request = try makeRequest(command)
            let data = try encoder().encode(request)
            let object = try jsonObject(data)
            #expect(Set(object.keys) == ["version", "request_id", "command", "payload"])
            #expect(object["version"] as? Int == 1)
            #expect(object["request_id"] as? String == "1")
            #expect(object["command"] as? String == name.rawValue)
            let payload = try #require(object["payload"] as? [String: Any])
            #expect(Set(payload.keys) == payloadKeys)
            #expect(try JSONDecoder().decode(EngineRequest.self, from: data) == request)
        }
    }

    @Test func nullablePayloadFieldsArePresentAndNull() throws {
        let sessionList = try EngineSessionListPayload(cursor: nil, limit: 1)
        let listObject = try jsonObject(encoder().encode(sessionList))
        #expect(Set(listObject.keys) == ["cursor", "limit"])
        #expect(listObject["cursor"] is NSNull)

        let transcript = try EngineTranscriptReadPayload(sessionID: "s", revision: nil, cursor: nil, limit: 1)
        let transcriptObject = try jsonObject(encoder().encode(transcript))
        #expect(Set(transcriptObject.keys) == ["session_id", "revision", "cursor", "limit"])
        #expect(transcriptObject["revision"] is NSNull)
        #expect(transcriptObject["cursor"] is NSNull)

        let settings = try sampleSettings(automaticExport: true, exportDestinationPath: nil)
        let settingsObject = try jsonObject(encoder().encode(settings))
        #expect(settingsObject["automatic_export"] as? Bool == true)
        #expect(settingsObject["export_destination_path"] is NSNull)

        let replace = EngineSettingsReplacePayload(expectedRevision: nil, settings: settings)
        let replaceObject = try jsonObject(encoder().encode(replace))
        #expect(replaceObject["expected_revision"] is NSNull)
        #expect(try JSONDecoder().decode(EngineSettingsReplacePayload.self, from: encoder().encode(replace)) == replace)
    }

    @Test func allSourceDeviceAndASRSizeCasesUseSpecifiedWireValues() throws {
        #expect(EngineSource.allCases.map(\.rawValue) == ["microphone", "system_audio"])
        #expect(EngineASRSize.allCases.map(\.rawValue) == ["0.6b", "1.7b"])
        #expect(EngineExecutionProvider.allCases.map(\.rawValue) == ["cpu"])
        #expect(EngineCommandName.allCases.map(\.rawValue) == [
            "hello", "state.get", "devices.list", "recording.start", "recording.stop",
            "session.import", "session.inspect", "session.reprocess", "session.retry_decisions", "session.list",
            "transcript.read", "transcript.watch", "session.export", "settings.get",
            "settings.replace", "models.prepare", "shutdown"
        ])

        for source in EngineSource.allCases {
            #expect(try JSONDecoder().decode(EngineSource.self, from: encoder().encode(source)) == source)
        }
        for size in EngineASRSize.allCases {
            #expect(try JSONDecoder().decode(EngineASRSize.self, from: encoder().encode(size)) == size)
        }
        let devices: [EngineDevice] = [.default, .id("endpoint-1")]
        let deviceObjects = try devices.map { try jsonObject(encoder().encode($0)) }
        #expect(deviceObjects[0]["kind"] as? String == "default")
        #expect(Set(deviceObjects[0].keys) == ["kind"])
        #expect(deviceObjects[1]["kind"] as? String == "id")
        #expect(deviceObjects[1]["id"] as? String == "endpoint-1")
        for device in devices {
            #expect(try JSONDecoder().decode(EngineDevice.self, from: encoder().encode(device)) == device)
        }
    }

    @Test func requestVersionIsValidatedByInitializerAndDecoder() throws {
        let id = try EngineID(decimal: "1")
        #expect(capturedEngineError { _ = try EngineRequest(version: 2, requestID: id, command: .hello) } == .unsupportedVersion(2))
        #expect(capturedEngineError { _ = try EngineRequest(version: 0, requestID: id, command: .hello) } == .unsupportedVersion(0))
        #expect(decodingEngineError(from: #"{"version":2,"request_id":"1","command":"hello","payload":{}}"#) == .unsupportedVersion(2))

        let invalidInteger = #"{"version":true,"request_id":"1","command":"hello","payload":{}}"#
        #expect(decodingFails(EngineRequest.self, from: Data(invalidInteger.utf8)))
    }

    @Test func unknownCommandsAndUnknownFieldsAreRejectedRecursively() throws {
        let unknownCommand = #"{"version":1,"request_id":"1","command":"future.command","payload":{}}"#
        #expect(decodingEngineError(from: unknownCommand) == .invalidJSON("unknown command"))

        var request = try requestObject(.hello)
        request["extra"] = true
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.devicesList(EngineDevicesListPayload(source: .microphone)))
        var payload = try #require(request["payload"] as? [String: Any])
        payload["extra"] = true
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.recordingStart(EngineRecordingStartPayload(source: .microphone, device: .default)))
        payload = try #require(request["payload"] as? [String: Any])
        var device = try #require(payload["device"] as? [String: Any])
        device["id"] = "unexpected"
        payload["device"] = device
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.settingsReplace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings())))
        payload = try #require(request["payload"] as? [String: Any])
        var settings = try #require(payload["settings"] as? [String: Any])
        settings["extra"] = false
        payload["settings"] = settings
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))
    }

    @Test func emptyCommandsRequireExactlyAnEmptyPayloadObject() throws {
        for command in ["hello", "state.get", "settings.get", "models.prepare", "shutdown"] {
            let empty = "{\"version\":1,\"request_id\":\"1\",\"command\":\"\(command)\",\"payload\":{}}"
            #expect(decodingSucceeds(EngineRequest.self, from: Data(empty.utf8)))
            let extra = "{\"version\":1,\"request_id\":\"1\",\"command\":\"\(command)\",\"payload\":{\"unexpected\":1}}"
            #expect(decodingFails(EngineRequest.self, from: Data(extra.utf8)))
            let null = "{\"version\":1,\"request_id\":\"1\",\"command\":\"\(command)\",\"payload\":null}"
            #expect(decodingFails(EngineRequest.self, from: Data(null.utf8)))
        }
    }

    @Test func requiredNullableKeysAndWrongTypesAreRejected() throws {
        var request = try requestObject(.sessionList(EngineSessionListPayload(cursor: nil, limit: 20)))
        var payload = try #require(request["payload"] as? [String: Any])
        payload.removeValue(forKey: "cursor")
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.transcriptRead(EngineTranscriptReadPayload(sessionID: "s", revision: nil, cursor: nil, limit: 20)))
        payload = try #require(request["payload"] as? [String: Any])
        payload["revision"] = NSNull()
        payload.removeValue(forKey: "cursor")
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.sessionList(EngineSessionListPayload(cursor: nil, limit: 20)))
        payload = try #require(request["payload"] as? [String: Any])
        payload["limit"] = true
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.settingsReplace(EngineSettingsReplacePayload(expectedRevision: nil, settings: sampleSettings())))
        payload = try #require(request["payload"] as? [String: Any])
        var settings = try #require(payload["settings"] as? [String: Any])
        settings["threads"] = true
        payload["settings"] = settings
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))

        request = try requestObject(.devicesList(EngineDevicesListPayload(source: .microphone)))
        payload = try #require(request["payload"] as? [String: Any])
        payload["source"] = NSNull()
        request["payload"] = payload
        #expect(decodingFails(EngineRequest.self, object: request))
    }

    @Test func settingsRequireEveryFieldAndRemainPortableUntilExplicitValidation() throws {
        let settings = try sampleSettings(threads: 4, automaticExport: true, exportDestinationPath: nil)
        let encoded = try encoder().encode(settings)
        let object = try jsonObject(encoded)
        #expect(Set(object.keys) == [
            "schema_version", "source", "device", "asr_size", "execution_provider", "threads",
            "low_heat", "decisions_enabled", "automatic_export", "export_destination_path"
        ])
        #expect(object["export_destination_path"] is NSNull)
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
        #expect(capturedEngineError { _ = try sampleSettings(schemaVersion: 2) } == .invalidJSON("schema_version must be 1"))
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
        #expect(decodingFails(EngineExecutionProvider.self, from: Data("\"future\"".utf8)))
    }
}

private func sampleSettings(
    schemaVersion: Int = 1,
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

private func makeRequest(_ command: EngineCommand) throws -> EngineRequest {
    try EngineRequest(version: 1, requestID: EngineID(decimal: "1"), command: command)
}

private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requestObject(_ command: EngineCommand) throws -> [String: Any] {
    try jsonObject(encoder().encode(makeRequest(command)))
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

private func decodingEngineError(from string: String) -> EngineProtocolError? {
    do {
        _ = try JSONDecoder().decode(EngineRequest.self, from: Data(string.utf8))
        return nil
    } catch let error as EngineProtocolError {
        return error
    } catch {
        return nil
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
