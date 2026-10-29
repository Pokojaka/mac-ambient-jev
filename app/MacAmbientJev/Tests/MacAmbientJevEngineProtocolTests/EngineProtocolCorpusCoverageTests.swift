import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCorpusCoverageTests {
    /// Required tokens come from the Swift wire types (every CodingKeys case, every CaseIterable
    /// enum value, both arms of every EngineNullable field); observed tokens come from the decoded corpus.
    @Test func corpusCoversEveryKeyEnumValueAndNullableArm() throws {
        let recorder = CoverageRecorder()
        let schema = CoverageEncoder(recorder: recorder, isRequired: true)
        for value in try coverageRepresentativeValues() {
            try schema.traverse(value)
        }
        for command in EngineCommandName.allCases {
            recorder.required.insert("command \(command.rawValue)")
            recorder.required.insert("result \(command.rawValue)")
        }
        for event in EngineEventName.allCases {
            recorder.required.insert("event \(event.rawValue)")
        }

        let corpus = CoverageEncoder(recorder: recorder, isRequired: false)
        for record in try wireCorpusRecords() {
            let root = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if root["event"] != nil {
                let output = try EngineCodec.decodeOutput(record)
                try corpus.traverse(output)
                recorder.observed.insert("event \(output.event.name.rawValue)")
                if case let .completed(result) = output.event {
                    recorder.observed.insert("result \(result.command.rawValue)")
                }
            } else {
                let request = try EngineCodec.decodeRequest(record)
                try corpus.traverse(request)
                recorder.observed.insert("command \(request.command.name.rawValue)")
            }
        }

        let missing = recorder.required.subtracting(recorder.observed).sorted()
        let unregistered = recorder.observed.subtracting(recorder.required).sorted()
        #expect(missing.isEmpty, "Missing wire corpus coverage: \(missing)")
        #expect(unregistered.isEmpty, "Unregistered wire corpus tokens: \(unregistered)")
    }
}

private final class CoverageRecorder {
    var required: Set<String> = []
    var observed: Set<String> = []
}

private protocol CoverageNullable {
    var isNull: Bool { get }
}

extension EngineNullable: CoverageNullable {
    fileprivate var isNull: Bool { wrappedValue == nil }
}

private protocol CoverageWrapper {
    static var wrappedType: any Encodable.Type { get }
}

extension Optional: CoverageWrapper where Wrapped: Encodable {
    fileprivate static var wrappedType: any Encodable.Type { Wrapped.self }
}

extension Array: CoverageWrapper where Element: Encodable {
    fileprivate static var wrappedType: any Encodable.Type { Element.self }
}

extension EngineNullable: CoverageWrapper {
    fileprivate static var wrappedType: any Encodable.Type { Value.self }
}

/// A traversal-only Encoder: it emits no bytes and records the keys and typed values that Codable implementations write.
private struct CoverageEncoder: Encoder {
    let recorder: CoverageRecorder
    let isRequired: Bool
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func traverse<T: Encodable>(_ value: T) throws {
        if isRequired {
            registerEnumCases(T.self)
        } else if T.self is any CaseIterable.Type {
            recorder.observed.insert("enum \(String(reflecting: T.self))=\(value)")
        }
        try value.encode(to: self)
    }

    private func registerEnumCases(_ type: any Encodable.Type) {
        if let enumType = type as? any CaseIterable.Type {
            for value in enumType.allCases {
                recorder.required.insert("enum \(String(reflecting: type))=\(value)")
            }
        }
        if let wrapper = type as? any CoverageWrapper.Type {
            registerEnumCases(wrapper.wrappedType)
        }
    }

    func record(_ token: String) {
        if isRequired {
            recorder.required.insert(token)
        } else {
            recorder.observed.insert(token)
        }
    }

