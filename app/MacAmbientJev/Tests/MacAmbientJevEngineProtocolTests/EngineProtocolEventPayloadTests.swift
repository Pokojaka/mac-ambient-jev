import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolEventPayloadTests {
    @Test func deviceDefaultsAndCapabilitiesAreValidated() throws {
        let first = try EngineDeviceInfo(id: "a", name: "A", isDefault: true)
        let second = try EngineDeviceInfo(id: "b", name: "B", isDefault: false)
        #expect(throws: (any Error).self) { try EngineDevicesResult(source: .microphone, devices: [first], defaultDeviceID: nil) }
        #expect(throws: (any Error).self) { try EngineDevicesResult(source: .microphone, devices: [first], defaultDeviceID: "b") }
        #expect(throws: (any Error).self) { try EngineDevicesResult(source: .microphone, devices: [first, second], defaultDeviceID: "b") }
        let secondDefault = try EngineDeviceInfo(id: "b", name: "B", isDefault: true)
        #expect(throws: (any Error).self) { try EngineDevicesResult(source: .microphone, devices: [first, secondDefault], defaultDeviceID: "a") }
        #expect(throws: (any Error).self) {
            try EngineDevicesResult(source: .microphone, devices: [second, second], defaultDeviceID: nil)
        }
        #expect(throws: (any Error).self) { try EngineDeviceInfo(id: "", name: "A", isDefault: false) }
        #expect(throws: (any Error).self) { try EngineDeviceInfo(id: "a", name: "", isDefault: false) }
        #expect(throws: (any Error).self) { try EngineRecordingState(sessionID: "s", source: .microphone, device: .id(""), phase: .recording) }

        #expect(throws: (any Error).self) {
            try EngineCapabilities(sources: [], asrSizes: [.small], executionProviders: [.cpu], maximumThreads: 1, automaticInputVolume: .none, thermalMonitoring: .none)
        }
        #expect(throws: (any Error).self) {
            try EngineCapabilities(sources: [.microphone, .microphone], asrSizes: [.small], executionProviders: [.cpu], maximumThreads: 1, automaticInputVolume: .none, thermalMonitoring: .none)
        }
        #expect(throws: (any Error).self) {
            try EngineCapabilities(sources: [.microphone], asrSizes: [.small], executionProviders: [.cpu], maximumThreads: 5, automaticInputVolume: .none, thermalMonitoring: .none)
        }

        #expect(throws: (any Error).self) { _ = try encoder().encode(EngineDevice.id("")) }
    }

    @Test func largeDeviceCollectionsRejectDuplicateLastID() throws {
        let devices = try (0..<10_000).map { index in
            try EngineDeviceInfo(id: "device-\(index)", name: "Device \(index)", isDefault: false)
        }
        #expect(try EngineDevicesResult(source: .microphone, devices: devices, defaultDeviceID: nil).devices.count == 10_000)
        #expect(throws: (any Error).self) {
            try EngineDevicesResult(source: .microphone, devices: devices + [devices[0]], defaultDeviceID: nil)
        }
    }

    @Test func boundedCollectionsAcceptLimitsAndRejectOverflowAndDuplicates() throws {
        let operation = try EngineQueuedOperation(sessionID: "s", stage: .asr)
        let state16 = try EngineState(revision: engineID(1), screen: .idle, setup: .ready, profileSetup: .init(evaluation: nil, operation: nil), resourceProtection: try .init(holdReasons: []), recovery: .completed, recording: nil, queue: Array(repeating: operation, count: 16), failures: [], presentation: try engineTestPresentation())
        #expect(state16.queue.count == 16)
        #expect(throws: (any Error).self) {
            try EngineState(revision: engineID(1), screen: .idle, setup: .ready, profileSetup: .init(evaluation: nil, operation: nil), resourceProtection: try .init(holdReasons: []), recovery: .completed, recording: nil, queue: Array(repeating: operation, count: 17), failures: [], presentation: try engineTestPresentation())
        }
        #expect(throws: (any Error).self) { try EngineQueuedOperation(sessionID: "", stage: .asr) }

        let sessions100 = try (0..<100).map { index in
            try makeSummary(
                folderID: "folder-\(index)", sessionID: "session-\(index)", status: .queued, error: nil,
                exportPath: nil, canReprocess: true, canRetryDecisions: true, canExport: true,
                metadata: .readable(createdAt: Double(index), source: .microphone, audio: .available, hasTranscript: false)
            )
        }
        #expect(try EngineSessionListResult(sessions: sessions100, nextCursor: nil, previousCursor: nil).sessions.count == 100)
        let session101 = try makeSummary(
            folderID: "folder-100", sessionID: "session-100", status: .queued, error: nil,
            exportPath: nil, canReprocess: true, canRetryDecisions: true, canExport: true,
            metadata: .readable(createdAt: 100, source: .microphone, audio: .available, hasTranscript: false)
        )
        #expect(throws: (any Error).self) { try EngineSessionListResult(sessions: sessions100 + [session101], nextCursor: nil, previousCursor: nil) }
        #expect(throws: (any Error).self) { try EngineSessionListResult(sessions: [sessions100[0], sessions100[0]], nextCursor: nil, previousCursor: nil) }
        #expect(throws: (any Error).self) { try EngineSessionListResult(sessions: [], nextCursor: "", previousCursor: nil) }

        let rows200 = try (0..<200).map { try makeRow("row-\($0)") }
        #expect(try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: rows200, nextCursor: nil, previousCursor: nil).rows.count == 200)
        #expect(throws: (any Error).self) { try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: rows200 + [try makeRow("row-200")], nextCursor: nil, previousCursor: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: [rows200[0], rows200[0]], nextCursor: nil, previousCursor: nil) }

        let rows199 = Array(rows200.prefix(199))
        #expect(try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: rows199, removedRowIDs: ["removed"], nextCursor: nil).rows.count == 199)
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: rows200, removedRowIDs: ["removed"], nextCursor: nil)
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: [], removedRowIDs: ["x", "x"], nextCursor: nil)
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: [rows200[0]], removedRowIDs: [rows200[0].rowID], nextCursor: nil)
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: [], removedRowIDs: [""], nextCursor: nil)
        }
    }

    @Test func rowsKindsValidateSemanticsAndRowFields() throws {
        let row = try sampleRow()
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .snapshot, rows: [], removedRowIDs: ["old"], nextCursor: nil)
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .changes, rows: [row], removedRowIDs: [], nextCursor: "more")
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .reloadRequired, rows: [row], removedRowIDs: [], nextCursor: nil)
        }
        #expect(throws: (any Error).self) {
            try EngineRowsPayload(sessionID: "s", revision: engineID(1), kind: .reloadRequired, rows: [], removedRowIDs: [], nextCursor: "more")
        }
        #expect(throws: (any Error).self) { try EngineTranscriptRow(rowID: "", startMS: 0, endMS: 0, text: "x", headings: [], clauseState: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptRow(rowID: "r", startMS: -1, endMS: 0, text: "x", headings: [], clauseState: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptRow(rowID: "r", startMS: 2, endMS: 1, text: "x", headings: [], clauseState: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptRow(rowID: "r", startMS: 0, endMS: 0, text: " \n\t", headings: [], clauseState: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptPage(sessionID: "", revision: engineID(1), rows: [], nextCursor: nil, previousCursor: nil) }
        #expect(throws: (any Error).self) { try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: [], nextCursor: "", previousCursor: nil) }
    }

    @Test func unreadableSummariesEnforceMetadataIdentityAndActionInvariants() throws {
        let failure = try sampleFailure()
        let unreadableMetadata = EngineSessionMetadata.unreadable(reason: "manifest is unreadable")
        let readableMetadata = EngineSessionMetadata.readable(
            createdAt: 1_700_000_000, source: .microphone, audio: .available, hasTranscript: true
        )
        let unreadable = try makeSummary(
            folderID: "stable-folder", sessionID: nil, status: .unreadable, error: failure,
            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
            metadata: unreadableMetadata
        )
        let object = try jsonObject(encoder().encode(unreadable))
        #expect(object["folder_id"] as? String == "stable-folder")
        #expect(object["session_id"] is NSNull)
        #expect(object["error"] is [String: Any])
        #expect(object["export_path"] is NSNull)
        let unreadableWithKnownID = try makeSummary(
            folderID: "folder-with-known-id", sessionID: "known-id", status: .unreadable, error: failure,
            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
            metadata: unreadableMetadata
        )
        #expect(try roundTrip(unreadableWithKnownID) == unreadableWithKnownID)
        let knownIDObject = try jsonObject(encoder().encode(unreadableWithKnownID))
        #expect(knownIDObject["session_id"] as? String == "known-id")

        var missingSessionID = object
        missingSessionID.removeValue(forKey: "session_id")
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(missingSessionID), as: UTF8.self)))
        var nullSessionID = object
        nullSessionID["session_id"] = NSNull()
        #expect(try JSONDecoder().decode(EngineSessionSummary.self, from: jsonData(nullSessionID)) == unreadable)
        var emptySessionID = object
        emptySessionID["session_id"] = ""
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(emptySessionID), as: UTF8.self)))
        var wrongTypeSessionID = object
        wrongTypeSessionID["session_id"] = 7
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(wrongTypeSessionID), as: UTF8.self)))
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: nil, status: .unreadable, error: nil,
                            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
                            metadata: unreadableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: nil, status: .unreadable, error: failure,
                            exportPath: "/exports/inapplicable", canReprocess: false, canRetryDecisions: false, canExport: false,
                            metadata: unreadableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: nil, status: .unreadable, error: failure,
                            exportPath: nil, canReprocess: true, canRetryDecisions: false, canExport: false,
                            metadata: unreadableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: nil, status: .unreadable, error: failure,
                            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
                            metadata: readableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: nil, status: .failed, error: failure,
                            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
                            metadata: unreadableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "folder", sessionID: "real-id", status: .failed, error: failure,
                            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
                            metadata: unreadableMetadata)
        }
        #expect(throws: (any Error).self) {
            try makeSummary(folderID: "", sessionID: "s", status: .queued, error: nil,
                            exportPath: nil, canReprocess: true, canRetryDecisions: true, canExport: true,
                            metadata: readableMetadata)
        }

        var readableMetadataForUnreadable = object
        readableMetadataForUnreadable["metadata"] = try jsonObject(encoder().encode(readableMetadata))
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(readableMetadataForUnreadable), as: UTF8.self)))
        var exportPathForUnreadable = object
        exportPathForUnreadable["export_path"] = "/exports/inapplicable"
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(exportPathForUnreadable), as: UTF8.self)))
        for actionKey in ["can_reprocess", "can_retry_decisions", "can_export"] {
            var actionForUnreadable = object
            actionForUnreadable[actionKey] = true
            #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(actionForUnreadable), as: UTF8.self)))
        }
        var missingExportPath = object
        missingExportPath.removeValue(forKey: "export_path")
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(missingExportPath), as: UTF8.self)))
        var wrongExportPath = object
        wrongExportPath["export_path"] = 7
        #expect(decodingFails(EngineSessionSummary.self, from: String(decoding: try jsonData(wrongExportPath), as: UTF8.self)))

        let readableWithError = try makeSummary(
            folderID: "folder-with-error", sessionID: "real-id", status: .failed, error: failure,
            exportPath: nil, canReprocess: false, canRetryDecisions: true, canExport: false,
            metadata: readableMetadata
        )
        #expect(try roundTrip(readableWithError) == readableWithError)
    }

    @Test func progressUsesNullableJSONNumbersAndChecksKnownTotal() throws {
        let unknown = try EngineProgressPayload(stage: .asr, completedUnits: 5, totalUnits: nil, sessionID: nil)
        let object = try jsonObject(encoder().encode(unknown))
        #expect(object["completed_units"] as? NSNumber == 5)
        #expect(object["completed_units"] as? String == nil)
        #expect(object["total_units"] is NSNull)
        #expect(object["session_id"] is NSNull)
        #expect(throws: (any Error).self) { try EngineProgressPayload(stage: .asr, completedUnits: 2, totalUnits: 1, sessionID: nil) }
        #expect(throws: (any Error).self) { try EngineProgressPayload(stage: .asr, completedUnits: 0, totalUnits: nil, sessionID: "") }

        let invalidOrdering = #"{"stage":"asr","completed_units":2,"total_units":1,"session_id":null}"#
        #expect(decodingFails(EngineProgressPayload.self, from: invalidOrdering))
        let fractional = #"{"stage":"asr","completed_units":1.5,"total_units":null,"session_id":null}"#
        #expect(decodingFails(EngineProgressPayload.self, from: fractional))
    }
}

