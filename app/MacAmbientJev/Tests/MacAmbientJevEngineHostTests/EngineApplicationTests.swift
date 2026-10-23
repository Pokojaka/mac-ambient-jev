import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@MainActor
@Suite struct EngineApplicationTests {
    private func prepared(_ root: URL) async throws -> ApplicationHarness {
        let harness = ApplicationHarness(root: root)
        harness.start()
        try await harness.hello()
        try await harness.replaceSettings(engineTestSettings(), expectedRevision: nil)
        try await harness.call("models.prepare")
        return harness
    }

    @Test func recordStopFinalizeAndExportThroughTheComposedController() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()

        // Nothing works before settings and models exist, and the refusals say what to do.
        #expect(try await h.failureCode(of: "settings.get") == .settingsRequired)
        #expect(try await h.failureCode(of: "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}") == .settingsRequired)
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        #expect(try await h.state().setup == .modelsRequired)
        #expect(try await h.failureCode(of: "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}") == .modelMissing)

        try await h.call("models.prepare")
        #expect(try await h.state().setup == .ready)
        let progress = try h.outputs.compactMap { output -> EngineProgressPayload? in
            if case let .progress(payload) = output.event { payload } else { nil }
        }
        #expect(progress.contains { $0.stage == .validatingModels })
        #expect(progress.contains { $0.stage == .loadingModels })

        guard case let .devicesList(devices) = try await h.call("devices.list", payload: "{\"source\":\"microphone\"}") else {
            Issue.record("devices.list did not return devices")
            return
        }
        #expect(devices.defaultDeviceID == "fake-endpoint")

