import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolPresentationTests {
    @Test func everyProcessingIndicatorAndNullableArmRoundTripsThroughCodecEnvelopes() throws {
        #expect(EngineProcessingIndicator.allCases.map(\.rawValue) == [
            "idle", "running", "backlogged", "complete", "partial_failure"
        ])

        let indicators: [EngineProcessingIndicator] = [
            .idle, .running, .backlogged, .complete, .partialFailure
        ]
        for indicator in indicators {
            for hasNullableValues in [false, true] {
                let presentation = try presentationForCodec(
                    indicator: indicator,
                    hasNullableValues: hasNullableValues
                )
                let state = try stateWithPresentation(presentation)
                let capabilities = try EngineCapabilities(
                    sources: [.microphone],
                    asrSizes: [.small],
                    executionProviders: [.cpu],
                    maximumThreads: 1,
                    automaticInputVolume: .none,
                    thermalMonitoring: .none
                )
                let ready = EngineReadyPayload(capabilities: capabilities, state: state)
                let outputs = [
                    try EngineOutput(version: 1, sequence: engineID(1), requestID: nil, event: .state(state)),
                    try EngineOutput(version: 1, sequence: engineID(2), requestID: nil, event: .ready(ready)),
                    try EngineOutput(version: 1, sequence: engineID(3), requestID: engineID(4), event: .completed(.hello(ready))),
                    try EngineOutput(version: 1, sequence: engineID(5), requestID: engineID(6), event: .completed(.stateGet(state)))
                ]

                for output in outputs {
                    let line = try EngineCodec.encodeOutput(output)
                    let body = Data(line.dropLast())
                    let text = String(decoding: body, as: UTF8.self)
                    #expect(try EngineCodec.decodeOutput(body) == output)
                    #expect(text.contains(#""recording_status_text":"録音しています""#))
                    #expect(text.contains(#""recording_tone":"neutral""#))
                    #expect(text.contains(#""preparation_phase":"ready""#))
                    #expect(text.contains(#""preparation_status_text":null"#))
                    #expect(text.contains(#""live_failure_notices":["音声入力に問題があります"]"#))
                    #expect(text.contains("\"processing_indicator\":\"\(indicator.rawValue)\""))
                    if hasNullableValues {
                        #expect(text.contains(#""recovery_status_text":"復旧しています""#))
                        #expect(text.contains(#""processing_status_text":"文字起こしを処理中""#))
                        #expect(text.contains(#""silence_warning_text":"無音が続いています""#))
                        #expect(text.contains(#""audio_gap_text":"音声の欠落を検出しました""#))
                    } else {
                        #expect(text.contains(#""recovery_status_text":null"#))
                        #expect(text.contains(#""processing_status_text":null"#))
                        #expect(text.contains(#""silence_warning_text":null"#))
                        #expect(text.contains(#""audio_gap_text":null"#))
                    }
                }
            }
        }
    }

    @Test func everyRecordingToneAndPreparationPhaseRoundTripsThroughCodec() throws {
        #expect(EngineRecordingTone.allCases.map(\.rawValue) == [
            "neutral", "recording", "warning", "error"
        ])
        #expect(EnginePreparationPhase.allCases.map(\.rawValue) == [
            "idle", "preparing", "ready", "failed"
        ])

        for tone in EngineRecordingTone.allCases {
            for phase in EnginePreparationPhase.allCases {
                var input = baselinePresentationInput()
                input.recordingTone = tone
                input.preparationPhase = phase
                input.preparationStatusText = switch phase {
                case .preparing: "準備しています"
                case .failed: "準備に失敗しました"
                case .idle, .ready: nil
                }
                let presentation = try input.make()
                let state = try stateWithPresentation(presentation)
                let output = try EngineOutput(
                    version: 1,
                    sequence: engineID(1),
                    requestID: nil,
                    event: .state(state)
                )
                let line = try EngineCodec.encodeOutput(output)
                let text = String(decoding: line.dropLast(), as: UTF8.self)
                #expect(try EngineCodec.decodeOutput(Data(line.dropLast())) == output)
                #expect(text.contains("\"recording_tone\":\"\(tone.rawValue)\""))
                #expect(text.contains("\"preparation_phase\":\"\(phase.rawValue)\""))
                if let statusText = input.preparationStatusText {
                    #expect(text.contains("\"preparation_status_text\":\"\(statusText)\""))
                } else {
                    #expect(text.contains(#""preparation_status_text":null"#))
                }
            }
        }
    }

    @Test func requiredPresentationFieldsRejectMissingWrongNullAndUnknownValues() throws {
        let valid = try stateOutputObject(presentation: baselinePresentation())
        let fieldKeys = [
            "recording_status_text", "recording_tone", "preparation_phase", "preparation_status_text",
            "recovery_status_text", "processing_status_text", "live_failure_notices", "silence_warning_active",
            "silence_warning_text", "audio_gap_count", "audio_gap_text", "processing_indicator"
        ]
        let wrongValues: [String: Any] = [
            "recording_status_text": 7,
            "recording_tone": 7,
            "preparation_phase": 7,
            "preparation_status_text": 7,
            "recovery_status_text": 7,
            "processing_status_text": 7,
            "live_failure_notices": "not-an-array",
            "silence_warning_active": "false",
            "silence_warning_text": 7,
            "audio_gap_count": "0",
            "audio_gap_text": 7,
            "processing_indicator": 7
        ]
        for key in fieldKeys {
            let missing = try changingPresentation(in: valid) { $0.removeValue(forKey: key) }
            #expect(try outputDecodingFails(missing), "missing presentation field: \(key)")

            let wrongType = try changingPresentation(in: valid) { $0[key] = wrongValues[key] }
            #expect(try outputDecodingFails(wrongType), "wrong presentation field type: \(key)")
        }

        let nonnullableKeys = [
            "recording_status_text", "recording_tone", "preparation_phase", "live_failure_notices",
            "silence_warning_active", "audio_gap_count", "processing_indicator"
        ]
        for key in nonnullableKeys {
            let nullValue = try changingPresentation(in: valid) { $0[key] = NSNull() }
            #expect(try outputDecodingFails(nullValue), "null nonnullable presentation field: \(key)")
        }

        let nullableKeys = [
            "preparation_status_text", "recovery_status_text", "processing_status_text",
            "silence_warning_text", "audio_gap_text"
        ]
        let validDecoded = try EngineCodec.decodeOutput(jsonData(valid))
        for key in nullableKeys {
            let missing = try changingPresentation(in: valid) { $0.removeValue(forKey: key) }
            #expect(try outputDecodingFails(missing), "missing nullable presentation field: \(key)")

            let explicitNull = try changingPresentation(in: valid) { $0[key] = NSNull() }
            let decodedExplicitNull = try EngineCodec.decodeOutput(jsonData(explicitNull))
            #expect(decodedExplicitNull == validDecoded)
        }

        let unknownPresentationKey = try changingPresentation(in: valid) { $0["future_presentation_key"] = true }
        #expect(try outputDecodingFails(unknownPresentationKey))
        var unknownStateKey = valid
        var payload = try #require(unknownStateKey["payload"] as? [String: Any])
        payload["future_state_key"] = true
        unknownStateKey["payload"] = payload
        #expect(try outputDecodingFails(unknownStateKey))

        let unknownTone = try changingPresentation(in: valid) { $0["recording_tone"] = "future_tone" }
        #expect(try outputDecodingFails(unknownTone))
        let unknownPreparationPhase = try changingPresentation(in: valid) { $0["preparation_phase"] = "future_phase" }
        #expect(try outputDecodingFails(unknownPreparationPhase))
        let unknownIndicator = try changingPresentation(in: valid) { $0["processing_indicator"] = "future_indicator" }
        #expect(try outputDecodingFails(unknownIndicator))
    }

    @Test func presentationObjectIsRequiredAndMustBeExactObject() throws {
        let valid = try stateOutputObject(presentation: baselinePresentation())
        var payloadMissingPresentation = valid
        var payload = try #require(payloadMissingPresentation["payload"] as? [String: Any])
        payload.removeValue(forKey: "presentation")
        payloadMissingPresentation["payload"] = payload
        #expect(try outputDecodingFails(payloadMissingPresentation))

        for invalidPresentation: Any in [NSNull(), "not-an-object", 7] {
            let invalid = try replacingStatePresentation(in: valid, with: invalidPresentation)
            #expect(try outputDecodingFails(invalid))
        }
    }

    @Test func presentationRejectsEveryEmptyStringAndMalformedFailureNotices() throws {
        let valid = try stateOutputObject(presentation: baselinePresentation())
        let stringKeys = [
            "recording_status_text", "recovery_status_text", "processing_status_text",
            "silence_warning_text", "audio_gap_text"
        ]
        for key in stringKeys {
            let emptyString = try changingPresentation(in: valid) { $0[key] = "" }
            #expect(try outputDecodingFails(emptyString), "empty presentation string: \(key)")
        }
        let emptyNotice = try changingPresentation(in: valid) { $0["live_failure_notices"] = [""] }
        #expect(try outputDecodingFails(emptyNotice))

        let nonArrayNotices = try changingPresentation(in: valid) { $0["live_failure_notices"] = 1 }
        #expect(try outputDecodingFails(nonArrayNotices))
        let wrongNoticeElement = try changingPresentation(in: valid) { $0["live_failure_notices"] = ["正常な通知", 1] }
        #expect(try outputDecodingFails(wrongNoticeElement))
    }

    @Test func audioGapCountIsAnExactUnsignedJSONNumberAndRejectsInvalidForms() throws {
        let zeroLine = try stateOutputLine(presentation: baselinePresentation())
        let zeroText = String(decoding: zeroLine, as: UTF8.self)
        #expect(zeroText.contains(#""audio_gap_count":0"#))
        #expect(zeroText.contains(#""audio_gap_text":null"#))
        let decodedZero = try EngineCodec.decodeOutput(Data(zeroLine.dropLast()))
        guard case let .state(zeroState) = decodedZero.event else {
            Issue.record("expected state event for zero audio gap count")
            return
        }
        #expect(zeroState.presentation.audioGapCount == 0)
        #expect(zeroState.presentation.audioGapText == nil)

        var maximumInput = baselinePresentationInput()
        maximumInput.audioGapCount = UInt64.max
        let maximumLine = try stateOutputLine(presentation: maximumInput.make())
        let maximumText = String(decoding: maximumLine, as: UTF8.self)
        #expect(maximumText.contains(#""audio_gap_count":18446744073709551615"#))
        #expect(!maximumText.contains(#""audio_gap_count":"18446744073709551615"#))
        let maximumOutput = try EngineCodec.decodeOutput(Data(maximumLine.dropLast()))
        guard case let .state(maximumState) = maximumOutput.event else {
            Issue.record("expected state event for UInt64.max presentation round trip")
            return
        }
        #expect(maximumState.presentation.audioGapCount == UInt64.max)
        #expect(try EngineCodec.encodeOutput(maximumOutput).range(of: Data(#""audio_gap_count":18446744073709551615"#.utf8)) != nil)

        for invalidCount: Any in [-1, 1.5, true, "1"] {
            let invalid = try changingPresentation(in: try stateOutputObject(presentation: baselinePresentation())) {
                $0["audio_gap_count"] = invalidCount
            }
            #expect(try outputDecodingFails(invalid), "invalid audio_gap_count: \(invalidCount)")
        }
        let overflowText = try replacingExactlyOnce(
            zeroLine,
            from: #""audio_gap_count":0"#,
            with: #""audio_gap_count":18446744073709551616"#
        )
        #expect(outputDecodingFails(Data(overflowText.dropLast())))
    }

    @Test func presentationCrossFieldInvariantsAreRejectedDuringDecodeAndInitialization() throws {
        let valid = try stateOutputObject(presentation: baselinePresentation())
        let activeWithoutText = try changingPresentation(in: valid) {
            $0["silence_warning_active"] = true
        }
        #expect(try outputDecodingFails(activeWithoutText))
        let textWhileInactive = try changingPresentation(in: valid) {
            $0["silence_warning_text"] = "無音が続いています"
        }
        #expect(try outputDecodingFails(textWhileInactive))
        let gapTextAtZero = try changingPresentation(in: valid) {
            $0["audio_gap_text"] = "音声の欠落を検出しました"
        }
        #expect(try outputDecodingFails(gapTextAtZero))

        let textWhileReady = try changingPresentation(in: valid) {
            $0["preparation_status_text"] = "準備しています"
        }
        #expect(try outputDecodingFails(textWhileReady))
        let textWhileIdle = try changingPresentation(in: valid) {
            $0["preparation_phase"] = "idle"
            $0["preparation_status_text"] = "準備しています"
        }
        #expect(try outputDecodingFails(textWhileIdle))
        let preparingWithoutText = try changingPresentation(in: valid) {
            $0["preparation_phase"] = "preparing"
        }
        #expect(try outputDecodingFails(preparingWithoutText))
        let failedWithoutText = try changingPresentation(in: valid) {
            $0["preparation_phase"] = "failed"
        }
        #expect(try outputDecodingFails(failedWithoutText))
        let emptyPreparationText = try changingPresentation(in: valid) {
            $0["preparation_phase"] = "preparing"
            $0["preparation_status_text"] = ""
        }
        #expect(try outputDecodingFails(emptyPreparationText))

        var activeWithoutWarningText = baselinePresentationInput()
        activeWithoutWarningText.silenceWarningActive = true
        #expect(throws: (any Error).self) { try activeWithoutWarningText.make() }
        var warningTextWithoutActive = baselinePresentationInput()
        warningTextWithoutActive.silenceWarningText = "無音が続いています"
        #expect(throws: (any Error).self) { try warningTextWithoutActive.make() }
        var gapTextWithoutCount = baselinePresentationInput()
        gapTextWithoutCount.audioGapText = "音声の欠落を検出しました"
        #expect(throws: (any Error).self) { try gapTextWithoutCount.make() }

        var textWhileReadyInput = baselinePresentationInput()
        textWhileReadyInput.preparationStatusText = "準備しています"
        #expect(throws: (any Error).self) { try textWhileReadyInput.make() }
        var textWhileIdleInput = baselinePresentationInput()
        textWhileIdleInput.preparationPhase = .idle
        textWhileIdleInput.preparationStatusText = "準備しています"
        #expect(throws: (any Error).self) { try textWhileIdleInput.make() }
        var preparingWithoutTextInput = baselinePresentationInput()
        preparingWithoutTextInput.preparationPhase = .preparing
        #expect(throws: (any Error).self) { try preparingWithoutTextInput.make() }
        var failedWithoutTextInput = baselinePresentationInput()
        failedWithoutTextInput.preparationPhase = .failed
        #expect(throws: (any Error).self) { try failedWithoutTextInput.make() }
        var emptyPreparationTextInput = baselinePresentationInput()
        emptyPreparationTextInput.preparationPhase = .preparing
        emptyPreparationTextInput.preparationStatusText = ""
        #expect(throws: (any Error).self) { try emptyPreparationTextInput.make() }
    }

    @Test func initializerRejectsEmptyPresentationStringsAndNoticeElements() throws {
        let base = baselinePresentationInput()
        var emptyRecording = base
        emptyRecording.recordingStatusText = ""
        #expect(throws: (any Error).self) { try emptyRecording.make() }
        var emptyPreparation = base
        emptyPreparation.preparationPhase = .preparing
        emptyPreparation.preparationStatusText = ""
        #expect(throws: (any Error).self) { try emptyPreparation.make() }
        var emptyRecovery = base
        emptyRecovery.recoveryStatusText = ""
        #expect(throws: (any Error).self) { try emptyRecovery.make() }
        var emptyProcessing = base
        emptyProcessing.processingStatusText = ""
        #expect(throws: (any Error).self) { try emptyProcessing.make() }
        var emptyNotice = base
        emptyNotice.liveFailureNotices = [""]
        #expect(throws: (any Error).self) { try emptyNotice.make() }
        var emptyWarning = base
        emptyWarning.silenceWarningActive = true
        emptyWarning.silenceWarningText = ""
        #expect(throws: (any Error).self) { try emptyWarning.make() }
        var emptyGapText = base
        emptyGapText.audioGapCount = 1
        emptyGapText.audioGapText = ""
        #expect(throws: (any Error).self) { try emptyGapText.make() }
    }
}