    func child(_ key: any CodingKey) -> CoverageEncoder {
        CoverageEncoder(recorder: recorder, isRequired: isRequired, codingPath: codingPath + [key])
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let owner = String(reflecting: Key.self)
        if isRequired, let keys = Key.self as? any CaseIterable.Type {
            for key in keys.allCases {
                if let key = key as? any CodingKey {
                    recorder.required.insert("key \(owner).\(key.stringValue)")
                }
            }
        }
        return KeyedEncodingContainer(CoverageKeyedContainer<Key>(encoder: self, owner: owner))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        CoverageUnkeyedContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        CoverageSingleValueContainer(encoder: self)
    }
}

private struct CoverageKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: CoverageEncoder
    let owner: String
    var codingPath: [any CodingKey] { encoder.codingPath }

    private func mark(_ key: Key) { encoder.record("key \(owner).\(key.stringValue)") }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        mark(key)
        if let nullable = value as? any CoverageNullable {
            let field = "nullable \(owner).\(key.stringValue)"
            if encoder.isRequired {
                encoder.recorder.required.formUnion(["\(field)=null", "\(field)=non-null"])
            } else {
                encoder.recorder.observed.insert(nullable.isNull ? "\(field)=null" : "\(field)=non-null")
            }
        }
        try encoder.child(key).traverse(value)
    }

    mutating func encodeNil(forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: String, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { mark(key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { mark(key) }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        mark(key)
        return encoder.child(key).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        mark(key)
        return encoder.child(key).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder { encoder }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        mark(key)
        return encoder.child(key)
    }
}

private struct CoverageUnkeyedContainer: UnkeyedEncodingContainer {
    let encoder: CoverageEncoder
    private(set) var count = 0
    var codingPath: [any CodingKey] { encoder.codingPath }

    mutating func encode<T: Encodable>(_ value: T) throws {
        count += 1
        try encoder.traverse(value)
    }

    mutating func encodeNil() throws { count += 1 }
    mutating func encode(_ value: Bool) throws { count += 1 }
    mutating func encode(_ value: String) throws { count += 1 }
    mutating func encode(_ value: Double) throws { count += 1 }
    mutating func encode(_ value: Float) throws { count += 1 }
    mutating func encode(_ value: Int) throws { count += 1 }
    mutating func encode(_ value: Int8) throws { count += 1 }
    mutating func encode(_ value: Int16) throws { count += 1 }
    mutating func encode(_ value: Int32) throws { count += 1 }
    mutating func encode(_ value: Int64) throws { count += 1 }
    mutating func encode(_ value: UInt) throws { count += 1 }
    mutating func encode(_ value: UInt8) throws { count += 1 }
    mutating func encode(_ value: UInt16) throws { count += 1 }
    mutating func encode(_ value: UInt32) throws { count += 1 }
    mutating func encode(_ value: UInt64) throws { count += 1 }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        count += 1
        return encoder.container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        count += 1
        return encoder.unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        count += 1
        return encoder
    }
}

private struct CoverageSingleValueContainer: SingleValueEncodingContainer {
    let encoder: CoverageEncoder
    var codingPath: [any CodingKey] { encoder.codingPath }

    func encode<T: Encodable>(_ value: T) throws { try encoder.traverse(value) }
    func encodeNil() throws {}
    func encode(_ value: Bool) throws {}
    func encode(_ value: String) throws {}
    func encode(_ value: Double) throws {}
    func encode(_ value: Float) throws {}
    func encode(_ value: Int) throws {}
    func encode(_ value: Int8) throws {}
    func encode(_ value: Int16) throws {}
    func encode(_ value: Int32) throws {}
    func encode(_ value: Int64) throws {}
    func encode(_ value: UInt) throws {}
    func encode(_ value: UInt8) throws {}
    func encode(_ value: UInt16) throws {}
    func encode(_ value: UInt32) throws {}
    func encode(_ value: UInt64) throws {}
}

