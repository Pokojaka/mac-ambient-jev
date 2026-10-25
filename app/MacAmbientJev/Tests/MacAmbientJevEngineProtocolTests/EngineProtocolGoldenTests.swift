import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolGoldenTests {
    @Test func canonicalFixtureRoundTripsAndCoversEveryCommandAndEvent() throws {
        let records = try goldenRecords()
        #expect(records.count == 72)
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

    @Test func fixtureCoversPresentationSemanticsAcrossStateEnvelopes() throws {
        let expectedPresentationKeys: Set<String> = [
            "recording_status_text", "recording_tone", "preparation_phase", "preparation_status_text",
            "recovery_status_text", "processing_status_text", "live_failure_notices", "silence_warning_active",
            "silence_warning_text", "audio_gap_count", "audio_gap_text", "processing_indicator",
        ]
        var recordingTones = Set<String>()
        var preparationPhases = Set<String>()
        var envelopeKinds = Set<String>()
        var sawOrdinaryPartialFailureProcessingText = false

        func collectPresentation(
            _ state: EngineState,
            from stateObject: [String: Any],
            envelope: String
        ) throws {
            let presentation = state.presentation
            let presentationObject = try #require(stateObject["presentation"] as? [String: Any])
            #expect(Set(presentationObject.keys) == expectedPresentationKeys, "presentation keys in \(envelope)")
            recordingTones.insert(presentation.recordingTone.rawValue)
            preparationPhases.insert(presentation.preparationPhase.rawValue)
            envelopeKinds.insert(envelope)

            let preparationRequiresStatusText = presentation.preparationPhase == .preparing || presentation.preparationPhase == .failed
            #expect(
                (presentation.preparationStatusText != nil) == preparationRequiresStatusText,
                "preparation status text presence in \(envelope)"
            )

            if presentation.processingIndicator == .partialFailure {
                let processingText = try #require(presentation.processingStatusText)
                #expect(processingText == "録音中の発話を文字起こししています")
                #expect(!presentation.liveFailureNotices.contains(processingText))
                sawOrdinaryPartialFailureProcessingText = true
            }
        }

        for record in try goldenRecords() {
            let metadata = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            guard metadata.keys.contains("event") else { continue }
            let output = try EngineCodec.decodeOutput(record)
            let payload = try #require(metadata["payload"] as? [String: Any])
            switch output.event {
            case let .state(state):
                try collectPresentation(state, from: payload, envelope: "state")
            case let .ready(ready):
                let stateObject = try #require(payload["state"] as? [String: Any])
                #expect(ready.state.presentation.recordingTone == .neutral)
                #expect(ready.state.presentation.preparationPhase == .idle)
                #expect(ready.state.presentation.preparationStatusText == nil)
                try collectPresentation(ready.state, from: stateObject, envelope: "ready")
            case let .completed(result):
                let resultObject = try #require(payload["result"] as? [String: Any])
                switch result {
                case let .hello(ready):
                    let stateObject = try #require(resultObject["state"] as? [String: Any])
                    #expect(ready.state.presentation.recordingTone == .neutral)
                    #expect(ready.state.presentation.preparationPhase == .idle)
                    #expect(ready.state.presentation.preparationStatusText == nil)
                    try collectPresentation(ready.state, from: stateObject, envelope: "completed.hello")
                case let .stateGet(state):
                    try collectPresentation(state, from: resultObject, envelope: "completed.stateGet")
                default:
                    break
                }
            case .rows, .error, .progress, .accepted:
                break
            }
        }

        #expect(recordingTones == Set(EngineRecordingTone.allCases.map(\.rawValue)))
        #expect(preparationPhases == Set(EnginePreparationPhase.allCases.map(\.rawValue)))
        #expect(envelopeKinds == ["state", "ready", "completed.hello", "completed.stateGet"])
        #expect(sawOrdinaryPartialFailureProcessingText)
    }

    @Test func fixtureExposesReconnectStateAndDeviceLostAsTypedValues() throws {
        var sawWaitingForDeviceState = false
        var sawDeviceLostReason = false

        for record in try goldenRecords() {
            let metadata = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            guard metadata.keys.contains("event") else { continue }
            let output = try EngineCodec.decodeOutput(record)
            switch output.event {
            case let .state(state) where output.sequence.value == 115:
                #expect(output.requestID == nil)
                #expect(state.revision.value == 115)
                #expect(state.screen == .live)
                #expect(state.setup == .ready)
                #expect(state.recovery == .completed)
                #expect(state.queue.isEmpty)
                #expect(state.failures.isEmpty)

                let recording = try #require(state.recording)
                #expect(recording.sessionID == "session-reconnect")
                #expect(recording.source == .microphone)
                #expect(recording.device == .id("wasapi-mic-reconnect"))
                #expect(recording.phase == .waitingForDevice)
                #expect(recording.phase.rawValue == "waiting_for_device")

                #expect(state.presentation.recordingStatusText == "録音デバイスの復帰を待っています")
                #expect(state.presentation.recordingTone == .warning)
                #expect(state.presentation.preparationPhase == .ready)
                #expect(state.presentation.preparationStatusText == nil)
                #expect(state.presentation.recoveryStatusText == nil)
                #expect(state.presentation.processingStatusText == nil)
                #expect(state.presentation.liveFailureNotices.isEmpty)
                #expect(!state.presentation.silenceWarningActive)
                #expect(state.presentation.silenceWarningText == nil)
                #expect(state.presentation.audioGapCount == 1)
                #expect(state.presentation.audioGapText == "音声の欠落: 1 回")
                #expect(state.presentation.processingIndicator == .idle)
                sawWaitingForDeviceState = true

            case let .error(failure) where output.sequence.value == 116:
                #expect(output.requestID == nil)
                #expect(failure.code == .deviceLost)
                #expect(failure.code.rawValue == "device_lost")
                #expect(failure.message == "録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています")
                #expect(failure.stage == .capture)
                #expect(failure.requestID == nil)
                #expect(failure.sessionID == "session-reconnect")
                #expect(failure.severity == .warning)
                #expect(failure.recoveryAction == .selectDevice)
                #expect(failure.details.count == 1)
                let detail = try #require(failure.details.first)
                #expect(detail.domain == "capture")
                #expect(detail.code == "reopen")
                #expect(detail.message == "mja_capture failed with code -401")
                #expect(detail.deviceID == nil)
                #expect(detail.path == nil)
                #expect(failure.cleanupErrors.isEmpty)
                sawDeviceLostReason = true

            default:
                break
            }
        }

        #expect(sawWaitingForDeviceState)
        #expect(sawDeviceLostReason)
    }

    @Test func fixturePreservesRepresentativeTypedSemantics() throws {
        let records = try goldenRecords()
        var sawUnconfiguredAutoExportReplacement = false
        var sawMicrophoneDefaultSelector = false
        var sawSystemAudioIDSelector = false
        var sawUInt64Maximum = false
        var sawLiveBusyState = false
        var sawReconnectWaitingState = false
        var sawConfiguredSettingsResult = false
        var sawEndpointDefault = false
        var sawUnreadableAndReadableSessions = false
        var sawSessionInspectRequest = false
        var sawUnreadableSessionInspect = false
        var sawReadableSessionInspect = false
        var sawMicrophoneSessionSource = false
        var sawSystemAudioSessionSource = false
        var sawImportedSessionSource = false
        var sawAvailableSessionAudio = false
        var sawMissingSessionAudio = false
        var sawUnreadableSessionAudio = false
        var sawPreviousCursorNull = false
        var sawPreviousCursorNonNull = false
        var sawEscapedJapaneseEmojiRow = false
        var sawNullClauseState = false
        var sawKnownClauseState = false
        var sawCorrelatedError = false
        var sawUnsolicitedError = false
        var sawDeviceLostUnsolicitedError = false
        var sawNativeErrorDetails = false
        var sawKnownProgressTotal = false
        var sawUnknownProgressTotal = false
        var sawNonNullRevisionAndCursor = false
        var sawDiagnosticsRequest = false
        var sawModelsInspectRequest = false
        var sawInspectionCancellation = false
        var sawRowNotFoundError = false
        var sawStaleRevisionError = false
        var sawAvailableDiagnostics = false
        var sawUnavailableDiagnostics = false
        var sawValidatedModelInspection = false
        var sawInvalidModelInspection = false
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
                        #expect(value.sessions.count == 5)
                        let unreadable = try #require(value.sessions.first { $0.status == .unreadable })
                        #expect(unreadable.folderID == "stable-folder-id-corrupt-metadata-17")
                        #expect(unreadable.sessionID == nil)
                        #expect(unreadable.statusText == "読み込みエラー: セッション情報を読み取れません")
                        #expect(unreadable.displayName == "日時を読み取れません")
                        #expect(unreadable.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17")
                        #expect(unreadable.exportPath == nil)
                        #expect(!unreadable.canReprocess && !unreadable.canRetryDecisions && !unreadable.canExport)
                        let unreadableError = try #require(unreadable.error)
                        #expect(unreadableError.code == .filesystem)
                        #expect(unreadableError.stage == .recovery)
                        #expect(unreadableError.severity == .warning)
                        #expect(unreadableError.recoveryAction == .inspectSession)
                        #expect(unreadableError.message == "セッション情報を読み取れません")
                        #expect(unreadableError.requestID == nil)
                        #expect(unreadableError.sessionID == nil)
                        let unreadableDetail = try #require(unreadableError.details.first)
                        #expect(unreadableDetail.path == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17/session.json")
                        #expect(unreadable.metadata == .unreadable(reason: "セッション情報を読み取れません"))

                        // Check every enriched summary field.
                        let readable = try #require(value.sessions.first { $0.status == .finalized })
                        #expect(readable.sessionID == "session-finalized-2025-03-08T10-22-31Z")
                        #expect(readable.folderID == "session-folder-2025-03-08-live")
                        #expect(readable.displayName == "2025年3月8日 19:22")
                        #expect(readable.statusText == "文字起こしあり")
                        #expect(readable.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-2025-03-08-live")
                        #expect(readable.error == nil)
                        #expect(readable.exportPath == nil)
                        #expect(readable.canReprocess && !readable.canRetryDecisions && readable.canExport)
                        if case let .readable(createdAt, source, audio, hasTranscript) = readable.metadata {
                            #expect(createdAt == 1741429351)
                            #expect(source == .microphone)
                            #expect(audio == .available)
                            #expect(hasTranscript)
                            sawMicrophoneSessionSource = true
                            sawAvailableSessionAudio = true
                        } else {
                            #expect(Bool(false), "Finalized session must have readable metadata")
                        }

                        let systemAudioFailed = try #require(value.sessions.first { $0.folderID == "session-folder-system-audio-missing-2025-03-10T08-00-00Z" })
                        #expect(systemAudioFailed.status == .failed)
                        #expect(systemAudioFailed.sessionID == "session-system-audio-missing-2025-03-10T08-00-00Z")
                        #expect(systemAudioFailed.displayName == "2025年3月10日 17:00")
                        #expect(systemAudioFailed.statusText == "保存済み音声がありません")
                        #expect(systemAudioFailed.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-system-audio-missing-2025-03-10T08-00-00Z")
                        #expect(systemAudioFailed.error == nil && systemAudioFailed.exportPath == nil)
                        #expect(!systemAudioFailed.canReprocess && !systemAudioFailed.canRetryDecisions && !systemAudioFailed.canExport)
                        if case let .readable(createdAt, source, audio, hasTranscript) = systemAudioFailed.metadata {
                            #expect(createdAt == 1741593600)
                            #expect(source == .systemAudio)
                            #expect(audio == .missing)
                            #expect(!hasTranscript)
                            sawSystemAudioSessionSource = true
                            sawMissingSessionAudio = true
                        } else {
                            #expect(Bool(false), "System-audio session must have readable metadata")
                        }

                        let importedAudioFailed = try #require(value.sessions.first { $0.folderID == "session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z" })
                        #expect(importedAudioFailed.status == .failed)
                        #expect(importedAudioFailed.sessionID == "session-imported-audio-unreadable-2025-03-11T00-30-00Z")
                        #expect(importedAudioFailed.displayName == "2025年3月11日 9:30")
                        #expect(importedAudioFailed.statusText == "音声を読めません: 音声ファイルを読めません")
                        #expect(importedAudioFailed.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z")
                        #expect(importedAudioFailed.error == nil && importedAudioFailed.exportPath == nil)
                        #expect(!importedAudioFailed.canReprocess && !importedAudioFailed.canRetryDecisions && !importedAudioFailed.canExport)
                        if case let .readable(createdAt, source, audio, hasTranscript) = importedAudioFailed.metadata {
                            #expect(createdAt == 1741653000)
                            #expect(source == .imported(originalFilename: "meeting.wav"))
                            #expect(audio == .unreadable(reason: "音声ファイルを読めません"))
                            #expect(!hasTranscript)
                            sawImportedSessionSource = true
                            sawUnreadableSessionAudio = true
                        } else {
                            #expect(Bool(false), "Imported session must have readable metadata")
                        }

                        let exportFailed = try #require(value.sessions.first { $0.folderID == "session-folder-export-probe-failed" })
                        #expect(exportFailed.status == .finalized)
                        #expect(exportFailed.sessionID == "session-export-probe-failed")
                        #expect(exportFailed.folderID == "session-folder-export-probe-failed")
                        #expect(exportFailed.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-export-probe-failed")
                        #expect(exportFailed.displayName == "2025年3月8日 19:22")
                        #expect(exportFailed.statusText == "文字起こしあり")
                        #expect(exportFailed.exportPath == nil)
                        #expect(exportFailed.canReprocess && !exportFailed.canRetryDecisions && exportFailed.canExport)
                        if case let .readable(createdAt, source, audio, hasTranscript) = exportFailed.metadata {
                            #expect(createdAt == 1741429351)
                            #expect(source == .microphone)
                            #expect(audio == .available)
                            #expect(hasTranscript)
                        } else {
                            #expect(Bool(false), "Export-failed session must retain readable metadata")
                        }
                        let exportError = try #require(exportFailed.error)
                        #expect(exportError.code == .exportFailure)
                        #expect(exportError.stage == .exporting)
                        #expect(exportError.requestID == nil)
                        #expect(exportError.sessionID == "session-export-probe-failed")
                        #expect(exportError.severity == .error)
                        #expect(exportError.recoveryAction == .retry)
                        #expect(exportError.message == "書き出し先を確認できません: アクセスが拒否されました")
                        #expect(exportError.details.isEmpty)
                        #expect(exportError.cleanupErrors.isEmpty)

                        sawUnreadableAndReadableSessions = true
                        #expect(value.nextCursor == "folder-page-cursor-2")
                        #expect(value.previousCursor == nil)
                        sawPreviousCursorNull = true
                        sawNonNullRevisionAndCursor = true
                    case let .sessionInspect(summary):
                        if summary.status == .unreadable {
                            #expect(summary.folderID == "stable-folder-id-corrupt-metadata-17")
                            #expect(summary.sessionID == "session-known-unreadable-17")
                            #expect(summary.statusText == "読み込みエラー: セッション情報を読み取れません")
                            #expect(summary.displayName == "日時を読み取れません")
                            #expect(summary.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17")
                            #expect(summary.exportPath == nil)
                            #expect(!summary.canReprocess && !summary.canRetryDecisions && !summary.canExport)
                            #expect(summary.metadata == .unreadable(reason: "セッション情報を読み取れません"))
                            let error = try #require(summary.error)
                            #expect(error.code == .filesystem)
                            #expect(error.stage == .recovery)
                            #expect(error.severity == .warning)
                            #expect(error.recoveryAction == .inspectSession)
                            #expect(error.message == "セッション情報を読み取れません")
                            #expect(error.requestID == nil && error.sessionID == "session-known-unreadable-17")
                            let detail = try #require(error.details.first)
                            #expect(detail.path == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/stable-folder-id-corrupt-metadata-17/session.json")
                            sawUnreadableSessionInspect = true
                        } else {
                            #expect(summary.status == .finalized)
                            #expect(summary.folderID == "session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z")
                            #expect(summary.sessionID == "session-imported-audio-unreadable-2025-03-11T00-30-00Z")
                            #expect(summary.displayName == "2025年3月11日 9:30")
                            #expect(summary.statusText == "文字起こしあり")
                            #expect(summary.folderPath == "C:/Users/Aki/AppData/Local/mac-ambient-jev/sessions/session-folder-imported-audio-unreadable-2025-03-11T00-30-00Z")
                            #expect(summary.error == nil)
                            #expect(summary.exportPath == "D:/Published/session-folder-imported")
                            #expect(summary.canReprocess && !summary.canRetryDecisions && summary.canExport)
                            if case let .readable(createdAt, source, audio, hasTranscript) = summary.metadata {
                                #expect(createdAt == 1741653000)
                                #expect(source == .imported(originalFilename: "meeting.wav"))
                                #expect(audio == .available)
                                #expect(hasTranscript)
                                sawImportedSessionSource = true
                                sawAvailableSessionAudio = true
                            } else {
                                #expect(Bool(false), "Imported inspect result must have readable metadata")
                            }
                            sawReadableSessionInspect = true
                        }
                    case let .transcriptRead(page):
                        #expect(page.revision.value == 184)
                        #expect(page.nextCursor == "rows-cursor-after-2")
                        #expect(page.previousCursor == "rows-cursor-before-2")
                        sawPreviousCursorNonNull = true
                        sawNonNullRevisionAndCursor = true
                    case let .transcriptWatch(page):
                        #expect(page.previousCursor == nil)
                        sawPreviousCursorNull = true
                    case let .diagnosticsGet(diagnostics):
                        #expect(diagnostics.scope == .engineProcess)
                        #expect(diagnostics.automaticInputVolume == .none)
                        #expect(diagnostics.thermalMonitoring == .none)
                        switch diagnostics.decisionUsage {
                        case let .available(snapshot):
                            #expect(output.requestID?.value == 19)
                            #expect(output.sequence.value == 35)
                            #expect(snapshot.sendCount == 4)
                            #expect(snapshot.inputTokens == 28)
                            #expect(snapshot.successCount == 2)
                            #expect(snapshot.failureCount == 2)
                            #expect(snapshot.pendingBoundarySegmentCount == 2)
                            #expect(snapshot.pendingPriorityClauseCount == 3)
                            #expect(snapshot.boundaryRequests.sendCount == 2)
                            #expect(snapshot.boundaryRequests.inputTokens == 11)
                            #expect(snapshot.boundaryRequests.successCount == 1)
                            #expect(snapshot.boundaryRequests.failureCount == 1)
                            #expect(snapshot.priorityRequests.sendCount == 2)
                            #expect(snapshot.priorityRequests.inputTokens == 17)
                            #expect(snapshot.priorityRequests.successCount == 1)
                            #expect(snapshot.priorityRequests.failureCount == 1)
                            sawAvailableDiagnostics = true
                        case let .unavailable(failure):
                            #expect(output.requestID?.value == 19)
                            #expect(output.sequence.value == 36)
                            #expect(failure.code == .internalError)
                            #expect(failure.message == "判断情報を収集できませんでした")
                            #expect(failure.stage == .decisions)
                            #expect(failure.requestID == nil && failure.sessionID == nil)
                            #expect(failure.severity == .error)
                            #expect(failure.recoveryAction == .retry)
                            let detail = try #require(failure.details.first)
                            #expect(detail.domain == "native")
                            #expect(detail.code == "DECISION_BACKEND_UNAVAILABLE")
                            #expect(detail.message == "ネイティブ判断バックエンドに接続できません")
                            sawUnavailableDiagnostics = true
                        }
                    case let .modelsInspect(inspection):
                        switch inspection.clauseTagger {
                        case let .validated(identity):
                            #expect(output.requestID?.value == 20)
                            #expect(output.sequence.value == 37)
                            #expect(identity.backend == "onnx-clause-tagger")
                            #expect(identity.modelID == "Pokojaka/modernbert-ja-30m-utterance-tagger")
                            #expect(identity.revision == "90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9")
                            #expect(identity.tokenizerSHA256 == "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062")
                            sawValidatedModelInspection = true
                        case let .invalid(failure):
                            let modelDirectory = "C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/5c0213592cf8d59fc0b665183ab7536ddde05d1f/clause-tagger-onnx"
                            let modelPath = "\(modelDirectory)/ClauseTagger.onnx"
                            let modelFailureMessage = "モデル(clause_tagger)が不正です: \(modelPath) (サイズが一致しません (期待: 146889562, 実際: 1))。次の手順で配置し直してください: python3 scripts/fetch_clause_tagger.py --format onnx を実行し、出力されたディレクトリの内容を \(modelDirectory) に置く"
                            #expect(output.requestID?.value == 20)
                            #expect(output.sequence.value == 38)
                            #expect(failure.code == .modelCorrupt)
                            #expect(failure.message == modelFailureMessage)
                            #expect(failure.stage == .validatingModels)
                            #expect(failure.requestID == nil && failure.sessionID == nil)
                            #expect(failure.severity == .error)
                            #expect(failure.recoveryAction == .prepareModels)
                            #expect(failure.cleanupErrors.isEmpty)
                            #expect(failure.details.count == 1)
                            let detail = try #require(failure.details.first)
                            #expect(detail.domain == "models")
                            #expect(detail.code == "clause_tagger")
                            #expect(detail.path == nil)
                            #expect(detail.deviceID == nil)
                            #expect(detail.message == modelFailureMessage)
                            sawInvalidModelInspection = true
                        }
                    case .hello, .stateGet, .recordingStart, .recordingStop, .sessionImport, .sessionReprocess,
                         .sessionRetryDecisions, .transcriptRowDetails, .sessionExport, .modelsPrepare, .shutdown:
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
                        } else if requestID.value == 20 {
                            #expect(output.sequence.value == 39)
                            #expect(failure.code == .cancelled)
                            #expect(failure.message == "モデルの確認が中止されました")
                            #expect(failure.stage == .validatingModels)
                            #expect(failure.sessionID == nil)
                            #expect(failure.severity == .error)
                            #expect(failure.recoveryAction == .none)
                            #expect(failure.details.isEmpty)
                            #expect(failure.cleanupErrors.isEmpty)
                            sawInspectionCancellation = true
                        } else if requestID.value == 108 {
                            #expect(output.sequence.value == 106)
                            #expect(failure.code == .rowNotFound)
                            #expect(failure.message == "指定された文字起こし行が見つかりません")
                            #expect(failure.stage == .finalization)
                            #expect(failure.requestID == requestID)
                            #expect(failure.sessionID == "session-detail-missing")
                            #expect(failure.severity == .error)
                            #expect(failure.recoveryAction == .inspectSession)
                            #expect(failure.details.isEmpty)
                            #expect(failure.cleanupErrors.isEmpty)
                            sawRowNotFoundError = true
                        } else if requestID.value == 109 {
                            #expect(output.sequence.value == 107)
                            #expect(failure.code == .staleRevision)
                            #expect(failure.message == "文字起こしの revision が古くなっています。最初から読み直してください")
                            #expect(failure.stage == .finalization)
                            #expect(failure.requestID == requestID)
                            #expect(failure.sessionID == "session-detail-stale")
                            #expect(failure.severity == .error)
                            #expect(failure.recoveryAction == .retry)
                            #expect(failure.details.isEmpty)
                            #expect(failure.cleanupErrors.isEmpty)
                            sawStaleRevisionError = true
                        } else {
                            #expect(Bool(false), "Unexpected correlated error request ID \(requestID.rawValue)")
                        }
                    } else {
                        #expect(failure.requestID == nil)
                        if failure.code == .deviceLost {
                            #expect(output.sequence.value == 116)
                            #expect(output.requestID == nil)
                            #expect(failure.code == .deviceLost)
                            #expect(failure.message == "録音デバイスが30秒以内に復帰しなかったため録音を停止しました。録音は保存されています")
                            #expect(failure.stage == .capture)
                            #expect(failure.sessionID == "session-reconnect")
                            #expect(failure.severity == .warning)
                            #expect(failure.recoveryAction == .selectDevice)
                            #expect(failure.details.count == 1)
                            let detail = try #require(failure.details.first)
                            #expect(detail.domain == "capture")
                            #expect(detail.code == "reopen")
                            #expect(detail.message == "mja_capture failed with code -401")
                            #expect(detail.deviceID == nil)
                            #expect(detail.path == nil)
                            #expect(failure.cleanupErrors.isEmpty)
                            sawDeviceLostUnsolicitedError = true
                        } else {
                            #expect(failure.message.contains("バックグラウンド処理"))
                            sawUnsolicitedError = true
                        }
                    }
                case let .state(state):
                    if state.recording?.phase == .waitingForDevice {
                        #expect(output.sequence.value == 115)
                        #expect(output.requestID == nil)
                        #expect(state.revision.value == 115)
                        #expect(state.screen == .live)
                        #expect(state.setup == .ready)
                        #expect(state.recovery == .completed)
                        #expect(state.recording?.sessionID == "session-reconnect")
                        #expect(state.recording?.source == .microphone)
                        #expect(state.recording?.device == .id("wasapi-mic-reconnect"))
                        #expect(state.recording?.phase == .waitingForDevice)
                        #expect(state.queue.isEmpty)
                        #expect(state.failures.isEmpty)
                        #expect(state.presentation.recordingStatusText == "録音デバイスの復帰を待っています")
                        #expect(state.presentation.recordingTone == .warning)
                        #expect(state.presentation.preparationPhase == .ready)
                        #expect(state.presentation.preparationStatusText == nil)
                        #expect(state.presentation.recoveryStatusText == nil)
                        #expect(state.presentation.processingStatusText == nil)
                        #expect(state.presentation.liveFailureNotices.isEmpty)
                        #expect(!state.presentation.silenceWarningActive)
                        #expect(state.presentation.silenceWarningText == nil)
                        #expect(state.presentation.audioGapCount == 1)
                        #expect(state.presentation.audioGapText == "音声の欠落: 1 回")
                        #expect(state.presentation.processingIndicator == .idle)
                        sawReconnectWaitingState = true
                    } else {
                        #expect(state.screen == .live)
                        #expect(state.recording?.sessionID == "session-live")
                        #expect(!state.queue.isEmpty)
                        #expect(!state.failures.isEmpty)
                        #expect(state.presentation.recordingStatusText == "システム音声を録音中")
                        #expect(state.presentation.recordingTone == .recording)
                        #expect(state.presentation.preparationPhase == .ready)
                        #expect(state.presentation.preparationStatusText == nil)
                        #expect(state.presentation.recoveryStatusText == "未完了の文字起こしを復旧しています（2件）")
                        #expect(state.presentation.processingStatusText == "文字起こし処理が待機中です")
                        #expect(state.presentation.liveFailureNotices.isEmpty)
                        #expect(state.presentation.silenceWarningActive)
                        #expect(state.presentation.silenceWarningText == "システム音声が30秒以上無音です")
                        #expect(state.presentation.audioGapCount == 2)
                        #expect(state.presentation.audioGapText == "音声の欠落: 2 回")
                        #expect(state.presentation.processingIndicator == .backlogged)
                        let failure = try #require(state.failures.first)
                        let detail = try #require(failure.details.first)
                        #expect(detail.path?.contains("/sessions/session-live/audio.wav") == true)
                        #expect(detail.deviceID == "wasapi-mic-17")
                        #expect(!failure.cleanupErrors.isEmpty)
                        sawLiveBusyState = true
                    }
                case let .ready(payload):
                    #expect(payload.state.setup == .settingsRequired)
                    #expect(payload.state.recovery == .pending)
                    #expect(payload.state.presentation.recordingStatusText == "待機中")
                    #expect(payload.state.presentation.recordingTone == .neutral)
                    #expect(payload.state.presentation.preparationPhase == .idle)
                    #expect(payload.state.presentation.preparationStatusText == nil)
                    #expect(payload.state.presentation.recoveryStatusText == nil)
                    #expect(payload.state.presentation.processingStatusText == nil)
                    #expect(payload.state.presentation.liveFailureNotices.isEmpty)
                    #expect(!payload.state.presentation.silenceWarningActive)
                    #expect(payload.state.presentation.silenceWarningText == nil)
                    #expect(payload.state.presentation.audioGapCount == 0)
                    #expect(payload.state.presentation.audioGapText == nil)
                    #expect(payload.state.presentation.processingIndicator == .idle)
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
                case let .sessionInspect(payload):
                    #expect(payload.folderID == "stable-folder-id-corrupt-metadata-17")
                    sawSessionInspectRequest = true
                case let .transcriptRead(payload):
                    #expect(payload.revision?.value == 184)
                    #expect(payload.cursor == "rows-cursor-1")
                    sawNonNullRevisionAndCursor = true
                case .diagnosticsGet:
                    #expect(request.requestID.value == 19)
                    sawDiagnosticsRequest = true
                case .modelsInspect:
                    #expect(request.requestID.value == 20)
                    sawModelsInspectRequest = true
                case .hello, .stateGet, .devicesList, .recordingStop, .sessionImport, .sessionReprocess,
                     .sessionRetryDecisions, .sessionList, .transcriptWatch, .transcriptRowDetails,
                     .sessionExport, .settingsGet, .modelsPrepare, .shutdown:
                    break
                }
            }
        }

        #expect(sawUnconfiguredAutoExportReplacement)
        #expect(sawMicrophoneDefaultSelector)
        #expect(sawSystemAudioIDSelector)
        #expect(sawUInt64Maximum)
        #expect(sawLiveBusyState)
        #expect(sawReconnectWaitingState)
        #expect(sawConfiguredSettingsResult)
        #expect(sawEndpointDefault)
        #expect(sawUnreadableAndReadableSessions)
        #expect(sawSessionInspectRequest)
        #expect(sawUnreadableSessionInspect)
        #expect(sawReadableSessionInspect)
        #expect(sawMicrophoneSessionSource)
        #expect(sawSystemAudioSessionSource)
        #expect(sawImportedSessionSource)
        #expect(sawAvailableSessionAudio)
        #expect(sawMissingSessionAudio)
        #expect(sawUnreadableSessionAudio)
        #expect(sawPreviousCursorNull)
        #expect(sawPreviousCursorNonNull)
        #expect(sawEscapedJapaneseEmojiRow)
        #expect(sawNullClauseState)
        #expect(sawKnownClauseState)
        #expect(sawCorrelatedError)
        #expect(sawUnsolicitedError)
        #expect(sawDeviceLostUnsolicitedError)
        #expect(sawNativeErrorDetails)
        #expect(sawKnownProgressTotal)
        #expect(sawUnknownProgressTotal)
        #expect(sawNonNullRevisionAndCursor)
        #expect(sawDiagnosticsRequest)
        #expect(sawModelsInspectRequest)
        #expect(sawAvailableDiagnostics)
        #expect(sawUnavailableDiagnostics)
        #expect(sawValidatedModelInspection)
        #expect(sawInvalidModelInspection)
        #expect(sawInspectionCancellation)
        #expect(sawRowNotFoundError)
        #expect(sawStaleRevisionError)
        #expect(rowLabels == Set(EngineSpeakerLabel.allCases.map(\.rawValue)))
    }

    @Test func rowDetailsCorpusCoversTypedFieldsStatesSpeakersAndPageArms() throws {
        let revision = try EngineID(999)
        let encodedPayload = try EngineTranscriptRowDetailsPayload(
            sessionID: "schema-session", revision: revision, rowID: "schema-row", cursor: nil, limit: 1
        )
        let encodedSpan = try EngineTranscriptSpeakerSpan(
            speakerID: "schema-speaker", displayLabel: "Schema Speaker", startMS: 0, endMS: 1
        )
        let encodedPage = try EngineTranscriptRowDetailsPage(
            sessionID: "schema-session", revision: revision, rowID: "schema-row",
            clauseState: .classified, clauseStateText: "発話文: 判定済み", speakers: [encodedSpan],
            nextCursor: nil, previousCursor: nil
        )
        let payloadKeys = try encodedObjectKeys(encodedPayload)
        let spanKeys = try encodedObjectKeys(encodedSpan)
        let pageKeys = try encodedObjectKeys(encodedPage)
        let encodedClauseStates = try encodedStringValues(EngineClauseState.allCases)

        var fixturePayloadKeys = Set<String>()
        var fixtureSpanKeys = Set<String>()
        var fixturePageKeys = Set<String>()
        var payloadCursorArms = Set<String>()
        var clauseStates = Set<String>()
        var speakerDisplayLabels = Set<String>()
        var pagePositionArms = Set<String>()
        var sawEmptySpeakers = false
        var sawNonemptySpeakers = false
        var sawRepeatedOverlappingSpeaker = false

        for record in try goldenRecords() {
            let metadata = try #require(JSONSerialization.jsonObject(with: record) as? [String: Any])
            if metadata.keys.contains("event") {
                let output = try EngineCodec.decodeOutput(record)
                guard case let .completed(.transcriptRowDetails(page)) = output.event else { continue }
                let eventPayload = try #require(metadata["payload"] as? [String: Any])
                let result = try #require(eventPayload["result"] as? [String: Any])
                fixturePageKeys.formUnion(result.keys)
                let encodedSpeakers = try #require(result["speakers"] as? [[String: Any]])
                for speaker in encodedSpeakers {
                    fixtureSpanKeys.formUnion(speaker.keys)
                }

                clauseStates.insert(page.clauseState.rawValue)
                speakerDisplayLabels.formUnion(page.speakers.map(\.displayLabel))
                let spanSignatures = page.speakers.map {
                    "\($0.speakerID)|\($0.displayLabel)|\($0.startMS)|\($0.endMS)"
                }
                if page.speakers.isEmpty { sawEmptySpeakers = true }
                if !page.speakers.isEmpty { sawNonemptySpeakers = true }

                switch page.rowID {
                case "row-detail-201":
                    #expect(page.sessionID == "session-detail-a")
                    #expect(page.revision.value == 201)
                    #expect(page.clauseState == .awaitingNextSegment)
                    #expect(page.clauseStateText == "発話文: 続き待ち")
                    #expect(page.previousCursor == nil)
                    #expect(page.nextCursor == "11111111-1111-4111-8111-111111111111")
                    #expect(spanSignatures == [
                        "speaker-internal-101|Speaker 1|0|850",
                        "speaker-internal-101|Speaker 1|700|1500",
                    ])
                    #expect(page.speakers[0].speakerID == page.speakers[1].speakerID)
                    #expect(page.speakers[0].startMS < page.speakers[1].startMS)
                    #expect(page.speakers[1].startMS < page.speakers[0].endMS)
                    #expect(page.speakers[0].endMS < page.speakers[1].endMS)
                    sawRepeatedOverlappingSpeaker = true
                    pagePositionArms.insert("first")
                case "row-detail-202":
                    #expect(page.sessionID == "session-detail-b")
                    #expect(page.revision.value == 202)
                    #expect(page.clauseState == .boundaryPending)
                    #expect(page.clauseStateText == "発話文: 境界判定を保留中")
                    #expect(page.previousCursor == "33333333-3333-4333-8333-333333333333")
                    #expect(page.nextCursor == "22222222-2222-4222-8222-222222222222")
                    #expect(spanSignatures == [
                        "speaker-internal-202|Speaker 2|400|1200",
                        "speaker-internal-203|Speaker 3|1100|2100",
                    ])
                    pagePositionArms.insert("middle")
                case "row-detail-203":
                    #expect(page.sessionID == "session-detail-c")
                    #expect(page.revision.value == 203)
                    #expect(page.clauseState == .priorityPending)
                    #expect(page.clauseStateText == "発話文: 優先度判定を待っています")
                    #expect(page.previousCursor == "55555555-5555-4555-8555-555555555555")
                    #expect(page.nextCursor == "44444444-4444-4444-8444-444444444444")
                    #expect(spanSignatures == [
                        "speaker-internal-204|Speaker 4|2000|3000",
                        "speaker-internal-205|Speaker 5|3100|4150",
                        "speaker-internal-206|Speaker 6|4200|5200",
                    ])
                    pagePositionArms.insert("middle")
                case "row-detail-204":
                    #expect(page.sessionID == "session-detail-d")
                    #expect(page.revision.value == 204)
                    #expect(page.clauseState == .classified)
                    #expect(page.clauseStateText == "発話文: 判定済み")
                    #expect(page.previousCursor == "66666666-6666-4666-8666-666666666666")
                    #expect(page.nextCursor == nil)
                    #expect(spanSignatures == [
                        "speaker-internal-207|Speaker 7|5100|6200",
                        "speaker-internal-other|OTHER|6300|7000",
                        "speaker-internal-unknown|UNKNOWN|7100|7900",
                        "speaker-raw-208|speaker-raw-208|8000|8500",
                    ])
                    pagePositionArms.insert("last")
                case "row-detail-205":
                    #expect(page.sessionID == "session-detail-empty")
                    #expect(page.revision.value == 205)
                    #expect(page.clauseState == .classified)
                    #expect(page.clauseStateText == "発話文: 判定済み")
                    #expect(page.speakers.isEmpty)
                    #expect(page.nextCursor == nil)
                    #expect(page.previousCursor == nil)
                    pagePositionArms.insert("single")
                default:
                    #expect(Bool(false), "Unexpected row-details fixture row ID \(page.rowID)")
                }
            } else {
                let request = try EngineCodec.decodeRequest(record)
                guard case let .transcriptRowDetails(payload) = request.command else { continue }
                let payloadObject = try #require(metadata["payload"] as? [String: Any])
                fixturePayloadKeys.formUnion(payloadObject.keys)
                if let cursor = payload.cursor {
                    payloadCursorArms.insert("value")
                    #expect(cursor == "11111111-1111-4111-8111-111111111111")
                } else {
                    payloadCursorArms.insert("null")
                }

                switch request.requestID.value {
                case 101:
                    #expect(payload.sessionID == "session-detail-a")
                    #expect(payload.revision.value == 201)
                    #expect(payload.rowID == "row-detail-201")
                    #expect(payload.cursor == nil)
                    #expect(payload.limit == 2)
                case 102:
                    #expect(payload.sessionID == "session-detail-b")
                    #expect(payload.revision.value == 202)
                    #expect(payload.rowID == "row-detail-202")
                    #expect(payload.cursor == "11111111-1111-4111-8111-111111111111")
                    #expect(payload.limit == 2)
                default:
                    #expect(Bool(false), "Unexpected row-details fixture request ID \(request.requestID.rawValue)")
                }
            }
        }

        #expect(fixturePayloadKeys.isSuperset(of: payloadKeys))
        #expect(fixtureSpanKeys.isSuperset(of: spanKeys))
        #expect(fixturePageKeys.isSuperset(of: pageKeys))
        #expect(payloadCursorArms == ["null", "value"])
        #expect(clauseStates == encodedClauseStates)
        let standardSpeakerLabels = Set(EngineSpeakerLabel.allCases.map(\.rawValue))
        #expect(speakerDisplayLabels == standardSpeakerLabels.union(["speaker-raw-208"]))
        #expect(sawEmptySpeakers)
        #expect(sawNonemptySpeakers)
        #expect(sawRepeatedOverlappingSpeaker)
        #expect(pagePositionArms == ["first", "middle", "last", "single"])
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

private enum GoldenFixtureError: Error {
    case missingFinalLineFeed
    case expectedJSONObject
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
    if key == "recording", has(["revision", "screen", "setup", "recovery", "recording", "queue", "failures", "presentation"]) { return true }
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

private func pathName(_ path: [GoldenPathComponent]) -> String {
    "$" + path.map { component in
        switch component {
        case let .key(key): ".\(key)"
        case let .index(index): "[\(index)]"
        }
    }.joined()
}

private func encodedObjectKeys<Value: Encodable>(_ value: Value) throws -> Set<String> {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw GoldenFixtureError.expectedJSONObject
    }
    return Set(object.keys)
}

private func encodedStringValues<Value: Encodable>(_ values: [Value]) throws -> Set<String> {
    var result = Set<String>()
    for value in values {
        let data = try JSONEncoder().encode(value)
        let rawValue = try JSONDecoder().decode(String.self, from: data)
        result.insert(rawValue)
    }
    return result
}
