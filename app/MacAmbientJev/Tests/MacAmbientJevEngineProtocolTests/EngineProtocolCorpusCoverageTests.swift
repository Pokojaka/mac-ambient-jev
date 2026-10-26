import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCorpusCoverageTests {
    @Test func corpusCoversCompleteWireContract() throws {
        let records = try coverageFixtureRecords()
        let recorder = EngineProtocolCoverageRecorder()
        var hasFailure = false
        func recordIssue(_ message: String) {
            hasFailure = true
            Issue.record("\(message)")
        }

        for value in try coverageRepresentativeValues() {
            try EngineProtocolCoverageEncoder.traverse(value, recorder: recorder, phase: .required)
        }
        for command in EngineCommandName.allCases {
            recorder.recordRequiredToken("command EngineCommand=\(command.rawValue)")
        }
        for event in EngineEventName.allCases {
            recorder.recordRequiredToken("event EngineEvent=\(event.rawValue)")
        }
        for command in EngineCommandName.allCases {
            recorder.recordRequiredToken("result EngineResult=\(command.rawValue)")
        }

        // CodingKeys and Kind-derived enum values form union requirements: each envelope selects one branch,
        // so a branch omitted from the fixtures stays required. Freeze the registry after schema discovery;
        // fixture traversal only records observations.
        for (offset, record) in records.enumerated() {
            let recordNumber = offset + 1
            let root: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: record) as? [String: Any] else {
                    recordIssue("record \(recordNumber): expected a JSON object")
                    continue
                }
                root = object
            } catch {
                recordIssue("record \(recordNumber): could not inspect envelope: \(error)")
                continue
            }

            if root["event"] != nil {
                let output: EngineOutput
                do {
                    output = try EngineCodec.decodeOutput(record)
                } catch {
                    hasFailure = true
                    recordDecodeFailure(error, recordNumber: recordNumber)
                    continue
                }
                do {
                    let canonical = try EngineCodec.encodeOutput(output)
                    if canonical != record + Data([0x0A]) {
                        recordIssue("record \(recordNumber): output is not a canonical byte roundtrip")
                    }
                    try EngineProtocolCoverageEncoder.traverse(output, recorder: recorder, phase: .observed)
                } catch {
                    recordIssue("record \(recordNumber): output coverage traversal failed: \(error)")
                    continue
                }

                recorder.recordObservedToken("event EngineEvent=\(output.event.name.rawValue)")
                if case let .completed(result) = output.event {
                    recorder.recordObservedToken("result EngineResult=\(result.command.rawValue)")
                }
            } else {
                let request: EngineRequest
                do {
                    request = try EngineCodec.decodeRequest(record)
                } catch {
                    hasFailure = true
                    recordDecodeFailure(error, recordNumber: recordNumber)
                    continue
                }
                do {
                    let canonical = try EngineCodec.encodeRequest(request)
                    if canonical != record + Data([0x0A]) {
                        recordIssue("record \(recordNumber): request is not a canonical byte roundtrip")
                    }
                    try EngineProtocolCoverageEncoder.traverse(request, recorder: recorder, phase: .observed)
                } catch {
                    recordIssue("record \(recordNumber): request coverage traversal failed: \(error)")
                    continue
                }
                recorder.recordObservedToken("command EngineCommand=\(request.command.name.rawValue)")
            }
        }

        let issues = recorder.coverageIssues()
        for issue in issues {
            recordIssue(issue)
        }
        if issues.isEmpty && !hasFailure {
            print("Wire corpus: \(records.count) records, \(recorder.requiredTokens.count) required coverage tokens")
        }
    }

    @Test func recorderRequiresIndependentTypedKeyEnumAndNullableCoverage() throws {
        let child = CoverageSelfTestChild(value: "確認用")
        let arrayElement = CoverageSelfTestArrayElement(value: "配列確認用")
        let nilValue = CoverageSelfTestRoot(
            value: "確認用", mode: .first, child: child, children: [arrayElement], nullable: nil
        )
        let nonNullValue = CoverageSelfTestRoot(
            value: "確認用", mode: .first, child: child, children: [arrayElement], nullable: "確認用"
        )
        let recorder = EngineProtocolCoverageRecorder()

        try EngineProtocolCoverageEncoder.traverse(nilValue, recorder: recorder, phase: .required)
        try EngineProtocolCoverageEncoder.traverse(nilValue, recorder: recorder, phase: .observed)
        try EngineProtocolCoverageEncoder.traverse(nonNullValue, recorder: recorder, phase: .observed)

        #expect(recorder.requiredTokens.contains("key CoverageSelfTestChild.never_observed"))
        #expect(!recorder.observedTokens.contains("key CoverageSelfTestChild.never_observed"))
        #expect(recorder.requiredTokens.contains("key CoverageSelfTestRoot.value"))
        #expect(recorder.requiredTokens.contains("key CoverageSelfTestChild.value"))
        #expect(recorder.requiredTokens.contains("key CoverageSelfTestArrayElement.value"))
        #expect(recorder.observedTokens.contains("key CoverageSelfTestArrayElement.value"))
        #expect(recorder.requiredTokens.contains("enum CoverageSelfTestMode=first"))
        #expect(recorder.requiredTokens.contains("enum CoverageSelfTestMode=second"))
        #expect(recorder.observedTokens.contains("enum CoverageSelfTestMode=first"))
        #expect(!recorder.observedTokens.contains("enum CoverageSelfTestMode=second"))
        #expect(recorder.requiredTokens.contains("nullable CoverageSelfTestRoot.nullable=null"))
        #expect(recorder.requiredTokens.contains("nullable CoverageSelfTestRoot.nullable=non-null"))
        #expect(recorder.observedTokens.contains("nullable CoverageSelfTestRoot.nullable=null"))
        #expect(recorder.observedTokens.contains("nullable CoverageSelfTestRoot.nullable=non-null"))

        let nullableEnumRecorder = EngineProtocolCoverageRecorder()
        let nilEnum = CoverageNullableEnumSelfTest(mode: nil)
        let nonNullEnum = CoverageNullableEnumSelfTest(mode: .second)
        try EngineProtocolCoverageEncoder.traverse(nilEnum, recorder: nullableEnumRecorder, phase: .required)
        try EngineProtocolCoverageEncoder.traverse(nonNullEnum, recorder: nullableEnumRecorder, phase: .required)
        try EngineProtocolCoverageEncoder.traverse(nilEnum, recorder: nullableEnumRecorder, phase: .observed)
        try EngineProtocolCoverageEncoder.traverse(nonNullEnum, recorder: nullableEnumRecorder, phase: .observed)
        #expect(nullableEnumRecorder.requiredTokens.contains("enum CoverageSelfTestMode=first"))
        #expect(nullableEnumRecorder.requiredTokens.contains("enum CoverageSelfTestMode=second"))
        #expect(!nullableEnumRecorder.observedTokens.contains("enum CoverageSelfTestMode=first"))
        #expect(nullableEnumRecorder.observedTokens.contains("enum CoverageSelfTestMode=second"))
    }

    @Test func recorderReportsUnknownTokensAndMissingRepresentatives() throws {
        let child = CoverageSelfTestChild(value: "確認用")

        let observedRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestUnexpectedObservedRoot(child: CoverageSelfTestUnexpectedObservedChild(value: "確認用")),
            recorder: observedRecorder,
            phase: .observed
        )
        #expect(observedRecorder.coverageIssues().contains(
            "Unregistered wire corpus token: key CoverageSelfTestUnexpectedObservedChild.value"
        ))

        let nullableRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestNullableObjectRoot(child: nil), recorder: nullableRecorder, phase: .required
        )
        #expect(nullableRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestNullableObject"
        ))

        let nullableDischargedRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestNullableObjectRepresentativeRoot(
                child: nil,
                representative: CoverageSelfTestNullableObject(value: "代表値")
            ),
            recorder: nullableDischargedRecorder,
            phase: .required
        )
        #expect(!nullableDischargedRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestNullableObject"
        ))

        let emptyArrayRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestEmptyArrayRoot(children: []), recorder: emptyArrayRecorder, phase: .required
        )
        #expect(emptyArrayRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))

        let optionalArrayRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestOptionalArrayRoot(children: nil),
            recorder: optionalArrayRecorder,
            phase: .required
        )
        let nilOptionalArrayTypeIssues = optionalArrayRecorder.coverageIssues().filter {
            $0.hasPrefix("Missing non-nil representative for wire type:")
        }
        #expect(nilOptionalArrayTypeIssues.count == 1)
        #expect(nilOptionalArrayTypeIssues.first.map {
            $0.contains("Array") || $0.contains("[")
        } == true)
        #expect(!nilOptionalArrayTypeIssues.contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestOptionalArrayRoot(children: []),
            recorder: optionalArrayRecorder,
            phase: .required
        )
        let emptyOptionalArrayTypeIssues = optionalArrayRecorder.coverageIssues().filter {
            $0.hasPrefix("Missing non-nil representative for wire type:")
        }
        #expect(emptyOptionalArrayTypeIssues == [
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ])

        let directOptionalRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestDirectOptionalRoot(child: nil), recorder: directOptionalRecorder, phase: .required
        )
        #expect(directOptionalRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))

        let synthesizedOptionalRecorder = EngineProtocolCoverageRecorder()
        let synthesizedNil = CoverageSelfTestSynthesizedOptionalRoot(child: nil)
        try EngineProtocolCoverageEncoder.traverse(
            synthesizedNil, recorder: synthesizedOptionalRecorder, phase: .required
        )
        try EngineProtocolCoverageEncoder.traverse(
            synthesizedNil, recorder: synthesizedOptionalRecorder, phase: .observed
        )
        #expect(synthesizedOptionalRecorder.requiredTokens.contains("key CoverageSelfTestSynthesizedOptionalRoot.child"))
        #expect(!synthesizedOptionalRecorder.observedTokens.contains("key CoverageSelfTestSynthesizedOptionalRoot.child"))
        #expect(synthesizedOptionalRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))

        let observedCannotDischargeRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestEmptyArrayRoot(children: []),
            recorder: observedCannotDischargeRecorder,
            phase: .required
        )
        try EngineProtocolCoverageEncoder.traverse(
            child, recorder: observedCannotDischargeRecorder, phase: .observed
        )
        #expect(observedCannotDischargeRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))

        let requiredDischargeRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestEmptyArrayRoot(children: []),
            recorder: requiredDischargeRecorder,
            phase: .required
        )
        try EngineProtocolCoverageEncoder.traverse(
            child, recorder: requiredDischargeRecorder, phase: .required
        )
        #expect(!requiredDischargeRecorder.coverageIssues().contains(
            "Missing non-nil representative for wire type: CoverageSelfTestChild"
        ))
    }

    @Test func rawRepresentableWireTypesRequireCaseIterable() {
        let stringDiagnostic = "RawRepresentable wire type is not CaseIterable: CoverageSelfTestNonCaseIterableStringEnum"
        expectCoverageTraversalFailure(
            CoverageSelfTestNonCaseIterableStringEnum.first,
            diagnostic: stringDiagnostic
        )
        expectCoverageTraversalFailure(
            CoverageSelfTestRawRepresentableFieldRoot(value: .first),
            diagnostic: stringDiagnostic
        )
        expectCoverageTraversalFailure(
            CoverageSelfTestRawRepresentableOptionalRoot(value: nil),
            diagnostic: stringDiagnostic
        )
        expectCoverageTraversalFailure(
            [CoverageSelfTestNonCaseIterableStringEnum](),
            diagnostic: stringDiagnostic
        )

        let intDiagnostic = "RawRepresentable wire type is not CaseIterable: CoverageSelfTestNonCaseIterableIntEnum"
        expectCoverageTraversalFailure(CoverageSelfTestNonCaseIterableIntEnum.first, diagnostic: intDiagnostic)
        expectCoverageTraversalFailure(CoverageSelfTestNonCaseIterableIntEnumRoot(value: .first), diagnostic: intDiagnostic)
        expectCoverageTraversalFailure(CoverageSelfTestNullableIntEnumRoot(value: nil), diagnostic: intDiagnostic)
        expectCoverageTraversalFailure([CoverageSelfTestNonCaseIterableIntEnum](), diagnostic: intDiagnostic)
    }

    @Test func recorderRequiresEveryCaseOfIntegerRawEnums() throws {
        let recorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(CoverageSelfTestIntegerEnum.first, recorder: recorder, phase: .required)
        try EngineProtocolCoverageEncoder.traverse(CoverageSelfTestIntegerEnum.first, recorder: recorder, phase: .observed)

        #expect(recorder.requiredTokens.contains("enum CoverageSelfTestIntegerEnum=1"))
        #expect(recorder.requiredTokens.contains("enum CoverageSelfTestIntegerEnum=2"))
        #expect(recorder.observedTokens.contains("enum CoverageSelfTestIntegerEnum=1"))
        #expect(!recorder.observedTokens.contains("enum CoverageSelfTestIntegerEnum=2"))
        #expect(recorder.coverageIssues() == ["Missing wire corpus coverage: enum CoverageSelfTestIntegerEnum=2"])
    }

    @Test func stringKindDiscriminatorMustEncodeTypedEnum() {
        expectCoverageTraversalFailure(
            CoverageSelfTestAssociatedValueEnum.value("b"),
            diagnostic: "Untyped wire discriminator: CoverageSelfTestAssociatedValueEnum.kind must encode a CaseIterable enum, not String"
        )
    }

    @Test func optionalStringKindDiscriminatorMustEncodeTypedEnum() throws {
        let diagnostic = "Untyped wire discriminator: CoverageSelfTestOptionalStringKind.kind must encode a CaseIterable enum, not String"
        expectCoverageTraversalFailure(CoverageSelfTestOptionalStringKind(kind: "b"), diagnostic: diagnostic)

        let nilRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestOptionalStringKind(kind: nil), recorder: nilRecorder, phase: .observed
        )
        #expect(!nilRecorder.observedTokens.contains("key CoverageSelfTestOptionalStringKind.kind"))

        let ordinaryRecorder = EngineProtocolCoverageRecorder()
        try EngineProtocolCoverageEncoder.traverse(
            CoverageSelfTestOptionalStringValue(value: "ordinary"), recorder: ordinaryRecorder, phase: .observed
        )
        #expect(ordinaryRecorder.observedTokens.contains("key CoverageSelfTestOptionalStringValue.value"))
    }
}

