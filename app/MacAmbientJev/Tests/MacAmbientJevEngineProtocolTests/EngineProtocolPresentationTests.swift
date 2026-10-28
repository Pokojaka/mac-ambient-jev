import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolPresentationTests {
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

private func stateWithPresentation(_ presentation: EnginePresentationState) throws -> EngineState {
    try EngineState(
        revision: engineID(1),
        screen: .idle,
        setup: .ready,
        profileSetup: .init(evaluation: nil),
        resourceProtection: try .init(holdReasons: []),
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
