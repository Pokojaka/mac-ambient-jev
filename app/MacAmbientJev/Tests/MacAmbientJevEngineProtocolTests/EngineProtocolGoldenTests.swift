import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolGoldenTests {
    @Test func canonicalFixtureRoundTripsAndCoversEveryCommandAndEvent() throws {
        let records = try goldenRecords()
        #expect(records.count == 46)
        #expect(records.allSatisfy { !$0.isEmpty })
        print("Golden fixture records: \(records.count)")

        var requestCommands = Set<String>()
        var completedCommands = Set<String>()
        var eventNames = Set<String>()
        var rowKinds = Set<String>()

        for record in records {
            let metadata = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if metadata.keys.contains("event") {
                let output = try EngineCodec.decodeOutput(record)
                #expect(try EngineCodec.encodeOutput(output) == record + Data([0x0A]))
                eventNames.insert(output.event.name.rawValue)
                if case let .completed(result) = output.event {
                    completedCommands.insert(result.command.rawValue)
                }
                if case let .rows(payload) = output.event {
                    rowKinds.insert(payload.kind.rawValue)
                }
            } else {
                let request = try EngineCodec.decodeRequest(record)
                #expect(try EngineCodec.encodeRequest(request) == record + Data([0x0A]))
                requestCommands.insert(request.command.name.rawValue)
            }
        }

        #expect(requestCommands == Set(EngineCommandName.allCases.map(\.rawValue)))
        #expect(completedCommands == Set(EngineCommandName.allCases.map(\.rawValue)))
        #expect(eventNames == Set(EngineEventName.allCases.map(\.rawValue)))
        #expect(rowKinds == Set(EngineRowsKind.allCases.map(\.rawValue)))
    }

    @Test func fixturePreservesRepresentativeTypedSemantics() throws {
        let records = try goldenRecords()
        var sawUnconfiguredAutoExportReplacement = false
        var sawMicrophoneDefaultSelector = false
        var sawSystemAudioIDSelector = false
        var sawUInt64Maximum = false
        var sawLiveBusyState = false
        var sawConfiguredSettingsResult = false
        var sawEndpointDefault = false
        var sawUnreadableAndReadableSessions = false
        var sawEscapedJapaneseEmojiRow = false
        var sawNullClauseState = false
        var sawKnownClauseState = false
        var sawCorrelatedError = false
        var sawUnsolicitedError = false
        var sawNativeErrorDetails = false
        var sawKnownProgressTotal = false
        var sawUnknownProgressTotal = false
        var sawNonNullRevisionAndCursor = false
        var rowLabels = Set<String>()

        for record in records {
            let metadata = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if metadata.keys.contains("event") {
                let output = try EngineCodec.decodeOutput(record)
                if output.sequence.value == UInt64.max || output.requestID?.value == UInt64.max {
                    sawUInt64Maximum = true
                }
                switch output.event {
                case let .completed(result):
                    switch result {
                    case let .devicesList(devices):
                        #expect(devices.source == .systemAudio)
                        #expect(devices.devices.contains { $0.id == "wasapi-loopback-42" && $0.isDefault })
                        #expect(devices.defaultDeviceID == "wasapi-loopback-42")
                        sawEndpointDefault = true
                    case let .settingsGet(value), let .settingsReplace(value):
                        #expect(value.settings.automaticExport)
                        #expect(value.settings.exportDestinationPath == "D:/Ambient Exports")
                        sawConfiguredSettingsResult = true
                    case let .sessionList(value):
                        let unreadable = try #require(value.sessions.first { $0.status == .unreadable })
                        #expect(unreadable.folderID == "stable-folder-id-corrupt-metadata-17")
                        #expect(unreadable.sessionID == nil)
                        #expect(unreadable.error != nil)
                        let readable = try #require(value.sessions.first { $0.status == .finalized })
                        #expect(readable.sessionID == "session-finalized-2025-03-08T10-22-31Z")
                        sawUnreadableAndReadableSessions = true
                        #expect(value.nextCursor == "folder-page-cursor-2")
                        sawNonNullRevisionAndCursor = true
                    case let .transcriptRead(page):
                        #expect(page.revision.value == 184)
                        #expect(page.nextCursor == "rows-cursor-after-2")
                        sawNonNullRevisionAndCursor = true
                    default:
                        break
                    }
                case let .rows(payload):
                    for row in payload.rows {
                        rowLabels.formUnion(row.headings.map(\.rawValue))
                        if row.text == "おはよう、世界😀\n次の行です" {
                            sawEscapedJapaneseEmojiRow = true
                        }
                        if row.clauseState == nil { sawNullClauseState = true }
                        if row.clauseState != nil { sawKnownClauseState = true }
                    }
                case let .error(failure):
                    if let requestID = output.requestID {
                        #expect(failure.requestID == requestID)
                        sawCorrelatedError = true
                        if requestID.value == 7 {
                            let detail = try #require(failure.details.first)
                            #expect(detail.path == "D:/Recordings/meeting.wav")
                            #expect(failure.cleanupErrors.count == 1)
                            #expect(failure.cleanupErrors[0].message == "一時ファイルの削除に失敗しました")
                        } else if requestID.value == 4 {
                            let detail = try #require(failure.details.first)
                            #expect(detail.path?.contains("/sessions/session-live/audio.wav") == true)
                            #expect(detail.deviceID == "wasapi-mic-17")
                            #expect(failure.cleanupErrors.count == 1)
                            #expect(failure.cleanupErrors[0].message == "録音ハンドルの解放にも失敗しました")
                            sawNativeErrorDetails = true
                        } else {
                            #expect(Bool(false), "Unexpected correlated error request ID \(requestID.rawValue)")
                        }
                    } else {
                        #expect(failure.requestID == nil)
                        #expect(failure.message.contains("バックグラウンド処理"))
                        sawUnsolicitedError = true
                    }
                case let .state(state):
                    #expect(state.screen == .live)
                    #expect(state.recording?.sessionID == "session-live")
                    #expect(!state.queue.isEmpty)
                    #expect(!state.failures.isEmpty)
                    let failure = try #require(state.failures.first)
                    let detail = try #require(failure.details.first)
                    #expect(detail.path?.contains("/sessions/session-live/audio.wav") == true)
                    #expect(detail.deviceID == "wasapi-mic-17")
                    #expect(!failure.cleanupErrors.isEmpty)
                    sawLiveBusyState = true
                case let .ready(payload):
                    #expect(payload.state.setup == .settingsRequired)
                    #expect(payload.state.recovery == .pending)
                case let .progress(payload):
                    if payload.totalUnits == 4 { sawKnownProgressTotal = true }
                    if payload.totalUnits == nil { sawUnknownProgressTotal = true }
                case .accepted:
                    break
                }
            } else {
                let request = try EngineCodec.decodeRequest(record)
                if request.requestID.value == UInt64.max { sawUInt64Maximum = true }
                switch request.command {
                case let .settingsReplace(payload):
                    #expect(payload.expectedRevision == nil)
                    #expect(payload.settings.automaticExport)
                    #expect(payload.settings.exportDestinationPath == nil)
                    sawUnconfiguredAutoExportReplacement = true
                case let .recordingStart(payload):
                    switch (payload.source, payload.device) {
                    case (.microphone, .default): sawMicrophoneDefaultSelector = true
                    case (.systemAudio, .id("wasapi-loopback-42")): sawSystemAudioIDSelector = true
                    default: break
                    }
                case let .transcriptRead(payload):
                    #expect(payload.revision?.value == 184)
                    #expect(payload.cursor == "rows-cursor-1")
                    sawNonNullRevisionAndCursor = true
                case .hello, .stateGet, .devicesList, .recordingStop, .sessionImport, .sessionReprocess,
                     .sessionRetryDecisions, .sessionList, .transcriptWatch, .sessionExport, .settingsGet,
                     .modelsPrepare, .shutdown:
                    break
                }
            }
        }

        #expect(sawUnconfiguredAutoExportReplacement)
        #expect(sawMicrophoneDefaultSelector)
        #expect(sawSystemAudioIDSelector)
        #expect(sawUInt64Maximum)
        #expect(sawLiveBusyState)
        #expect(sawConfiguredSettingsResult)
        #expect(sawEndpointDefault)
        #expect(sawUnreadableAndReadableSessions)
        #expect(sawEscapedJapaneseEmojiRow)
        #expect(sawNullClauseState)
        #expect(sawKnownClauseState)
        #expect(sawCorrelatedError)
        #expect(sawUnsolicitedError)
        #expect(sawNativeErrorDetails)
        #expect(sawKnownProgressTotal)
        #expect(sawUnknownProgressTotal)
        #expect(sawNonNullRevisionAndCursor)
        #expect(rowLabels == Set(EngineSpeakerLabel.allCases.map(\.rawValue)))
    }

    @Test func recursivelyRejectsUnknownMissingNullAndWrongCategoryFields() throws {
        let records = try goldenRecords()
        var mutationCount = 0
        var acceptedMutations: [String] = []

        for record in records {
            let root = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            let isOutput = root.keys.contains("event")
            let nodes = objectNodes(in: root)

            for node in nodes {
                let unknownName = "__golden_unknown_\(mutationCount)"
                try verifyMutation(
                    .add(key: unknownName, value: "reject"),
                    at: node.path,
                    root: root,
                    record: record,
                    isOutput: isOutput,
                    label: "unknown \(pathName(node.path)).\(unknownName)",
                    mutationCount: &mutationCount,
                    acceptedMutations: &acceptedMutations
                )

                for key in node.object.keys.sorted() {
                    guard let value = node.object[key] else { continue }
                    let fieldPath = node.path + [.key(key)]
                    try verifyMutation(
                        .remove(key: key),
                        at: node.path,
                        root: root,
                        record: record,
                        isOutput: isOutput,
                        label: "missing \(pathName(fieldPath))",
                        mutationCount: &mutationCount,
                        acceptedMutations: &acceptedMutations
                    )

                    if !(value is NSNull), !isNullableField(key, in: node.object, objectPath: node.path, root: root) {
                        try verifyMutation(
                            .set(key: key, value: NSNull()),
                            at: node.path,
                            root: root,
                            record: record,
                            isOutput: isOutput,
                            label: "null \(pathName(fieldPath))",
                            mutationCount: &mutationCount,
                            acceptedMutations: &acceptedMutations
                        )
                    }

                    let incompatible = try incompatibleJSONCategory(for: value)
                    try verifyMutation(
                        .set(key: key, value: incompatible),
                        at: node.path,
                        root: root,
                        record: record,
                        isOutput: isOutput,
                        label: "wrong category \(pathName(fieldPath))",
                        mutationCount: &mutationCount,
                        acceptedMutations: &acceptedMutations
                    )
                }
            }
        }

        #expect(mutationCount > 500)
        #expect(acceptedMutations.isEmpty, "Codec accepted mutations: \(acceptedMutations.prefix(20).joined(separator: ", "))")
        print("Recursive rejection mutation count: \(mutationCount)")
    }

    @Test func rejectsUnknownNamesAliasesNoncanonicalIDsAndWrongVersions() {
        let unknownCommand = #"{"version":1,"request_id":"1","command":"future.command","payload":{}}"#
        let unknownEvent = #"{"version":1,"sequence":"1","request_id":null,"event":"future.event","payload":{}}"#
        let unknownResultCommand = #"{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"future.result","result":{}}}"#
        let unknownResultEnum = #"{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"session.list","result":{"sessions":[{"folder_id":"f","session_id":"s","status":"future","error":null}],"next_cursor":null}}}"#
        let camelCaseAlias = #"{"version":1,"requestId":"1","command":"hello","payload":{}}"#
        let wrongRequestVersion = #"{"version":2,"request_id":"1","command":"hello","payload":{}}"#
        let wrongOutputVersion = #"{"version":2,"sequence":"1","request_id":null,"event":"state","payload":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[]}}"#

        #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(Data(unknownCommand.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(Data(unknownEvent.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(Data(unknownResultCommand.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(Data(unknownResultEnum.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(Data(camelCaseAlias.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(Data(wrongRequestVersion.utf8)) }
        #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(Data(wrongOutputVersion.utf8)) }

        for invalidID in ["", "0", "00", "01", "+1", "-1", "18446744073709551616"] {
            let line = #"{"version":1,"request_id":"\#(invalidID)","command":"hello","payload":{}}"#
            #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(Data(line.utf8)) }
        }
    }
}

