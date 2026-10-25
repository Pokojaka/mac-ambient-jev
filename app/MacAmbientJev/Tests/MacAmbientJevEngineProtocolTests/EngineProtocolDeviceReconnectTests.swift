import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolDeviceReconnectTests {
    @Test func reconnectEnumsDecodeOnlyExactWireValues() throws {
        #expect(EngineErrorCode.deviceLost.rawValue == "device_lost")
        #expect(EngineRecordingPhase.waitingForDevice.rawValue == "waiting_for_device")

        for value in EngineErrorCode.allCases {
            #expect(try JSONDecoder().decode(EngineErrorCode.self, from: Data("\"\(value.rawValue)\"".utf8)) == value)
        }
        for value in EngineRecordingPhase.allCases {
            #expect(try JSONDecoder().decode(EngineRecordingPhase.self, from: Data("\"\(value.rawValue)\"".utf8)) == value)
        }

        for invalid in ["\"unknown\"", "\"deviceLost\"", "null", "1", "true", "{}", "[]"] {
            #expect(rejectsEngineEnum(EngineErrorCode.self, value: invalid))
        }
        for invalid in ["\"unknown\"", "\"waitingForDevice\"", "null", "1", "true", "{}", "[]"] {
            #expect(rejectsEngineEnum(EngineRecordingPhase.self, value: invalid))
        }
    }

    @Test func reconnectStateAndFailureRoundTripThroughEngineCodec() throws {
        let sessionID = "session-reconnect"
        let reopenDetail = try EngineErrorDetail(
            domain: "capture",
            code: "reopen",
            message: "mja_capture failed with code -401",
            path: nil,
            deviceID: nil
        )
        let detailCases: [[EngineErrorDetail]] = [[], [reopenDetail]]

        for details in detailCases {
            let failure = try EngineFailure(
                code: .deviceLost,
                message: "録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています",
                stage: .capture,
                requestID: nil,
                sessionID: sessionID,
                severity: .warning,
                recoveryAction: .selectDevice,
                details: details,
                cleanupErrors: []
            )
            let recording = try EngineRecordingState(
                sessionID: sessionID,
                source: .microphone,
                device: .id("device-1"),
                phase: .waitingForDevice
            )
            let presentation = try EnginePresentationState(
                recordingStatusText: "録音デバイスの復帰を待っています",
                recordingTone: .warning,
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
            let state = try EngineState(
                revision: EngineID(1),
                screen: .live,
                setup: .ready,
                recovery: .completed,
                recording: recording,
                queue: [],
                failures: [failure],
                presentation: presentation
            )
            let stateOutput = try EngineOutput(version: 1, sequence: EngineID(2), requestID: nil, event: .state(state))
            let failureOutput = try EngineOutput(version: 1, sequence: EngineID(3), requestID: nil, event: .error(failure))

            let stateLine = try EngineCodec.encodeOutput(stateOutput)
            let failureLine = try EngineCodec.encodeOutput(failureOutput)
            #expect(stateLine.last == 0x0A)
            #expect(failureLine.last == 0x0A)
            try expectReconnectDetails(in: stateLine, stateEvent: true, expected: details)
            try expectReconnectDetails(in: failureLine, stateEvent: false, expected: details)

            let decodedStateOutput = try EngineCodec.decodeOutput(Data(stateLine.dropLast()))
            let decodedFailureOutput = try EngineCodec.decodeOutput(Data(failureLine.dropLast()))
            #expect(decodedStateOutput == stateOutput)
            #expect(decodedFailureOutput == failureOutput)
            guard case let .state(decodedState) = decodedStateOutput.event else {
                Issue.record("Expected a state event")
                continue
            }
            guard case let .error(decodedFailure) = decodedFailureOutput.event else {
                Issue.record("Expected an error event")
                continue
            }
            #expect(decodedState.failures == [failure])
            #expect(decodedState.failures.first?.details == details)
            #expect(decodedFailure.details == details)
        }
    }
}

private func expectReconnectDetails(
    in line: Data,
    stateEvent: Bool,
    expected: [EngineErrorDetail]
) throws {
    let root = try #require(JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: Any])
    let payload = try #require(root["payload"] as? [String: Any])
    let failure: [String: Any]
    if stateEvent {
        let failures = try #require(payload["failures"] as? [[String: Any]])
        failure = try #require(failures.first)
    } else {
        failure = payload
    }
    let details = try #require(failure["details"] as? [[String: Any]])
    #expect(details.count == expected.count)

    for (encoded, detail) in zip(details, expected) {
        #expect(Set(encoded.keys) == Set(["domain", "code", "message", "path", "device_id"]))
        #expect(encoded["domain"] as? String == detail.domain)
        #expect(encoded["code"] as? String == detail.code)
        #expect(encoded["message"] as? String == detail.message)
        if let path = detail.path {
            #expect(encoded["path"] as? String == path)
        } else {
            #expect(encoded["path"] is NSNull)
        }
        if let deviceID = detail.deviceID {
            #expect(encoded["device_id"] as? String == deviceID)
        } else {
            #expect(encoded["device_id"] is NSNull)
        }
    }
}

private func rejectsEngineEnum<Value: Decodable>(_ type: Value.Type, value: String) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: Data(value.utf8))
        return false
    } catch {
        return true
    }
}
