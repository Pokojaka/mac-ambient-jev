import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolEventPayloadTests {
    @Test func everyEventPayloadStructRoundTrips() throws {
        let detail = try sampleDetail()
        let failure = try sampleFailure()
        let capabilities = try sampleCapabilities()
        let recording = try sampleRecording()
        let operation = try EngineQueuedOperation(sessionID: "queued-session", stage: .asr)
        let state = try sampleState(recording: recording, queue: [operation], failures: [failure])
        let ready = EngineReadyPayload(capabilities: capabilities, state: state)
        let device = try EngineDeviceInfo(id: "endpoint-1", name: "Microphone", isDefault: true)
        let devices = try EngineDevicesResult(source: .microphone, devices: [device], defaultDeviceID: "endpoint-1")
        let settingsResult = EngineSettingsResult(revision: try engineID(2), settings: try sampleSettings())
        let unreadable = try makeSummary(
            folderID: "folder-unreadable", sessionID: nil, status: .unreadable, error: failure,
            exportPath: nil, canReprocess: false, canRetryDecisions: false, canExport: false,
            metadata: .unreadable(reason: "manifest is unreadable")
        )
        let session = try makeSummary(
            folderID: "folder-session", sessionID: "session-1", status: .finalized, error: nil,
            exportPath: "/exports/session-1", canReprocess: true, canRetryDecisions: true, canExport: true,
            metadata: .readable(createdAt: 1_700_000_000, source: .microphone, audio: .available, hasTranscript: true)
        )
        let sessions = try EngineSessionListResult(sessions: [unreadable, session], nextCursor: "next", previousCursor: nil)
        let row = try sampleRow()
        let page = try EngineTranscriptPage(sessionID: "session-1", revision: try engineID(3), rows: [row], nextCursor: nil, previousCursor: nil)
        let rows = try EngineRowsPayload(sessionID: "session-1", revision: try engineID(3), kind: .snapshot, rows: [row], removedRowIDs: [], nextCursor: "page-2")
        let progress = try EngineProgressPayload(stage: .finalization, completedUnits: 4, totalUnits: nil, sessionID: "session-1")

        #expect(try roundTrip(detail) == detail)
        #expect(try roundTrip(failure) == failure)
        #expect(try roundTrip(capabilities) == capabilities)
        #expect(try roundTrip(recording) == recording)
        #expect(try roundTrip(operation) == operation)
        #expect(try roundTrip(state) == state)
        #expect(try roundTrip(ready) == ready)
        #expect(try roundTrip(device) == device)
        #expect(try roundTrip(devices) == devices)
        #expect(try roundTrip(settingsResult) == settingsResult)
        #expect(try roundTrip(unreadable) == unreadable)
        #expect(try roundTrip(session) == session)
        #expect(try roundTrip(sessions) == sessions)
        #expect(try roundTrip(row) == row)
        #expect(try roundTrip(page) == page)
        #expect(try roundTrip(rows) == rows)
        #expect(try roundTrip(progress) == progress)

        let detailObject = try jsonObject(encoder().encode(detail))
        #expect(detailObject["path"] is NSNull)
        #expect(detailObject["device_id"] as? String == "endpoint-1")
        let failureObject = try jsonObject(encoder().encode(failure))
        #expect(failureObject["request_id"] as? String == "9")
        #expect(failureObject["session_id"] is NSNull)
        let summaryObject = try jsonObject(encoder().encode(session))
        #expect(summaryObject["export_path"] as? String == "/exports/session-1")
        let rowObject = try jsonObject(encoder().encode(row))
        #expect(rowObject["clause_state"] is NSNull)
        let sessionsObject = try jsonObject(encoder().encode(try EngineSessionListResult(sessions: [], nextCursor: nil, previousCursor: nil)))
        #expect(sessionsObject["previous_cursor"] is NSNull)
        let pageObject = try jsonObject(encoder().encode(try EngineTranscriptPage(sessionID: "session-1", revision: engineID(3), rows: [], nextCursor: nil, previousCursor: nil)))
        #expect(pageObject["previous_cursor"] is NSNull)
        let progressObject = try jsonObject(encoder().encode(progress))
        #expect(progressObject["total_units"] is NSNull)
        #expect(progressObject["completed_units"] as? NSNumber == 4)
        #expect(progressObject["session_id"] as? String == "session-1")
    }

    @Test func everyNewEnumHasExactWireValuesAndRoundTrips() throws {
        #expect(EngineStage.allCases.map(\.rawValue) == [
            "startup", "settings", "devices", "capture", "import", "recovery", "maintenance",
            "validating_models", "loading_models", "vad", "diarization", "asr", "decisions",
            "finalization", "export", "shutdown", "protocol"
        ])
        #expect(EngineErrorCode.allCases.map(\.rawValue) == [
            "invalid_request", "unsupported_version", "invalid_request_id", "hello_required", "busy",
            "settings_required", "invalid_settings", "stale_revision", "invalid_cursor", "session_not_found",
            "device_not_found", "device_failure", "capture_failure", "disk_space", "power_failure", "filesystem",
            "model_missing", "model_corrupt", "model_failure", "processing_failure", "export_failure",
            "row_too_large", "cancelled", "internal_error"
        ])
        #expect(!EngineErrorCode.allCases.contains { $0.rawValue == "resource_limit" })
        #expect(EngineSeverity.allCases.map(\.rawValue) == ["warning", "error", "fatal"])
        #expect(EngineRecoveryAction.allCases.map(\.rawValue) == [
            "none", "replace_settings", "prepare_models", "retry", "reprocess", "retry_decisions",
            "select_device", "free_disk_space", "inspect_session", "restart"
        ])
        #expect(EngineScreen.allCases.map(\.rawValue) == ["idle", "live", "finalizing", "finalized"])
        #expect(EngineSetupStatus.allCases.map(\.rawValue) == ["settings_required", "models_required", "ready"])
        #expect(EngineRecoveryStatus.allCases.map(\.rawValue) == ["pending", "running", "completed", "failed"])
        #expect(EngineRecordingPhase.allCases.map(\.rawValue) == ["starting", "recording", "stopping"])
        #expect(EngineUnavailableCapability.allCases.map(\.rawValue) == ["none"])
        #expect(EngineSessionStatus.allCases.map(\.rawValue) == ["unreadable", "recording", "queued", "processing", "finalized", "failed"])
        #expect(EngineSpeakerLabel.allCases.map(\.rawValue) == [
            "Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 5", "Speaker 6", "Speaker 7", "OTHER", "UNKNOWN"
        ])
        #expect(EngineClauseState.allCases.map(\.rawValue) == [
            "awaiting_next_segment", "boundary_pending", "priority_pending", "classified"
        ])
        #expect(EngineRowsKind.allCases.map(\.rawValue) == ["snapshot", "changes", "reload_required"])

        for value in EngineStage.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineErrorCode.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineSeverity.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineRecoveryAction.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineScreen.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineSetupStatus.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineRecoveryStatus.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineRecordingPhase.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineUnavailableCapability.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineSessionStatus.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineSpeakerLabel.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineClauseState.allCases { #expect(try roundTrip(value) == value) }
        for value in EngineRowsKind.allCases { #expect(try roundTrip(value) == value) }
    }

    @Test func nestedUnknownKeysAndUnknownEnumValuesAreRejected() throws {
        let detailWithExtra = #"{"domain":"native","code":"E_DEVICE","message":"失敗","path":null,"device_id":null,"extra":true}"#
        #expect(decodingFails(EngineErrorDetail.self, from: detailWithExtra))
        let failureDetailExtra = #"{"code":"device_failure","message":"日本語の失敗","stage":"capture","request_id":null,"session_id":null,"severity":"error","recovery_action":"retry","details":[{"domain":"native","code":"raw","message":"保全","path":null,"device_id":null,"extra":1}],"cleanup_errors":[]}"#
        #expect(decodingFails(EngineFailure.self, from: failureDetailExtra))
        let failureCleanupExtra = #"{"code":"device_failure","message":"日本語の失敗","stage":"capture","request_id":null,"session_id":null,"severity":"error","recovery_action":"retry","details":[],"cleanup_errors":[{"domain":"native","code":"raw","message":"保全","path":null,"device_id":null,"extra":1}]}"#
        #expect(decodingFails(EngineFailure.self, from: failureCleanupExtra))

        let stateQueueExtra = #"{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[{"session_id":"s","stage":"asr","extra":true}],"failures":[]}"#
        #expect(decodingFails(EngineState.self, from: stateQueueExtra))
        let stateDeviceExtra = #"{"revision":"1","screen":"live","setup":"ready","recovery":"completed","recording":{"session_id":"s","source":"microphone","device":{"kind":"default","unexpected":true},"phase":"recording"},"queue":[],"failures":[]}"#
        #expect(decodingFails(EngineState.self, from: stateDeviceExtra))
        let pageRowExtra = #"{"session_id":"s","revision":"1","rows":[{"row_id":"r","start_ms":0,"end_ms":1,"text":"hello","headings":["Speaker 1"],"clause_state":null,"extra":0}],"next_cursor":null,"previous_cursor":null}"#
        #expect(decodingFails(EngineTranscriptPage.self, from: pageRowExtra))
        let invalidHeading = #"{"row_id":"r","start_ms":0,"end_ms":1,"text":"hello","headings":["Speaker 8"],"clause_state":null}"#
        #expect(decodingFails(EngineTranscriptRow.self, from: invalidHeading))
        let invalidClauseState = #"{"row_id":"r","start_ms":0,"end_ms":1,"text":"hello","headings":[],"clause_state":"pending"}"#
        #expect(decodingFails(EngineTranscriptRow.self, from: invalidClauseState))
        let invalidCode = #"{"code":"resource_limit","message":"error","stage":"capture","request_id":null,"session_id":null,"severity":"error","recovery_action":"none","details":[],"cleanup_errors":[]}"#
        #expect(decodingFails(EngineFailure.self, from: invalidCode))
    }

    @Test func nullableFieldsAreRequiredAndNullIsTypeChecked() throws {
        let detail = #"{"domain":"native","code":"42","message":"message","device_id":null}"#
        #expect(decodingFails(EngineErrorDetail.self, from: detail))
        let wrongDetailNull = #"{"domain":"native","code":"42","message":"message","path":7,"device_id":null}"#
        #expect(decodingFails(EngineErrorDetail.self, from: wrongDetailNull))
        let nullMessage = #"{"domain":"native","code":"42","message":null,"path":null,"device_id":null}"#
        #expect(decodingFails(EngineErrorDetail.self, from: nullMessage))
        let failureMissingNullable = #"{"code":"busy","message":"busy","stage":"capture","session_id":null,"severity":"warning","recovery_action":"retry","details":[],"cleanup_errors":[]}"#
        #expect(decodingFails(EngineFailure.self, from: failureMissingNullable))
        let stateMissingRecording = #"{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","queue":[],"failures":[]}"#
        #expect(decodingFails(EngineState.self, from: stateMissingRecording))
        let rowMissingClauseState = #"{"row_id":"r","start_ms":0,"end_ms":0,"text":"x","headings":[]}"#
        #expect(decodingFails(EngineTranscriptRow.self, from: rowMissingClauseState))
        let progressMissingTotal = #"{"stage":"asr","completed_units":1,"session_id":null}"#
        #expect(decodingFails(EngineProgressPayload.self, from: progressMissingTotal))
        let progressWrongNull = #"{"stage":"asr","completed_units":1,"total_units":"unknown","session_id":null}"#
        #expect(decodingFails(EngineProgressPayload.self, from: progressWrongNull))
        let progressMissingSession = #"{"stage":"asr","completed_units":1,"total_units":null}"#
        #expect(decodingFails(EngineProgressPayload.self, from: progressMissingSession))
        let devicesMissingDefault = #"{"source":"microphone","devices":[]}"#
        #expect(decodingFails(EngineDevicesResult.self, from: devicesMissingDefault))
        let pageWrongPreviousCursor = #"{"session_id":"s","revision":"1","rows":[],"next_cursor":null,"previous_cursor":3}"#
        #expect(decodingFails(EngineTranscriptPage.self, from: pageWrongPreviousCursor))
        let pageMissingPreviousCursor = #"{"session_id":"s","revision":"1","rows":[],"next_cursor":null}"#
        #expect(decodingFails(EngineTranscriptPage.self, from: pageMissingPreviousCursor))
        let pageEmptyPreviousCursor = #"{"session_id":"s","revision":"1","rows":[],"next_cursor":null,"previous_cursor":""}"#
        #expect(decodingFails(EngineTranscriptPage.self, from: pageEmptyPreviousCursor))
        let listMissingPreviousCursor = #"{"sessions":[],"next_cursor":null}"#
        #expect(decodingFails(EngineSessionListResult.self, from: listMissingPreviousCursor))
        let listWrongPreviousCursor = #"{"sessions":[],"next_cursor":null,"previous_cursor":false}"#
        #expect(decodingFails(EngineSessionListResult.self, from: listWrongPreviousCursor))
        let listEmptyPreviousCursor = #"{"sessions":[],"next_cursor":null,"previous_cursor":""}"#
        #expect(decodingFails(EngineSessionListResult.self, from: listEmptyPreviousCursor))
    }

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
        let state16 = try EngineState(revision: engineID(1), screen: .idle, setup: .ready, recovery: .completed, recording: nil, queue: Array(repeating: operation, count: 16), failures: [])
        #expect(state16.queue.count == 16)
        #expect(throws: (any Error).self) {
            try EngineState(revision: engineID(1), screen: .idle, setup: .ready, recovery: .completed, recording: nil, queue: Array(repeating: operation, count: 17), failures: [])
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

    @Test func sessionMetadataUnionsRoundTripAllArmsAndRejectInvalidJSON() throws {
        let sources: [(EngineSessionSource, String)] = [
            (.microphone, #"{"kind":"microphone"}"#),
            (.systemAudio, #"{"kind":"system_audio"}"#),
            (.imported(originalFilename: "recording.wav"), #"{"kind":"imported","original_filename":"recording.wav"}"#)
        ]
        let audios: [(EngineSessionAudio, String)] = [
            (.available, #"{"kind":"available"}"#),
            (.missing, #"{"kind":"missing"}"#),
            (.unreadable(reason: "audio file is unreadable"), #"{"kind":"unreadable","reason":"audio file is unreadable"}"#)
        ]
        let unreadableJSON = #"{"kind":"unreadable","reason":"manifest is unreadable"}"#
        let unreadableMetadata = EngineSessionMetadata.unreadable(reason: "manifest is unreadable")
        #expect(try JSONDecoder().decode(EngineSessionMetadata.self, from: Data(unreadableJSON.utf8)) == unreadableMetadata)
        #expect(try roundTrip(unreadableMetadata) == unreadableMetadata)
        #expect(Set(try jsonObject(encoder().encode(unreadableMetadata)).keys) == ["kind", "reason"])

        for (source, sourceJSON) in sources {
            #expect(try roundTrip(source) == source)
            for (audio, audioJSON) in audios {
                #expect(try roundTrip(audio) == audio)
                let metadata = EngineSessionMetadata.readable(
                    createdAt: 1_700_000_000.25, source: source, audio: audio, hasTranscript: true
                )
                let json = "{\"kind\":\"readable\",\"created_at\":1700000000.25,\"source\":\(sourceJSON),\"audio\":\(audioJSON),\"has_transcript\":true}"
                #expect(try JSONDecoder().decode(EngineSessionMetadata.self, from: Data(json.utf8)) == metadata)
                #expect(try roundTrip(metadata) == metadata)
                let object = try jsonObject(encoder().encode(metadata))
                #expect(Set(object.keys) == ["kind", "created_at", "source", "audio", "has_transcript"])
            }
        }

        let invalidJSON = [
            #"{"reason":"missing kind"}"#,
            #"{"kind":null,"reason":"wrong kind type"}"#,
            #"{"kind":"future","reason":"unknown"}"#,
            #"{"kind":"unreadable"}"#,
            #"{"kind":"unreadable","reason":""}"#,
            #"{"kind":"unreadable","reason":4}"#,
            #"{"kind":"unreadable","reason":"bad","created_at":null}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"available"}}"#,
            #"{"kind":"readable","created_at":"1","source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":null,"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":"available","has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":"true"}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":true,"reason":null}"#,
            #"{"kind":"readable","created_at":1e9999,"source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone","original_filename":null},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"system_audio","original_filename":null},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"imported"},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"imported","original_filename":""},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"imported","original_filename":"a.wav","extra":null},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"future"},"audio":{"kind":"available"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"available","reason":null},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"missing","reason":null},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"unreadable"},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"unreadable","reason":""},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"unreadable","reason":"bad","extra":null},"has_transcript":true}"#,
            #"{"kind":"readable","created_at":1,"source":{"kind":"microphone"},"audio":{"kind":"future"},"has_transcript":true}"#
        ]
        for json in invalidJSON {
            #expect(decodingFails(EngineSessionMetadata.self, from: json))
        }
        #expect(throws: (any Error).self) {
            _ = try encoder().encode(EngineSessionMetadata.readable(
                createdAt: .infinity, source: .microphone, audio: .available, hasTranscript: false
            ))
        }
        #expect(throws: (any Error).self) {
            _ = try encoder().encode(EngineSessionMetadata.unreadable(reason: ""))
        }
    }

    @Test func listAndTranscriptCursorsAreRequiredNullableFields() throws {
        let sessions = try EngineSessionListResult(sessions: [], nextCursor: nil, previousCursor: nil)
        let sessionsObject = try jsonObject(encoder().encode(sessions))
        #expect(sessionsObject["next_cursor"] is NSNull)
        #expect(sessionsObject["previous_cursor"] is NSNull)
        #expect(try roundTrip(sessions) == sessions)
        let cursoredSessions = try EngineSessionListResult(sessions: [], nextCursor: "next", previousCursor: "previous")
        #expect(try roundTrip(cursoredSessions) == cursoredSessions)

        let page = try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: [], nextCursor: nil, previousCursor: nil)
        let pageObject = try jsonObject(encoder().encode(page))
        #expect(pageObject["next_cursor"] is NSNull)
        #expect(pageObject["previous_cursor"] is NSNull)
        #expect(try roundTrip(page) == page)
        let cursoredPage = try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: [], nextCursor: "next", previousCursor: "previous")
        #expect(try roundTrip(cursoredPage) == cursoredPage)

        #expect(throws: (any Error).self) {
            try EngineSessionListResult(sessions: [], nextCursor: nil, previousCursor: "")
        }
        #expect(throws: (any Error).self) {
            try EngineTranscriptPage(sessionID: "s", revision: engineID(1), rows: [], nextCursor: nil, previousCursor: "")
        }
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

private func sampleRecording() throws -> EngineRecordingState {
    try EngineRecordingState(sessionID: "session-live", source: .systemAudio, device: .id("endpoint-loopback"), phase: .recording)
}

private func sampleState(
    recording: EngineRecordingState? = nil,
    queue: [EngineQueuedOperation] = [],
    failures: [EngineFailure] = []
) throws -> EngineState {
    try EngineState(revision: engineID(1), screen: .live, setup: .ready, recovery: .running, recording: recording, queue: queue, failures: failures)
}

private func sampleRow() throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: "row-1", startMS: 12, endMS: 34, text: "日本語の文字起こし", headings: [.speaker1, .other], clauseState: nil)
}

private func makeRow(_ id: String) throws -> EngineTranscriptRow {
    try EngineTranscriptRow(rowID: id, startMS: 0, endMS: 1, text: "text", headings: [], clauseState: .classified)
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