private enum GoldenFixtureError: Error {
    case missingFinalLineFeed
}

private enum GoldenPathComponent {
    case key(String)
    case index(Int)
}

private struct GoldenObjectNode {
    let path: [GoldenPathComponent]
    let object: [String: Any]
}

private enum GoldenObjectMutation {
    case add(key: String, value: Any)
    case remove(key: String)
    case set(key: String, value: Any)
}

private func goldenRecords() throws -> [Data] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wire-v1.ndjson")
    let bytes = try Data(contentsOf: url)
    guard bytes.last == 0x0A else { throw GoldenFixtureError.missingFinalLineFeed }
    var framer = EngineLineFramer()
    let records = try framer.append(bytes)
    try framer.finish()
    return records
}

private func objectNodes(in value: Any) -> [GoldenObjectNode] {
    var result: [GoldenObjectNode] = []
    collectObjectNodes(value, path: [], into: &result)
    return result
}

private func collectObjectNodes(_ value: Any, path: [GoldenPathComponent], into result: inout [GoldenObjectNode]) {
    if let object = value as? [String: Any] {
        result.append(GoldenObjectNode(path: path, object: object))
        for key in object.keys.sorted() {
            if let child = object[key] {
                collectObjectNodes(child, path: path + [.key(key)], into: &result)
            }
        }
    } else if let array = value as? [Any] {
        for (index, child) in array.enumerated() {
            collectObjectNodes(child, path: path + [.index(index)], into: &result)
        }
    }
}