private struct PresentationInput {
    var recordingStatusText: String
    var recordingTone: EngineRecordingTone
    var preparationPhase: EnginePreparationPhase
    var preparationStatusText: String?
    var recoveryStatusText: String?
    var processingStatusText: String?
    var liveFailureNotices: [String]
    var silenceWarningActive: Bool
    var silenceWarningText: String?
    var audioGapCount: UInt64
    var audioGapText: String?
    var processingIndicator: EngineProcessingIndicator

    func make() throws -> EnginePresentationState {
        try EnginePresentationState(
            recordingStatusText: recordingStatusText,
            recordingTone: recordingTone,
            preparationPhase: preparationPhase,
            preparationStatusText: preparationStatusText,
            recoveryStatusText: recoveryStatusText,
            processingStatusText: processingStatusText,
            liveFailureNotices: liveFailureNotices,
            silenceWarningActive: silenceWarningActive,
            silenceWarningText: silenceWarningText,
            audioGapCount: audioGapCount,
            audioGapText: audioGapText,
            processingIndicator: processingIndicator
        )
    }
}

private func baselinePresentationInput() -> PresentationInput {
    PresentationInput(
        recordingStatusText: "録音しています",
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

private func baselinePresentation() throws -> EnginePresentationState {
    try baselinePresentationInput().make()
}

private func presentationForCodec(
    indicator: EngineProcessingIndicator,
    hasNullableValues: Bool
) throws -> EnginePresentationState {
    try PresentationInput(
        recordingStatusText: "録音しています",
        recordingTone: .neutral,
        preparationPhase: .ready,
        preparationStatusText: nil,
        recoveryStatusText: hasNullableValues ? "復旧しています" : nil,
        processingStatusText: hasNullableValues ? "文字起こしを処理中" : nil,
        liveFailureNotices: ["音声入力に問題があります"],
        silenceWarningActive: hasNullableValues,
        silenceWarningText: hasNullableValues ? "無音が続いています" : nil,
        audioGapCount: hasNullableValues ? 9 : 0,
        audioGapText: hasNullableValues ? "音声の欠落を検出しました" : nil,
        processingIndicator: indicator
    ).make()
}

private func stateWithPresentation(_ presentation: EnginePresentationState) throws -> EngineState {
    try EngineState(
        revision: engineID(1),
        screen: .idle,
        setup: .ready,
        recovery: .completed,
        recording: nil,
        queue: [],
        failures: [],
        presentation: presentation
    )
}

private func stateOutputLine(presentation: EnginePresentationState) throws -> Data {
    let state = try stateWithPresentation(presentation)
    let output = try EngineOutput(version: 1, sequence: engineID(1), requestID: nil, event: .state(state))
    return try EngineCodec.encodeOutput(output)
}

private func stateOutputObject(presentation: EnginePresentationState) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: stateOutputLine(presentation: presentation)) as? [String: Any])
}