private func coverageRepresentativeValues() throws -> [any Encodable] {
    let id = try EngineID(1)
    let settings = try EngineSettings(
        schemaVersion: 2,
        source: .microphone,
        device: .id("coverage-device"),
        asrSize: .small,
        executionProvider: .cpu,
        threads: 1,
        lowHeat: false,
        decisionsEnabled: true,
        automaticExport: false,
        exportDestinationPath: nil
    )
    let detail = try EngineErrorDetail(
        domain: "coverage", code: "coverage", message: "確認用",
        path: "D:/Coverage", deviceID: "coverage-device"
    )
    let failure = try EngineFailure(
        code: .filesystem,
        message: "確認用",
        stage: .recovery,
        requestID: nil,
        sessionID: "coverage-session",
        severity: .warning,
        recoveryAction: .inspectSession,
        details: [detail],
        cleanupErrors: [detail]
    )
    let presentation = try EnginePresentationState(
        recordingStatusText: "確認用",
        recordingTone: .neutral,
        preparationPhase: .idle,
        preparationStatusText: nil,
        recoveryStatusText: "確認用",
        processingStatusText: "確認用",
        liveFailureNotices: [],
        silenceWarningActive: false,
        silenceWarningText: nil,
        audioGapCount: 0,
        audioGapText: nil,
        processingIndicator: .idle
    )
    let capabilities = try EngineCapabilities(
        sources: EngineSource.allCases,
        asrSizes: EngineASRSize.allCases,
        executionProviders: [.cpu, .windowsML(providerName: "Windows ML", deviceID: "gpu-adapter-01", verificationID: "verification-200")],
        maximumThreads: 1,
        automaticInputVolume: .none,
        thermalMonitoring: .none
    )
    let profileEvaluation = try EngineProfileEvaluation(
        initialSize: .small,
        recommendLarge: true,
        reason: .recommendLarge,
        explanation: "確認用",
        measuredRTF: 0.25,
        predictedRTF: 0.5,
        decisionState: .offered,
        requestedChoice: nil,
        calibrationID: "calibration-1"
    )
    let completeEvaluation = try EngineProfileEvaluation(
        initialSize: .small, recommendLarge: false, reason: .noGPU, explanation: "確認用",
        measuredRTF: nil, predictedRTF: nil, decisionState: .complete, requestedChoice: nil, calibrationID: nil
    )
    let chosenEvaluation = try EngineProfileEvaluation(
        initialSize: .small, recommendLarge: false, reason: .eligible, explanation: "確認用",
        measuredRTF: nil, predictedRTF: nil, decisionState: .complete, requestedChoice: .small, calibrationID: nil
    )
    let profileSetup = EngineProfileSetup(evaluation: profileEvaluation, operation: .binding)
    let profileEvaluatePayload = try EngineProfilesEvaluatePayload(
        hardware: .gpu(
            name: "Coverage GPU", adapterID: "coverage-adapter", deviceID: "coverage-device",
            driverVersion: "1.0", dedicatedVRAMBytes: 24576
        ),
        acquisition: .acquired(.openVINO),
        threads: 2
    )
    let resourceProtection = try EngineResourceProtection(holdReasons: EngineResourceHoldReason.allCases)
    let resourcePreflight = EngineResourcesPreflightPayload(workload: .load)
    let resourceAcknowledge = try EngineResourcesAcknowledgePayload(assessmentID: "resource-assessment-1")
    let resourceAssessment = try EngineResourceAssessment(
        assessmentID: "resource-assessment-1", result: .warning,
        reason: .envelopeUnmeasured, explanation: "リソースの測定がありません"
    )
    let recording = try EngineRecordingState(
        sessionID: "coverage-session", source: .microphone,
        device: .id("coverage-device"), phase: .recording
    )
    let queued = try EngineQueuedOperation(sessionID: "coverage-session", stage: .finalization)
    let state = try EngineState(
        revision: id,
        screen: .idle,
        setup: .ready,
        profileSetup: EngineProfileSetup(evaluation: nil, operation: nil),
        resourceProtection: try EngineResourceProtection(holdReasons: []),
        recovery: .completed,
        recording: recording,
        queue: [queued],
        failures: [failure],
        presentation: presentation
    )
    let ready = EngineReadyPayload(capabilities: capabilities, state: state)
    let deviceInfo = try EngineDeviceInfo(id: "coverage-device", name: "確認用", isDefault: true)
    let devices = try EngineDevicesResult(
        source: .microphone, devices: [deviceInfo], defaultDeviceID: "coverage-device"
    )
    let importedSource = EngineSessionSource.imported(originalFilename: "coverage.wav")
    let unreadableAudio = EngineSessionAudio.unreadable(reason: "確認用")
    let readableMetadata = EngineSessionMetadata.readable(
        createdAt: 0, source: importedSource, audio: .available, hasTranscript: true
    )
    let unreadableMetadata = EngineSessionMetadata.unreadable(reason: "確認用")
    let summary = try EngineSessionSummary(
        folderID: "coverage-folder",
        sessionID: "coverage-session",
        status: .finalized,
        error: nil,
        displayName: "確認用",
        statusText: "確認用",
        folderPath: "D:/Coverage",
        exportPath: nil,
        canReprocess: true,
        canRetryDecisions: false,
        canExport: true,
        metadata: readableMetadata
    )
    let sessionList = try EngineSessionListResult(
        sessions: [summary], nextCursor: "coverage-cursor", previousCursor: nil
    )
    let row = try EngineTranscriptRow(
        rowID: "coverage-row", startMS: 0, endMS: 1,
        text: "確認用", headings: [.speaker1], clauseState: .classified
    )
    let transcriptPage = try EngineTranscriptPage(
        sessionID: "coverage-session", revision: id, rows: [row],
        nextCursor: "coverage-cursor", previousCursor: nil
    )
    let rowsPayload = try EngineRowsPayload(
        sessionID: "coverage-session", revision: id, kind: .snapshot,
        rows: [row], removedRowIDs: [], nextCursor: "coverage-cursor"
    )
    let progress = try EngineProgressPayload(
        stage: .asr, completedUnits: 0, totalUnits: nil, sessionID: nil
    )
    let speakerSpan = try EngineTranscriptSpeakerSpan(
        speakerID: "coverage-row", displayLabel: "確認用", startMS: 0, endMS: 1
    )
    let rowDetailsPayload = try EngineTranscriptRowDetailsPayload(
        sessionID: "coverage-session", revision: id, rowID: "coverage-row",
        cursor: "coverage-cursor", limit: 1
    )
    let rowDetailsPage = try EngineTranscriptRowDetailsPage(
        sessionID: "coverage-session", revision: id, rowID: "coverage-row",
        clauseState: .classified, clauseStateText: "確認用", speakers: [speakerSpan],
        nextCursor: "coverage-cursor", previousCursor: nil
    )
    let requestUsage = try EngineDecisionRequestUsage(
        sendCount: 0, inputTokens: 0, successCount: 0, failureCount: 0
    )
    let usageSnapshot = try EngineDecisionUsageSnapshot(
        sendCount: 0, inputTokens: 0, successCount: 0, failureCount: 0,
        pendingBoundarySegmentCount: 0, pendingPriorityClauseCount: 0,
        boundaryRequests: requestUsage, priorityRequests: requestUsage
    )
    let diagnostics = EngineDiagnosticsResult(
        scope: .engineProcess,
        decisionUsage: .available(usageSnapshot),
        automaticInputVolume: .none,
        thermalMonitoring: .none
    )
    let sha256 = String(repeating: "a", count: 64)
    let dependency = try EngineAcceleratorDependency(path: "C:/Coverage/dependency.dll", hash: sha256)
    let acceleratorDescriptor = try EngineAcceleratorDescriptor(
        providerName: "coverage-provider", deviceID: "coverage-device", gpuName: "Coverage GPU",
        driverVersion: "1.0", adapterID: "coverage-adapter", architecture: "x64",
        dedicatedVRAMBytes: 24576, packageIdentity: "coverage-package",
        libraryPath: "C:/Coverage/provider.dll", libraryHash: sha256, dependencies: [dependency]
    )
    let bindPayload = try EngineAcceleratorsBindPayload(descriptor: acceleratorDescriptor)
    let bindResult = try EngineAcceleratorsBindResult(bindingID: "coverage-binding")
    let verifyPayload = try EngineAcceleratorsVerifyPayload(bindingID: "coverage-binding", asrSize: .small, threads: 1)
    let verifyPass = EngineAcceleratorsVerifyResult.pass(verificationID: "coverage-verification", rtf: 0.5)
    let verifyFail = EngineAcceleratorsVerifyResult.fail(
        verificationID: "coverage-verification", reason: "verification failed", observedOutput: "unexpected output"
    )
    let decidePayload = try EngineProfilesDecidePayload(expectedRevision: id, choice: .small)
    let identity = try EngineClauseTaggerIdentity(
        backend: "coverage", modelID: "coverage", revision: sha256, tokenizerSHA256: sha256
    )
    let inspection = EngineModelsInspection(clauseTagger: .validated(identity))
    let settingsResult = EngineSettingsResult(revision: id, settings: settings)
    let request = try EngineRequest(version: 1, requestID: id, command: .hello)
    let output = try EngineOutput(version: 1, sequence: id, requestID: nil, event: .state(state))
    let result = EngineResult.hello(ready)

    return [
        request,
        output,
        result,
        EngineEmptyPayload(),
        EngineDevicesListPayload(source: .microphone),
        try EngineRecordingStartPayload(source: .microphone, device: .id("coverage-device")),
        try EngineSessionPayload(sessionID: "coverage-session"),
        try EngineSessionInspectPayload(folderID: "coverage-folder"),
        try EngineImportPayload(inputPath: "D:/Coverage"),
        try EngineSessionListPayload(cursor: "coverage-cursor", limit: 1),
        try EngineTranscriptReadPayload(
            sessionID: "coverage-session", revision: nil, cursor: "coverage-cursor", limit: 1
        ),
        rowDetailsPayload,
        try EngineExportPayload(sessionID: "coverage-session", destinationPath: "D:/Coverage"),
        EngineSettingsReplacePayload(expectedRevision: nil, settings: settings),
        settings,
        profileEvaluatePayload,
        acceleratorDescriptor,
        bindPayload,
        bindResult,
        verifyPayload,
        verifyPass,
        verifyFail,
        decidePayload,
        EngineProfileHardware.noGPU,
        EngineProfileHardware.queryFailed("GPU query failed"),
        EngineProfileHardware.gpu(
            name: "Coverage GPU", adapterID: "coverage-adapter", deviceID: "coverage-device",
            driverVersion: "1.0", dedicatedVRAMBytes: 24576
        ),
        EngineProfileAcquisition.unavailable,
        EngineProfileAcquisition.failed("provider acquisition failed"),
        EngineProfileAcquisition.acquired(.openVINO),
        profileEvaluation,
        completeEvaluation,
        chosenEvaluation,
        profileSetup,
        resourceProtection,
        resourcePreflight,
        resourceAcknowledge,
        resourceAssessment,
        EngineDevice.id("coverage-device"),
        EngineAcceptedPayload(command: .hello),
        try EngineExportResult(sessionID: "coverage-session", destinationPath: "D:/Coverage"),
        state,
        ready,
        capabilities,
        recording,
        queued,
        failure,
        detail,
        deviceInfo,
        devices,
        settingsResult,
        importedSource,
        EngineSessionSource.microphone,
        EngineSessionAudio.available,
        unreadableAudio,
        readableMetadata,
        unreadableMetadata,
        summary,
        sessionList,
        row,
        transcriptPage,
        rowsPayload,
        progress,
        rowDetailsPage,
        speakerSpan,
        requestUsage,
        usageSnapshot,
        EngineDecisionUsage.available(usageSnapshot),
        diagnostics,
        identity,
        EngineClauseTaggerInspection.validated(identity),
        inspection,
        presentation,
    ]
}
