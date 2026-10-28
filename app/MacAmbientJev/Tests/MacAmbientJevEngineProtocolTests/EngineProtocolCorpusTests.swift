import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCorpusTests {
    @Test func everyCorpusRecordRoundTripsByteIdentically() throws {
        let records = try wireCorpusRecords()
        #expect(records.count == 142)
        for record in records {
            let root = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if root["event"] != nil {
                #expect(try EngineCodec.encodeOutput(EngineCodec.decodeOutput(record)) == record + Data([0x0A]))
            } else {
                #expect(try EngineCodec.encodeRequest(EngineCodec.decodeRequest(record)) == record + Data([0x0A]))
            }
        }
    }

    @Test func rejectsEveryNegativeCorpusRecord() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wire-v1-negative.ndjson")
        let bytes = try Data(contentsOf: url)
        guard bytes.last == 0x0A else { throw CorpusFixtureError.missingFinalLineFeed }
        let records = bytes.split(separator: 0x0A)
        #expect(records.count == 130)

        for rawRecord in records {
            let record = Data(rawRecord)
            let root = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if root["event"] != nil {
                #expect(throws: (any Error).self) { try EngineCodec.decodeOutput(record) }
            } else {
                #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(record) }
            }
        }
    }

    @Test func recursivelyRejectsUnknownMissingNullAndWrongCategoryFields() throws {
        let records = try wireCorpusRecords()
        var mutationCount = 0
        var acceptedMutations: [String] = []

        for record in records {
            let root = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            let isOutput = root.keys.contains("event")
            let nodes = objectNodes(in: root)

            for node in nodes {
                let unknownName = "__corpus_unknown_\(mutationCount)"
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
    }

    @Test func rejectsUnknownNamesAliasesNoncanonicalIDsAndWrongVersions() {
        let unknownCommand = #"{"version":1,"request_id":"1","command":"future.command","payload":{}}"#
        let unknownEvent = #"{"version":1,"sequence":"1","request_id":null,"event":"future.event","payload":{}}"#
        let unknownResultCommand = #"{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"future.result","result":{}}}"#
        let unknownResultEnum = #"{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"session.list","result":{"sessions":[{"folder_id":"f","session_id":"s","status":"future","error":null}],"next_cursor":null}}}"#
        let camelCaseAlias = #"{"version":1,"requestId":"1","command":"hello","payload":{}}"#
        let wrongRequestVersion = #"{"version":2,"request_id":"1","command":"hello","payload":{}}"#
        let wrongOutputVersion = #"{"version":2,"sequence":"1","request_id":null,"event":"state","payload":{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[],"presentation":{"recording_status_text":"待機中","recording_tone":"neutral","preparation_phase":"idle","preparation_status_text":null,"recovery_status_text":null,"processing_status_text":null,"live_failure_notices":[],"silence_warning_active":false,"silence_warning_text":null,"audio_gap_count":0,"audio_gap_text":null,"processing_indicator":"idle"}}}"#

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

private enum CorpusFixtureError: Error {
    case missingFinalLineFeed
}

private enum CorpusPathComponent {
    case key(String)
    case index(Int)
}

private struct CorpusObjectNode {
    let path: [CorpusPathComponent]
    let object: [String: Any]
}

private enum CorpusObjectMutation {
    case add(key: String, value: Any)
    case remove(key: String)
    case set(key: String, value: Any)
}

func wireCorpusRecords() throws -> [Data] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wire-v1.ndjson")
    let bytes = try Data(contentsOf: url)
    guard bytes.last == 0x0A else { throw CorpusFixtureError.missingFinalLineFeed }
    var framer = EngineLineFramer()
    let records = try framer.append(bytes)
    try framer.finish()
    return records
}

private func objectNodes(in value: Any) -> [CorpusObjectNode] {
    var result: [CorpusObjectNode] = []
    collectObjectNodes(value, path: [], into: &result)
    return result
}

private func collectObjectNodes(_ value: Any, path: [CorpusPathComponent], into result: inout [CorpusObjectNode]) {
    if let object = value as? [String: Any] {
        result.append(CorpusObjectNode(path: path, object: object))
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
    _ mutation: CorpusObjectMutation,
    at objectPath: [CorpusPathComponent],
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
    at path: [CorpusPathComponent],
    applying mutation: CorpusObjectMutation
) throws -> Any {
    guard let first = path.first else {
        guard var object = value as? [String: Any] else { throw CorpusFixtureError.missingFinalLineFeed }
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
            throw CorpusFixtureError.missingFinalLineFeed
        }
        object[key] = try rebuild(child, at: remaining, applying: mutation)
        return object
    case let .index(index):
        guard var array = value as? [Any], array.indices.contains(index) else {
            throw CorpusFixtureError.missingFinalLineFeed
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
    throw CorpusFixtureError.missingFinalLineFeed
}

private func isNullableField(
    _ key: String,
    in object: [String: Any],
    objectPath: [CorpusPathComponent],
    root: [String: Any]
) -> Bool {
    let keys = Set(object.keys)
    func has(_ expected: Set<String>) -> Bool { keys == expected }
    let isSessionSummary = has([
        "folder_id", "session_id", "status", "error", "display_name", "status_text",
        "folder_path", "export_path", "can_reprocess", "can_retry_decisions", "can_export", "metadata",
    ])
    let isTranscriptRowDetailsPage = object["clause_state_text"] != nil && object["speakers"] != nil
    let isPresentationState = has([
        "recording_status_text", "recording_tone", "preparation_phase", "preparation_status_text",
        "recovery_status_text", "processing_status_text", "live_failure_notices", "silence_warning_active",
        "silence_warning_text", "audio_gap_count", "audio_gap_text", "processing_indicator",
    ])
    let isProfileHardwareGPU = has([
        "kind", "name", "adapter_id", "device_id", "driver_version", "dedicated_vram_bytes",
    ])
    let isProfileEvaluation = has([
        "initial_size", "recommend_large", "reason", "explanation", "measured_rtf", "predicted_rtf",
        "decision_state", "calibration_id",
    ])

    if key == "request_id" {
        if objectPath.isEmpty { return root["event"] != nil }
        if has(["code", "message", "stage", "request_id", "session_id", "severity", "recovery_action", "details", "cleanup_errors"]) { return true }
    }
    if key == "export_destination_path" { return true }
    if key == "expected_revision" { return has(["expected_revision", "settings"]) }
    if key == "cursor" {
        if root["command"] as? String == "session.list", has(["cursor", "limit"]) { return true }
        if root["command"] as? String == "transcript.read", has(["session_id", "revision", "cursor", "limit"]) { return true }
        if root["command"] as? String == "transcript.row_details" { return true }
    }
    if key == "revision", root["command"] as? String == "transcript.read",
       has(["session_id", "revision", "cursor", "limit"]) { return true }
    if key == "session_id" {
        if has(["code", "message", "stage", "request_id", "session_id", "severity", "recovery_action", "details", "cleanup_errors"]) { return true }
        if isSessionSummary { return true }
        if has(["stage", "completed_units", "total_units", "session_id"]) { return true }
    }
    if key == "error", isSessionSummary { return true }
    if key == "export_path", isSessionSummary { return true }
    if key == "path" || key == "device_id", has(["domain", "code", "message", "path", "device_id"]) { return true }
    if ["preparation_status_text", "recovery_status_text", "processing_status_text", "silence_warning_text", "audio_gap_text"].contains(key),
       isPresentationState { return true }
    if key == "recording", has([
        "revision", "screen", "setup", "profile_setup", "resource_protection", "recovery", "recording",
        "queue", "failures", "presentation",
    ]) { return true }
    if key == "dedicated_vram_bytes", isProfileHardwareGPU { return true }
    if (key == "measured_rtf" || key == "predicted_rtf" || key == "calibration_id"), isProfileEvaluation { return true }
    if key == "evaluation", has(["evaluation"]) { return true }
    if key == "default_device_id", has(["source", "devices", "default_device_id"]) { return true }
    if key == "previous_cursor" {
        if has(["sessions", "next_cursor", "previous_cursor"]) { return true }
        if has(["session_id", "revision", "rows", "next_cursor", "previous_cursor"]) { return true }
        if isTranscriptRowDetailsPage { return true }
    }
    if key == "next_cursor" {
        if has(["sessions", "next_cursor", "previous_cursor"]) { return true }
        if has(["session_id", "revision", "rows", "next_cursor", "previous_cursor"]) { return true }
        if has(["session_id", "revision", "kind", "rows", "removed_row_ids", "next_cursor"]) { return true }
        if isTranscriptRowDetailsPage { return true }
    }
    if key == "clause_state", has(["row_id", "start_ms", "end_ms", "text", "headings", "clause_state"]) { return true }
    if key == "total_units", has(["stage", "completed_units", "total_units", "session_id"]) { return true }
    return false
}

private func pathName(_ path: [CorpusPathComponent]) -> String {
    "$" + path.map { component in
        switch component {
        case let .key(key): ".\(key)"
        case let .index(index): "[\(index)]"
        }
    }.joined()
}