        // Record two seconds, watching the session as the live screen does.
        guard case let .recordingStart(started) = try await h.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            return
        }
        let recordingState = try await h.state()
        #expect(recordingState.screen == .live)
        #expect(recordingState.recording?.sessionID == started.sessionID)
        #expect(recordingState.recording?.phase == .recording)
        #expect(try await h.failureCode(of: "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}") == .busy)
        try await h.call("transcript.watch", payload: "{\"session_id\":\"\(started.sessionID)\"}")
        let capture = try #require(h.capture.session)
        try await capture.appendSpeech(seconds: 2)
        let capturedCheckpoint = try await capture.committedCheckpoint()
        #expect(capturedCheckpoint.committedFrames == 32_000)
        #expect(capturedCheckpoint.sampleRate == 16_000)
        #expect(capturedCheckpoint.channelCount == 1)
        #expect(try await h.failureCode(of: "recording.stop", payload: "{\"session_id\":\"\(UUID().uuidString.lowercased())\"}") == .sessionNotFound)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(started.sessionID)\"}")
        #expect(h.capture.session?.isStopped == true)

        let finalized = try await h.waitForSession(status: .finalized)
        #expect(finalized.sessionID == started.sessionID)
        let finalState = try await h.state()
        #expect(finalState.recording == nil)
        #expect(finalState.queue.isEmpty)
        #expect(finalState.failures.isEmpty)

        guard case let .transcriptRead(page) = try await h.call(
            "transcript.read",
            payload: "{\"session_id\":\"\(started.sessionID)\",\"revision\":null,\"cursor\":null,\"limit\":50}"
        ) else {
            Issue.record("transcript.read did not return a page")
            return
        }
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.text == "日本語のテストです。")
        #expect(page.rows.first?.headings == [.speaker1])
        #expect(page.nextCursor == nil)
        #expect(try await h.failureCode(
            of: "transcript.read",
            payload: "{\"session_id\":\"\(started.sessionID)\",\"revision\":\"999999\",\"cursor\":null,\"limit\":50}"
        ) == .staleRevision)

        // Rows streamed while the watched session finalized.
        let rowEvents = try h.outputs.compactMap { output -> EngineRowsPayload? in
            if case let .rows(payload) = output.event { payload } else { nil }
        }
        #expect(rowEvents.contains { $0.rows.contains { $0.text == "日本語のテストです。" } })

        let exportDirectory = root.appending(path: "export", directoryHint: .isDirectory)
        guard case let .sessionExport(exported) = try await h.call(
            "session.export",
            payload: "{\"session_id\":\"\(started.sessionID)\",\"destination_path\":\(jsonString(exportDirectory.path))}"
        ) else {
            Issue.record("session.export did not return a result")
            return
        }
        let bundle = URL(fileURLWithPath: exported.destinationPath, isDirectory: true)
        #expect(bundle.deletingLastPathComponent().standardizedFileURL.path == exportDirectory.standardizedFileURL.path)
        let text = try String(contentsOf: bundle.appending(path: "transcript.txt"), encoding: .utf8)
        #expect(text == "[00:00] Speaker 1: 日本語のテストです。\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.path).sorted() == ["audio.flac", "transcript.txt"])

        let sourceLayout = SessionLayout(
            sessionURL: h.paths.sessionsRoot.appending(path: finalized.folderID, directoryHint: .isDirectory)
        )
        #expect(try sourceLayout.loadManifest().source == .recording(.microphone))
        guard case let .recordingFLAC(sourceInfo) = try SessionAudioStorageStore(layout: sourceLayout).load() else {
            Issue.record("recorded FLAC source was not retained")
            return
        }
        #expect(sourceInfo.committedFrames == capturedCheckpoint.committedFrames)
        #expect(sourceInfo.committedFrames == 32_000)
        let retainedSource = sourceLayout.recordingFLACURL
        #expect(FileManager.default.fileExists(atPath: retainedSource.path))

        let exportedAudio = bundle.appending(path: "audio.flac")
        let reader = try FLACTimelineReader(url: exportedAudio, info: sourceInfo, sessionURL: bundle)
        #expect(reader.info.committedFrames == capturedCheckpoint.committedFrames)
        try reader.validateAudio()
        #expect(try Data(contentsOf: exportedAudio) == Data(contentsOf: retainedSource))

        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func aDeviceFailureAtStartIsReportedAndLeavesNoSession() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        h.capture.startError = EngineAdapterError(
            code: .deviceNotFound, message: "録音デバイスが見つかりません", recoveryAction: .selectDevice, details: []
        )
        let code = try await h.failureCode(of: "recording.start", payload: "{\"source\":\"system_audio\",\"device\":{\"kind\":\"id\",\"id\":\"gone\"}}")
        #expect(code == .captureFailure || code == .deviceNotFound)
        #expect(try await h.state().recording == nil)
        #expect(try await h.sessions().isEmpty)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func aModelPreparationFailureKeepsSetupBlockedAndNamesTheRecovery() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        h.inference.failPrepare(with: EngineAdapterError(
            code: .modelMissing, message: "モデルがありません: D:\\models", recoveryAction: .prepareModels, details: []
        ))
        do {
            try await h.call("models.prepare")
            Issue.record("prepare should fail")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .modelMissing)
            #expect(error.failure.recoveryAction == .prepareModels)
            #expect(error.failure.message.contains("D:\\models"))
        }
        #expect(try await h.state().setup == .modelsRequired)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func settingsChangesThatInvalidateModelsAreRefusedWhileBusyAndResetPreparedState() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        try await h.call("recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}")
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        let payload = String(decoding: try JSONEncoder().encode(EngineSettingsReplacePayload(expectedRevision: try EngineID(1), settings: larger)), as: UTF8.self)
        #expect(try await h.failureCode(of: "settings.replace", payload: payload) == .busy)
        // A change that does not touch the model profile applies while recording.
        let exporting = try engineTestSettings(automaticExport: true, exportPath: root.path)
        try await h.replaceSettings(exporting, expectedRevision: 1)
        #expect(try await h.state().setup == .ready)
        let session = try #require(try await h.state().recording)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(session.sessionID)\"}")
        _ = try await h.waitForSession(status: .finalized)

        try await h.replaceSettings(larger, expectedRevision: 2)
        #expect(try await h.state().setup == .modelsRequired)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func shutdownStopsTheRecordingDurablyAndTheNextLaunchRecoversIt() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await prepared(root)
        try await first.call("recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}")
        try await first.capture.session?.appendSpeech(seconds: 2)
        #expect(try await first.shutdown() == .shutdownRequested)
        #expect(first.capture.session?.isStopped == true)

        let second = ApplicationHarness(root: root)
        second.start()
        try await second.hello()
        await second.app.waitForStartupRecovery()
        // Settings persisted, models are not prepared yet: the interrupted session waits.
        #expect(try await second.state().setup == .modelsRequired)
        #expect(try await second.waitForSession(status: .queued).sessionID != nil)
        #expect(try await second.state().recovery == .pending)
        try await second.call("models.prepare")
        _ = try await second.waitForSession(status: .finalized)
        let state = try await second.state()
        #expect(state.recovery == .completed)
        #expect(state.queue.isEmpty)
        #expect(try await second.shutdown() == .shutdownRequested)
    }

    @Test func captureFailureStopsTheControllerAndTheNextLaunchRecoversDurableAudio() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await prepared(root)
        guard case let .recordingStart(started) = try await first.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            return
        }
        try await first.capture.session?.appendSpeech(seconds: 2)

        let message = "test capture fault"
        let onFailure = try #require(first.capture.callbacks?.onFailure)
        onFailure(message)

        let exit = await first.exit()
        #expect(exit == .captureFailed(message))
        #expect(exit.processExitCode == 7)
        #expect(first.capture.session?.isStopped == true)
        let failure = try #require(try first.outputs.compactMap { output -> EngineFailure? in
            guard case let .error(failure) = output.event, failure.message == message else { return nil }
            return failure
        }.first)
        #expect(failure.code == .captureFailure)
        #expect(failure.message == message)
        #expect(failure.sessionID == started.sessionID)
        #expect(failure.severity == .fatal)

        let second = ApplicationHarness(root: root)
        second.start()
        try await second.hello()
        await second.app.waitForStartupRecovery()
        #expect(try await second.state().setup == .modelsRequired)
        #expect(try await second.waitForSession(status: .queued).sessionID == started.sessionID)
        try await second.call("models.prepare")
        let recovered = try await second.waitForSession(status: .finalized)
        #expect(recovered.sessionID == started.sessionID)
        guard case let .transcriptRead(page) = try await second.call(
            "transcript.read",
            payload: "{\"session_id\":\"\(started.sessionID)\",\"revision\":null,\"cursor\":null,\"limit\":10}"
        ) else {
            Issue.record("transcript.read did not return a page")
            return
        }
        #expect(page.rows.map(\.text) == ["日本語のテストです。"])
        #expect(try await second.state().recovery == .completed)
        #expect(try await second.shutdown() == .shutdownRequested)
    }

    @Test func aForcedKillMidRecordingIsRecoveredAtStartup() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = engineTestPaths(root: root)
        try EngineSettingsStore(paths: paths, logicalCPUCount: 4).replace(expectedRevision: nil, settings: engineTestSettings())

        // The state a killed engine leaves: a recording session with committed audio and no stop.
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.microphone), createdAt: Date(), timeZone: .current
        )
        let writer = try DurableAudioWriter(
            directory: SessionLayout(sessionURL: sessionURL).processingDirectory, chunkDurationSeconds: 0.5, sessionURL: sessionURL
        )
        try await writer.append(samples: FakeCaptureSession.tone(seconds: 3))

        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        await h.app.waitForStartupRecovery()
        try await h.call("models.prepare")
        let recovered = try await h.waitForSession(status: .finalized)
        #expect(recovered.sessionID == EngineFailures_wireID(sessionID))
        guard case let .transcriptRead(page) = try await h.call(
            "transcript.read",
            payload: "{\"session_id\":\"\(EngineFailures_wireID(sessionID))\",\"revision\":null,\"cursor\":null,\"limit\":10}"
        ) else {
            Issue.record("transcript.read did not return a page")
            return
        }
        #expect(page.rows.map(\.text) == ["日本語のテストです。"])
        #expect(try await h.state().recovery == .completed)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func startupRecoveryHasStartedBeforeTheClientSaysHello() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        // start() began recovery before hello, so the first state a client sees is never "pending".
        try await h.hello()
        #expect(try await h.state().recovery != .pending)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func importQueuesAFinalizationAndReprocessWaitsForIt() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let audio = root.appending(path: "input.wav")
        try Data("RIFF-not-decoded-by-the-fake-timeline".utf8).write(to: audio)
        #expect(try await h.failureCode(of: "session.import", payload: "{\"input_path\":\"relative.wav\"}") == .filesystem)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(jsonString(audio.path))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        let finalized = try await h.waitForSession(status: .finalized)
        #expect(finalized.sessionID == imported.sessionID)

        // Reprocess completes only after its finalization ran.
        let before = h.inference.calls.count("asr")
        try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
        #expect(h.inference.calls.count("asr") > before)
        #expect(try await h.sessions().first?.status == .finalized)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func listPagesWithCursorsAndReportsUnreadableFolders() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await prepared(root)
        let sessionsRoot = engineTestPaths(root: root).sessionsRoot
        try FileManager.default.createDirectory(at: sessionsRoot.appending(path: "not-a-session", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let first = try await h.call("session.list", payload: "{\"cursor\":null,\"limit\":1}")
        guard case let .sessionList(list) = first else {
            Issue.record("not a list")
            return
        }
        #expect(list.sessions.count == 1)
        #expect(list.sessions[0].status == .unreadable)
        #expect(list.sessions[0].sessionID == nil)
        #expect(list.sessions[0].folderID == "not-a-session")
        #expect(list.nextCursor == nil)
        #expect(try await h.failureCode(of: "session.list", payload: "{\"cursor\":\"x\",\"limit\":1}") == .invalidCursor)
        #expect(try await h.shutdown() == .shutdownRequested)
    }
}

private func jsonString(_ value: String) -> String {
    String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
}

private func EngineFailures_wireID(_ id: UUID) -> String {
    id.uuidString.lowercased()
}