private func coverageFixtureRecords() throws -> [Data] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wire-v1.ndjson")
    let bytes = try Data(contentsOf: url)
    guard bytes.last == 0x0A else {
        throw EngineProtocolError.invalidJSON("wire fixture must end with LF")
    }
    var framer = EngineLineFramer()
    let records = try framer.append(bytes)
    try framer.finish()
    return records
}

private func expectCoverageTraversalFailure(_ value: any Encodable, diagnostic: String) {
    let recorder = EngineProtocolCoverageRecorder()
    do {
        try EngineProtocolCoverageEncoder.traverse(value, recorder: recorder, phase: .required)
        Issue.record("Expected coverage traversal failure: \(diagnostic)")
    } catch {
        #expect(String(describing: error) == diagnostic)
    }
}

private func recordDecodeFailure(_ error: Error, recordNumber: Int) {
    if case let DecodingError.keyNotFound(key, context) = error {
        let path = (context.codingPath + [key]).map { ".\($0.stringValue)" }.joined()
        Issue.record("record \(recordNumber): missing key $\(path)")
    } else {
        Issue.record("record \(recordNumber): strict decode failed: \(error)")
    }
}

private func coverageRepresentativeValues() throws -> [any Encodable] {
    let id = try EngineID(1)
    let settings = try EngineSettings(
        schemaVersion: 1,
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
        executionProviders: EngineExecutionProvider.allCases,
        maximumThreads: 1,
        automaticInputVolume: .none,
        thermalMonitoring: .none
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

private enum CoverageSelfTestMode: String, Codable, CaseIterable {
    case first
    case second
}

private struct CoverageSelfTestChild: Encodable {
    let value: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case neverObserved = "never_observed"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

private struct CoverageSelfTestArrayElement: Encodable {
    let value: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

private struct CoverageSelfTestRoot: Encodable {
    let value: String
    let mode: CoverageSelfTestMode
    let child: CoverageSelfTestChild
    let children: [CoverageSelfTestArrayElement]
    @EngineNullable var nullable: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
        case mode
        case child
        case children
        case nullable
    }

    init(value: String, mode: CoverageSelfTestMode, child: CoverageSelfTestChild, children: [CoverageSelfTestArrayElement], nullable: String?) {
        self.value = value
        self.mode = mode
        self.child = child
        self.children = children
        _nullable = EngineNullable(wrappedValue: nullable)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(mode, forKey: .mode)
        try container.encode(child, forKey: .child)
        try container.encode(children, forKey: .children)
        try container.encode(_nullable, forKey: .nullable)
    }
}

private struct CoverageNullableEnumSelfTest: Encodable {
    @EngineNullable var mode: CoverageSelfTestMode?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
    }

    init(mode: CoverageSelfTestMode?) {
        _mode = EngineNullable(wrappedValue: mode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_mode, forKey: .mode)
    }
}

private struct CoverageSelfTestUnexpectedObservedChild: Encodable {
    let value: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

private struct CoverageSelfTestUnexpectedObservedRoot: Encodable {
    let child: CoverageSelfTestUnexpectedObservedChild

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case child
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(child, forKey: .child)
    }
}

private struct CoverageSelfTestNullableObject: Codable, Equatable, Sendable {
    let value: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }
}

private struct CoverageSelfTestNullableObjectRoot: Encodable {
    @EngineNullable var child: CoverageSelfTestNullableObject?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case child
    }

    init(child: CoverageSelfTestNullableObject?) {
        _child = EngineNullable(wrappedValue: child)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_child, forKey: .child)
    }
}