private func verifyMutation(
    _ mutation: GoldenObjectMutation,
    at objectPath: [GoldenPathComponent],
    root: [String: Any],
    record: Data,
    isOutput: Bool,
    label: String,
    mutationCount: inout Int,
    acceptedMutations: inout [String]
) throws {
    mutationCount += 1
    let mutated = try rebuild(root, at: objectPath, applying: mutation)
    let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
    let rejected: Bool
    do {
        if isOutput {
            _ = try EngineCodec.decodeOutput(data)
        } else {
            _ = try EngineCodec.decodeRequest(data)
        }
        rejected = false
    } catch {
        rejected = true
    }
    if !rejected, acceptedMutations.count < 20 {
        acceptedMutations.append("record \(record.count) bytes: \(label)")
    }
}

private func rebuild(
    _ value: Any,
    at path: [GoldenPathComponent],
    applying mutation: GoldenObjectMutation
) throws -> Any {
    guard let first = path.first else {
        guard var object = value as? [String: Any] else { throw GoldenFixtureError.missingFinalLineFeed }
        switch mutation {
        case let .add(key, value), let .set(key, value): object[key] = value
        case let .remove(key): object.removeValue(forKey: key)
        }
        return object
    }

    let remaining = Array(path.dropFirst())
    switch first {
    case let .key(key):
        guard var object = value as? [String: Any], let child = object[key] else {
            throw GoldenFixtureError.missingFinalLineFeed
        }
        object[key] = try rebuild(child, at: remaining, applying: mutation)
        return object
    case let .index(index):
        guard var array = value as? [Any], array.indices.contains(index) else {
            throw GoldenFixtureError.missingFinalLineFeed
        }
        array[index] = try rebuild(array[index], at: remaining, applying: mutation)
        return array
    }
}