private func makeSummary(
    folderID: String,
    sessionID: String?,
    status: EngineSessionStatus,
    error: EngineFailure?,
    exportPath: String?,
    canReprocess: Bool,
    canRetryDecisions: Bool,
    canExport: Bool,
    metadata: EngineSessionMetadata
) throws -> EngineSessionSummary {
    try EngineSessionSummary(
        folderID: folderID,
        sessionID: sessionID,
        status: status,
        error: error,
        displayName: "Session \(folderID)",
        statusText: status.rawValue,
        folderPath: "/sessions/\(folderID)",
        exportPath: exportPath,
        canReprocess: canReprocess,
        canRetryDecisions: canRetryDecisions,
        canExport: canExport,
        metadata: metadata
    )
}

private func sampleDetail() throws -> EngineErrorDetail {
    try EngineErrorDetail(domain: "WASAPI", code: "AUDCLNT_E_DEVICE_INVALIDATED", message: "デバイスが切断されました", path: nil, deviceID: "endpoint-1")
}

private func sampleFailure() throws -> EngineFailure {
    try EngineFailure(
        code: .deviceFailure,
        message: "録音デバイスが利用できません",
        stage: .capture,
        requestID: engineID(9),
        sessionID: nil,
        severity: .error,
        recoveryAction: .selectDevice,
        details: [sampleDetail()],
        cleanupErrors: [try EngineErrorDetail(domain: "native", code: "E_CLEANUP", message: "後処理に失敗しました", path: "/sessions", deviceID: nil)]
    )
}

func engineTestPresentation() throws -> EnginePresentationState {
    try EnginePresentationState(
        recordingStatusText: "待機中",
        recordingTone: .neutral,
        preparationPhase: .ready,
        preparationStatusText: nil,
        recoveryStatusText: nil,
        processingStatusText: nil,
        liveFailureNotices: [],
        silenceWarningActive: false,
        silenceWarningText: nil,
        audioGapCount: 0,
        audioGapText: nil,
        processingIndicator: .idle
    )
}

private func sampleRow() throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: "row-1", startMS: 12, endMS: 34, text: "日本語の文字起こし", headings: [.speaker1, .other], clauseState: nil)
}

private func makeRow(_ id: String) throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: id, startMS: 0, endMS: 1, text: "text", headings: [], clauseState: .classified)
}

private func engineID(_ value: UInt64) throws -> EngineID {
    try EngineID(value)
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: encoder().encode(value))
}

private func encoder() -> JSONEncoder {
    let result = JSONEncoder()
    result.outputFormatting = [.sortedKeys]
    return result
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, from string: String) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: Data(string.utf8))
        return false
    } catch {
        return true
    }
}