private func changingPresentation(
    in envelope: [String: Any],
    _ mutation: (inout [String: Any]) -> Void
) throws -> [String: Any] {
    var changed = envelope
    var payload = try #require(changed["payload"] as? [String: Any])
    var presentation = try #require(payload["presentation"] as? [String: Any])
    mutation(&presentation)
    payload["presentation"] = presentation
    changed["payload"] = payload
    return changed
}

private func replacingStatePresentation(
    in envelope: [String: Any],
    with value: Any
) throws -> [String: Any] {
    var changed = envelope
    var payload = try #require(changed["payload"] as? [String: Any])
    payload["presentation"] = value
    changed["payload"] = payload
    return changed
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func outputDecodingFails(_ object: [String: Any]) throws -> Bool {
    do {
        _ = try EngineCodec.decodeOutput(jsonData(object))
        return false
    } catch {
        return true
    }
}

private func outputDecodingFails(_ data: Data) -> Bool {
    do {
        _ = try EngineCodec.decodeOutput(data)
        return false
    } catch {
        return true
    }
}

private func replacingExactlyOnce(_ data: Data, from needle: String, with replacement: String) throws -> Data {
    let source = String(decoding: data, as: UTF8.self)
    let parts = source.components(separatedBy: needle)
    try #require(parts.count == 2)
    return Data((parts[0] + replacement + parts[1]).utf8)
}

private func engineID(_ value: UInt64) throws -> EngineID {
    try EngineID(value)
}