private func incompatibleJSONCategory(for value: Any) throws -> Any {
    if value is NSNull { return [Any]() }
    if value is String { return [String: Any]() }
    if value is [Any] { return [String: Any]() }
    if value is [String: Any] { return [Any]() }
    if value is NSNumber { return "__wrong_json_category__" }
    throw GoldenFixtureError.missingFinalLineFeed
}

private func isNullableField(
    _ key: String,
    in object: [String: Any],
    objectPath: [GoldenPathComponent],
    root: [String: Any]
) -> Bool {
    let keys = Set(object.keys)
    func has(_ expected: Set<String>) -> Bool { keys == expected }

    if key == "request_id" {
        if objectPath.isEmpty { return root["event"] != nil }
        if has(["code", "message", "stage", "request_id", "session_id", "severity", "recovery_action", "details", "cleanup_errors"]) { return true }
    }
    if key == "export_destination_path" { return true }
    if key == "expected_revision" { return has(["expected_revision", "settings"]) }
    if key == "cursor" {
        if root["command"] as? String == "session.list", has(["cursor", "limit"]) { return true }
        if root["command"] as? String == "transcript.read", has(["session_id", "revision", "cursor", "limit"]) { return true }
    }
    if key == "revision", root["command"] as? String == "transcript.read",
       has(["session_id", "revision", "cursor", "limit"]) { return true }
    if key == "session_id" {
        if has(["code", "message", "stage", "request_id", "session_id", "severity", "recovery_action", "details", "cleanup_errors"]) { return true }
        if has(["folder_id", "session_id", "status", "error"]) { return true }
        if has(["stage", "completed_units", "total_units", "session_id"]) { return true }
    }
    if key == "error", has(["folder_id", "session_id", "status", "error"]) { return true }
    if key == "path" || key == "device_id", has(["domain", "code", "message", "path", "device_id"]) { return true }
    if key == "recording", has(["revision", "screen", "setup", "recovery", "recording", "queue", "failures"]) { return true }
    if key == "default_device_id", has(["source", "devices", "default_device_id"]) { return true }
    if key == "next_cursor" {
        if has(["sessions", "next_cursor"]) { return true }
        if has(["session_id", "revision", "rows", "next_cursor"]) { return true }
        if has(["session_id", "revision", "kind", "rows", "removed_row_ids", "next_cursor"]) { return true }
    }
    if key == "clause_state", has(["row_id", "start_ms", "end_ms", "text", "headings", "clause_state"]) { return true }
    if key == "total_units", has(["stage", "completed_units", "total_units", "session_id"]) { return true }
    return false
}

private func pathName(_ path: [GoldenPathComponent]) -> String {
    "$" + path.map { component in
        switch component {
        case let .key(key): ".\(key)"
        case let .index(index): "[\(index)]"
        }
    }.joined()
}