private struct CoverageSelfTestNullableObjectRepresentativeRoot: Encodable {
    @EngineNullable var child: CoverageSelfTestNullableObject?
    let representative: CoverageSelfTestNullableObject

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case child
        case representative
    }

    init(child: CoverageSelfTestNullableObject?, representative: CoverageSelfTestNullableObject) {
        _child = EngineNullable(wrappedValue: child)
        self.representative = representative
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_child, forKey: .child)
        try container.encode(representative, forKey: .representative)
    }
}

private struct CoverageSelfTestEmptyArrayRoot: Encodable {
    let children: [CoverageSelfTestChild]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case children
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(children, forKey: .children)
    }
}

private struct CoverageSelfTestOptionalArrayRoot: Encodable {
    let children: [CoverageSelfTestChild]?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case children
    }
}

private struct CoverageSelfTestDirectOptionalRoot: Encodable {
    let child: CoverageSelfTestChild?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case child
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(child, forKey: .child)
    }
}

private struct CoverageSelfTestSynthesizedOptionalRoot: Encodable {
    let child: CoverageSelfTestChild?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case child
    }
}

private enum CoverageSelfTestNonCaseIterableStringEnum: String, Encodable {
    case first
}

private struct CoverageSelfTestRawRepresentableFieldRoot: Encodable {
    let value: CoverageSelfTestNonCaseIterableStringEnum

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

private struct CoverageSelfTestRawRepresentableOptionalRoot: Encodable {
    let value: CoverageSelfTestNonCaseIterableStringEnum?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
    }
}

private enum CoverageSelfTestNonCaseIterableIntEnum: Int, Codable, Equatable, Sendable {
    case first = 1
}

private struct CoverageSelfTestNonCaseIterableIntEnumRoot: Encodable {
    let value: CoverageSelfTestNonCaseIterableIntEnum

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }
}

private struct CoverageSelfTestNullableIntEnumRoot: Encodable {
    @EngineNullable var value: CoverageSelfTestNonCaseIterableIntEnum?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    init(value: CoverageSelfTestNonCaseIterableIntEnum?) {
        _value = EngineNullable(wrappedValue: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_value, forKey: .value)
    }
}

private enum CoverageSelfTestIntegerEnum: Int, Encodable, CaseIterable {
    case first = 1
    case second = 2
}

private enum CoverageSelfTestAssociatedValueEnum: Encodable {
    case value(String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    func encode(to encoder: Encoder) throws {
        guard case let .value(value) = self else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .kind)
    }
}

private struct CoverageSelfTestOptionalStringKind: Encodable {
    let kind: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(kind, forKey: .kind)
    }
}

private struct CoverageSelfTestOptionalStringValue: Encodable {
    let value: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
    }
}
