import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevEngineHost

private actor ImportGate {
    private var didEnter = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        didEnter = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private let microphone = "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationAutomaticPreparationTests {
    private func started(_ root: URL, holdingPrepare: Bool = false, failingPrepare: Bool = false) async throws -> ApplicationHarness {
        let harness = ApplicationHarness(root: root)
        if holdingPrepare { harness.inference.holdPrepare() }
        if failingPrepare {
            harness.inference.failPrepare(with: EngineAdapterError(
                code: .modelMissing, message: "モデルがありません", recoveryAction: .prepareModels, details: []
            ))
        }
        harness.start()
        try await harness.hello()
        try await harness.replaceSettings(engineTestSettings(), expectedRevision: nil)
        return harness
    }

    private func recordTwoSeconds(_ harness: ApplicationHarness) async throws -> String {
        guard case let .recordingStart(started) = try await harness.call("recording.start", payload: microphone) else {
            throw TestTimeout(description: "recording.start did not return a session")
        }
        try await #require(harness.capture.session).appendSpeech(seconds: 2)
        return started.sessionID
    }

    private func waitForProcessingIdle(_ harness: ApplicationHarness) async throws {
        try await harness.sink.changes.wait("processing queue drains") {
            let queue = harness.app.core.processingQueue
            return queue.summaries.isEmpty && queue.currentSessionID == nil
        }
    }

    private func waitForState(_ harness: ApplicationHarness, _ description: String, _ predicate: @escaping (EngineState) -> Bool) async throws {
        try await harness.sink.changes.wait(description) {
            ((try? harness.outputs) ?? []).contains { output in
                if case let .state(state) = output.event { predicate(state) } else { false }
            }
        }
    }

    @Test func recordingWorksWhileModelsPrepareAndFinalizationRunsOnceTheyAreReady() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root, holdingPrepare: true)

        let sessionID = try await recordTwoSeconds(h)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(sessionID)\"}")
        try await waitForState(h, "the finalization held for the models") {
            $0.queue.map(\.sessionID) == [sessionID]
                && $0.presentation.processingStatusText == ModelPreparationStatus.waitingForModelsText
        }
        #expect(try await h.sessions().first?.status != .finalized)

        h.inference.releasePrepare()
        let finalized = try await h.waitForSession(status: .finalized)
        #expect(finalized.sessionID == sessionID)
        #expect(try await h.state().queue.isEmpty)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(10)))
    func importReturningToIdleResumesModelHeldReprocessAfterPreparation() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let importGate = ImportGate()
        defer { Task { await importGate.release() } }
        let h = ApplicationHarness(root: root, importRetainedSession: { audioURL, importer in
            await importGate.pause()
            return try importer.importRetainedSession(audioURL: audioURL)
        })
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let sessionID = try await recordTwoSeconds(h)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(sessionID)\"}")
        _ = try await h.waitForSession(status: .finalized)
        try await waitForProcessingIdle(h)

        h.inference.holdPrepare()
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        try await h.replaceSettings(larger, expectedRevision: 1)
        try await h.sink.changes.wait("replacement-profile preparation starts") {
            h.inference.calls.count("prepare") == 2
        }

        let reprocess = Task {
            try await h.call("session.reprocess", payload: "{\"session_id\":\"\(sessionID)\"}")
        }
        let reprocessID = try #require(UUID(uuidString: sessionID))
        try await h.sink.changes.wait("reprocess waits for models") {
            h.app.core.processingQueue.summaries.contains { $0.sessionID == reprocessID && $0.holdReason == .models }
        }

        let audio = root.appending(path: "long-import.wav")
        try Data("fake wav".utf8).write(to: audio)
        let encodedPath = String(decoding: try JSONEncoder().encode(audio.path), as: UTF8.self)
        let importing = Task {
            try await h.call("session.import", payload: "{\"input_path\":\(encodedPath)}")
        }
        try await h.sink.changes.wait("import enters its active phase") {
            h.app.core.recording.phase == .importing
        }
        await importGate.waitUntilEntered()
        h.inference.releasePrepare()
        await h.awaitModels()
        #expect(h.app.core.recording.phase == .importing)
        #expect(h.app.core.processingQueue.summaries.contains {
            $0.sessionID == reprocessID && $0.holdReason == .models
        })
        await importGate.release()

        guard case .sessionImport = try await importing.value else {
            Issue.record("session.import did not return its session")
            return
        }
        guard case let .sessionReprocess(result) = try await reprocess.value else {
            Issue.record("model-held reprocess did not complete after import returned to idle")
            return
        }
        #expect(result.sessionID == sessionID)
        _ = try await h.waitForSession(status: .finalized)
        #expect(!h.app.core.processingQueue.summaries.contains { $0.holdReason == .models })
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func savedSettingsPrepareTheModelsAtStartupWithoutARequest() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await started(root)
        await first.awaitModels()
        #expect(try await first.shutdown() == .shutdownRequested)

        let second = ApplicationHarness(root: root)
        second.inference.holdPrepare()
        second.start()
        try await second.hello()
        second.inference.releasePrepare()
        await second.awaitModels()

        #expect(second.inference.calls.count("prepare") == 1)
        let progress = try second.outputs.compactMap { output -> (EngineProgressPayload, EngineID?)? in
            if case let .progress(payload) = output.event { (payload, output.requestID) } else { nil }
        }
        #expect(progress.contains { $0.0.stage == .validatingModels })
        #expect(progress.allSatisfy { $0.1 == nil })
        #expect(second.app.core.modelsPrepared)
        #expect(try await second.shutdown() == .shutdownRequested)
    }

    @Test func anAutomaticFailureStopsAutomaticAttemptsUntilTheUserPreparesAgain() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root, failingPrepare: true)
        await h.awaitModels()
        #expect(try await h.state().presentation.preparationPhase == .failed)

        let sessionID = try await recordTwoSeconds(h)
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(sessionID)\"}")
        #expect(try await h.state().queue.map(\.sessionID) == [sessionID])
        #expect(h.inference.calls.count("prepare") == 1)

        h.inference.failPrepare(with: nil)
        try await h.call("models.prepare")
        #expect(h.inference.calls.count("prepare") == 2)
        _ = try await h.waitForSession(status: .finalized)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func failedPreparationResolvesReprocessWaiterAndExplicitRetryResumesHeldWork() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root)
        await h.awaitModels()
        let audio = root.appending(path: "model-reprocess.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(audio.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        try await waitForProcessingIdle(h)

        let failure = EngineAdapterError(
            code: .modelMissing, message: "再処理用モデルを準備できません", recoveryAction: .prepareModels, details: []
        )
        h.inference.holdPrepare()
        h.inference.failPrepare(with: failure)
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        try await h.replaceSettings(larger, expectedRevision: 1)
        try await h.sink.changes.wait("model profile preparation started") {
            h.inference.calls.count("prepare") == 2
        }

        let reprocess = Task {
            try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
        }
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        try await h.sink.changes.wait("reprocess enters model hold") {
            h.app.core.processingQueue.summaries.contains { $0.sessionID == sessionID && $0.holdReason == .models }
        }
        #expect(h.app.core.processingQueue.summaries.contains { $0.sessionID == sessionID && $0.holdReason == .models })

        h.inference.releasePrepare()
        await h.awaitModels()
        do {
            _ = try await reprocess.value
            Issue.record("failed preparation must finish the waiting reprocess RPC")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .modelMissing)
            #expect(error.failure.message == failure.message)
            #expect(error.failure.recoveryAction == .prepareModels)
        }
        #expect(h.app.core.processingQueue.summaries.contains { $0.sessionID == sessionID && $0.holdReason == .models })
        #expect(h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        do {
            _ = try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
            Issue.record("new reprocess must be refused until model preparation succeeds")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .busy)
            #expect(error.failure.message == "このセッションは処理待ち・保留中または実行中のため再処理できません")
        }

        h.inference.failPrepare(with: nil)
        try await h.call("models.prepare")
        _ = try await h.waitForSession(status: .finalized)
        try await waitForProcessingIdle(h)
        #expect(!h.app.core.processingQueue.summaries.contains { $0.holdReason == .models })
        #expect(!h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        #expect(h.inference.calls.count("prepare") == 3)
        _ = try await h.shutdown()
    }

    @Test func cancelledPreparationResolvesReprocessWaiterAndKeepsHeldClaim() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root)
        await h.awaitModels()
        let audio = root.appending(path: "cancelled-model-reprocess.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(audio.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        try await waitForProcessingIdle(h)

        h.inference.holdPrepare()
        h.inference.cancelNextPreparation()
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        try await h.replaceSettings(larger, expectedRevision: 1)
        try await h.sink.changes.wait("cancelled model profile preparation started") {
            h.inference.calls.count("prepare") == 2
        }

        let reprocess = Task {
            try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
        }
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        try await h.sink.changes.wait("reprocess enters model hold before cancellation") {
            h.app.core.processingQueue.summaries.contains { $0.sessionID == sessionID && $0.holdReason == .models }
        }

        h.inference.releasePrepare()
        await h.awaitModels()
        do {
            _ = try await reprocess.value
            Issue.record("cancelled preparation must finish the waiting reprocess RPC")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .cancelled)
            #expect(error.failure.message == "モデルの準備が中止されました")
        }
        #expect(h.app.core.processingQueue.summaries.contains { $0.sessionID == sessionID && $0.holdReason == .models })
        #expect(h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))

        h.inference.releasePrepare()
        try await h.call("models.prepare")
        _ = try await h.waitForSession(status: .finalized)
        try await waitForProcessingIdle(h)
        #expect(!h.app.core.processingQueue.summaries.contains { $0.holdReason == .models })
        #expect(!h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        #expect(h.inference.calls.count("prepare") == 3)
        _ = try await h.shutdown()
    }

    @Test func changingTheModelProfilePreparesTheNewSizeByItself() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root)
        await h.awaitModels()
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        try await h.replaceSettings(larger, expectedRevision: 1)
        await h.awaitModels()

        #expect(h.inference.preparedSettings.get().map(\.asrSize) == [.small, .large])
        #expect(h.app.core.modelsPrepared)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func recordingStartsWhileAnImportWaitsForModelsAndTheImportFinalizesBeforeTheRecording() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try await started(root, holdingPrepare: true)
        let audio = root.appending(path: "input.wav")
        try Data("RIFF-not-decoded-by-the-fake-timeline".utf8).write(to: audio)
        let encodedPath = String(decoding: try JSONEncoder().encode(audio.path), as: UTF8.self)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(encodedPath)}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        try await waitForState(h, "the import held for the models") {
            $0.queue.map(\.sessionID) == [imported.sessionID]
                && $0.presentation.processingStatusText == ModelPreparationStatus.waitingForModelsText
        }

        let recordingID = try await recordTwoSeconds(h)

        // Preparing the models during the recording does not start the held import.
        h.inference.releasePrepare()
        await h.awaitModels()
        #expect(h.app.core.modelsPrepared)
        #expect(h.app.core.processingQueue.summaries.filter { $0.holdReason == .models }
            .map { $0.sessionID.uuidString.lowercased() } == [imported.sessionID])
        #expect(!h.app.core.processingCoordinator.isDraining)

        try await h.call("recording.stop", payload: "{\"session_id\":\"\(recordingID)\"}")
        try await h.sink.changes.wait("both sessions finalized") {
            let states = ((try? h.outputs) ?? []).compactMap { output -> EngineState? in
                if case let .state(state) = output.event { state } else { nil }
            }
            return states.last.map { $0.queue.isEmpty } == true && h.inference.calls.count("asr") > 0
        }
        let sessions = try await h.sessions()
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.status == .finalized })

        // The import leaves the queue no later than the recording's finalization does.
        let queues = try h.outputs.compactMap { output -> [String]? in
            if case let .state(state) = output.event { state.queue.map(\.sessionID) } else { nil }
        }
        let importQueued = try #require(queues.firstIndex { $0.contains(imported.sessionID) })
        let recordingQueued = try #require(queues.firstIndex { $0.contains(recordingID) })
        let importDone = try #require(queues[importQueued...].firstIndex { !$0.contains(imported.sessionID) })
        let recordingDone = try #require(queues[recordingQueued...].firstIndex { !$0.contains(recordingID) })
        #expect(importDone <= recordingDone)
        #expect(try await h.shutdown() == .shutdownRequested)
    }
}
