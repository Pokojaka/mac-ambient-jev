import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline

@testable import MacAmbientJevEngineHost

@MainActor
@Suite struct EngineApplicationAdmissionTests {
    private struct Fixture {
        let root: URL
        let app: EngineApplication
        let inference: FakeInferenceProvider
        let resources: FakeResourceMonitor
        let context: EngineRequestContext
    }

    private enum SessionOperation: CaseIterable {
        case reprocess
        case retryDecisions

        var stage: EngineStage {
            switch self {
            case .reprocess: return .finalization
            case .retryDecisions: return .decisions
            }
        }

        func call(in fixture: Fixture, payload: EngineSessionPayload) async throws -> EngineSessionPayload {
            switch self {
            case .reprocess:
                return try await fixture.app.core.reprocess(payload, context: fixture.context)
            case .retryDecisions:
                return try await fixture.app.core.retryDecisions(payload, context: fixture.context)
            }
        }
    }

    private struct QueueSnapshot: Equatable {
        let pendingIDs: [UUID]
        let currentID: UUID?
        let heldIDs: [UUID]
        let modelHeldIDs: [UUID]
        let claimedIDs: Set<UUID>
    }

    private func fixture() throws -> Fixture {
        let root = try ApplicationHarness.makeRoot()
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let inference = FakeInferenceProvider()
        let resources = FakeResourceMonitor()
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4, resourceMonitor: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20), timeZone: TimeZone(identifier: "Asia/Tokyo")!),
            capture: FakeCapture(), inference: inference, events: events
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: events, terminalReplyClaim: {})
        return Fixture(root: root, app: app, inference: inference, resources: resources, context: context)
    }

    private func start(_ fixture: Fixture) async {
        fixture.app.start()
        await fixture.app.waitForStartupRecovery()
    }

    private func setDecisionsEnabled(_ fixture: Fixture) async throws {
        let settings = try engineTestSettings(decisions: true)
        _ = try await fixture.app.core.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings), context: fixture.context
        )
    }

    private func seedQueue(in fixture: Fixture) async throws -> QueueSnapshot {
        let pendingIDs = [UUID(), UUID(), UUID()]
        for sessionID in pendingIDs {
            fixture.app.core.processingCoordinator.enqueue(.finalize(sessionID: sessionID, metadataPolicy: .reject))
        }
        await fixture.app.core.processingCoordinator.waitUntilIdle()
        return queueSnapshot(in: fixture)
    }

    private func queueSnapshot(in fixture: Fixture) -> QueueSnapshot {
        let queue = fixture.app.core.processingQueue
        return QueueSnapshot(
            pendingIDs: queue.pending.map(\.sessionID), currentID: queue.currentSessionID,
            heldIDs: queue.held.map(\.sessionID), modelHeldIDs: queue.modelHeld.map(\.sessionID),
            claimedIDs: queue.claimedSessionIDs
        )
    }

    private func completionWaiterCount(in fixture: Fixture) -> Int? {
        guard let requests = Mirror(reflecting: fixture.app.core.completions).children
            .first(where: { $0.label == "requests" })?.value else { return nil }
        return Mirror(reflecting: requests).children.count
    }

    @Test func reprocessRechecksRecordingPhaseAfterCatalogWait() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()

        let audio = root.appending(path: "admission-recheck.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import",
            payload: String(decoding: try JSONEncoder().encode(EngineImportPayload(inputPath: audio.path)), as: UTF8.self)
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        let sessionUUID = try #require(UUID(uuidString: imported.sessionID))
        let gate = h.sessionCatalogLookupGate
        h.app.core.savedSessionsAreStale = true
        await gate.arm()
        let context = EngineRequestContext(
            requestID: try EngineID(900), events: EngineEventEmitter(transport: h.transport), terminalReplyClaim: {}
        )
        let reprocess = Task { @MainActor in
            try await h.app.core.reprocess(EngineSessionPayload(sessionID: imported.sessionID), context: context)
        }
        await gate.waitUntilSuspended()
        guard case let .recordingStart(recording) = try await h.call(
            "recording.start", payload: "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}"
        ) else {
            Issue.record("recording.start did not return a session")
            await gate.release()
            return
        }
        await gate.release()
        do {
            _ = try await reprocess.value
            Issue.record("reprocess must refuse while recording began during catalog lookup")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        } catch {
            Issue.record("expected busy, got \(error)")
        }
        #expect(!h.app.core.processingQueue.containsProcessing(sessionUUID))
        try await h.call("recording.stop", payload: "{\"session_id\":\"\(recording.sessionID)\"}")
        _ = try await h.waitForSession(status: .finalized)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(10)))
    func reprocessRechecksAdmissionBeforePreparationFailureAfterCatalogWait() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()

        let audio = root.appending(path: "catalog-recheck.wav")
        try Data("fake wav".utf8).write(to: audio)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import",
            payload: String(decoding: try JSONEncoder().encode(EngineImportPayload(inputPath: audio.path)), as: UTF8.self)
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()

        let preparationFailure = EngineAdapterError(
            code: .modelMissing, message: "再処理用モデルを準備できません", recoveryAction: .prepareModels, details: []
        )
        h.inference.holdPrepare()
        h.inference.failPrepare(with: preparationFailure)
        defer { h.inference.releasePrepare() }
        let larger = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        try await h.replaceSettings(larger, expectedRevision: 1)
        try await h.sink.changes.wait("model profile preparation starts") {
            h.inference.calls.count("prepare") == 2
        }

        let gate = h.sessionCatalogLookupGate
        defer { Task { await gate.release() } }
        h.app.core.savedSessionsAreStale = true
        await gate.arm()
        let payload = "{\"session_id\":\"\(imported.sessionID)\"}"
        let first = Task { try await h.call("session.reprocess", payload: payload) }
        await gate.waitUntilSuspended()

        let second = Task { try await h.call("session.reprocess", payload: payload) }
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        try await h.sink.changes.wait("second reprocess enters model hold") {
            h.app.core.processingQueue.summaries.contains {
                $0.sessionID == sessionID && $0.holdReason == .models
            }
        }

        h.inference.releasePrepare()
        await h.awaitModels()
        do {
            _ = try await second.value
            Issue.record("second reprocess must fail when model preparation fails")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .modelMissing)
            #expect(error.failure.message == preparationFailure.message)
        } catch {
            Issue.record("expected model preparation failure, got \(error)")
        }

        await gate.release()
        do {
            _ = try await first.value
            Issue.record("first reprocess must fail busy after the session becomes occupied")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .busy)
        } catch {
            Issue.record("expected busy, got \(error)")
        }
        #expect(h.app.core.processingQueue.containsProcessing(sessionID))
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test func fullQueueRejectsImportBeforeCreatingSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)

        for _ in 0..<EngineApplicationCore.queueLimit {
            fixture.app.core.processingCoordinator.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
        }
        let input = fixture.root.appending(path: "invalid-audio.wav")
        try Data("not audio".utf8).write(to: input)
        let payload = try EngineImportPayload(inputPath: input.path)

        do {
            _ = try await fixture.app.core.importSession(payload, context: fixture.context)
            Issue.record("import should be busy when all processing slots are occupied")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
            #expect(error.stage == .importing)
        }

        #expect(fixture.app.core.processingQueue.pending.count == EngineApplicationCore.queueLimit)
        #expect(try await fixture.app.core.currentSessions().isEmpty)
    }

    @Test func fifteenthQueuedRequestAllowsImportButSixteenthRejectsAnother() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)

        for _ in 0..<(EngineApplicationCore.queueLimit - 1) {
            fixture.app.core.processingCoordinator.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
        }
        let input = fixture.root.appending(path: "retained-audio.wav")
        try Data("retained audio".utf8).write(to: input)
        let payload = try EngineImportPayload(inputPath: input.path)
        let imported = try await fixture.app.core.importSession(payload, context: fixture.context)

        #expect(fixture.app.core.processingQueue.pending.count == EngineApplicationCore.queueLimit)
        #expect(try await fixture.app.core.currentSessions().count == 1)

        do {
            _ = try await fixture.app.core.importSession(payload, context: fixture.context)
            Issue.record("the seventeenth queued request should be busy")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        }

        #expect(fixture.app.core.processingQueue.pending.count == EngineApplicationCore.queueLimit)
        #expect(try await fixture.app.core.currentSessions().count == 1)
        #expect(fixture.app.core.processingQueue.pending.last?.sessionID == UUID(uuidString: imported.sessionID))
    }

    @Test func sessionProcessingInspectsSessionsWithoutPreparedModels() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        fixture.inference.failPrepare(with: EngineAdapterError(
            code: .modelMissing, message: "モデルがありません", recoveryAction: .prepareModels, details: []
        ))
        try await setDecisionsEnabled(fixture)
        await fixture.app.core.awaitModelPreparation()
        #expect(!fixture.app.core.modelsPrepared)

        let queueBefore = try await seedQueue(in: fixture)
        let sessionID = UUID()
        let payload = try EngineSessionPayload(sessionID: sessionID.uuidString.lowercased())
        #expect(completionWaiterCount(in: fixture) == 0)

        for operation in SessionOperation.allCases {
            do {
                _ = try await operation.call(in: fixture, payload: payload)
                Issue.record("\(operation) should inspect the unknown session")
            } catch let error as EngineCommandError {
                #expect(error.code == .sessionNotFound)
            } catch {
                Issue.record("unexpected \(operation) error: \(error)")
            }

            #expect(!fixture.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
            #expect(queueSnapshot(in: fixture) == queueBefore)
            #expect(completionWaiterCount(in: fixture) == 0)
        }
    }

    @Test func sessionProcessingRequiresSettingsBeforeCheckingModels() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        let payload = try EngineSessionPayload(sessionID: UUID().uuidString.lowercased())

        for operation in SessionOperation.allCases {
            do {
                _ = try await operation.call(in: fixture, payload: payload)
                Issue.record("\(operation) should require settings")
            } catch let error as EngineCommandError {
                #expect(error.code == .settingsRequired)
                #expect(error.stage == operation.stage)
                #expect(error.recoveryAction == .replaceSettings)
            } catch {
                Issue.record("unexpected \(operation) error: \(error)")
            }
            #expect(completionWaiterCount(in: fixture) == 0)
        }
    }

    @Test func sessionProcessingInspectsSessionsDuringModelPreparation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        fixture.inference.holdPrepare()
        defer { fixture.inference.releasePrepare() }
        try await setDecisionsEnabled(fixture)
        #expect(fixture.app.core.isPreparingModels)
        let payload = try EngineSessionPayload(sessionID: UUID().uuidString.lowercased())

        for operation in SessionOperation.allCases {
            do {
                _ = try await operation.call(in: fixture, payload: payload)
                Issue.record("\(operation) should inspect the unknown session")
            } catch let error as EngineCommandError {
                #expect(error.code == .sessionNotFound)
            } catch {
                Issue.record("unexpected \(operation) error: \(error)")
            }
        }
    }

    @Test func reprocessAndDecisionRetryAreBusyForTheRecordingSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)
        await fixture.app.core.awaitModelPreparation()
        #expect(fixture.app.core.settings?.decisionsEnabled == true)

        let sessionID = UUID()
        fixture.app.core.recording.start(sessionID: sessionID)
        fixture.app.core.recording.didStart(sessionID: sessionID)
        let payload = try EngineSessionPayload(sessionID: sessionID.uuidString.lowercased())

        do {
            _ = try await fixture.app.core.retryDecisions(payload, context: fixture.context)
            Issue.record("decision retry should be busy during live recording")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
            #expect(error.stage == .decisions)
        }
        do {
            _ = try await fixture.app.core.reprocess(payload, context: fixture.context)
            Issue.record("reprocess should be busy for the recording session's own ID")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
            #expect(error.stage == .finalization)
        }
        #expect(fixture.app.core.processingQueue.pending.isEmpty)
    }

    @Test func reprocessReturnsBusyWithoutChangingExistingQueuedWork() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)
        await fixture.app.core.awaitModelPreparation()
        let input = fixture.root.appending(path: "busy-target.wav")
        try Data("fake wav".utf8).write(to: input)
        let imported = try await fixture.app.core.importSession(
            try EngineImportPayload(inputPath: input.path), context: fixture.context
        )
        await fixture.app.core.processingCoordinator.waitUntilIdle()
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        let existing = PendingProcessing.finalize(sessionID: sessionID, metadataPolicy: .reject)
        fixture.resources.setSignal(.pressure)
        fixture.app.core.processingCoordinator.enqueue(existing)
        await fixture.app.core.processingCoordinator.waitUntilIdle()
        #expect(fixture.app.core.processingQueue.held.contains {
            $0.sessionID == sessionID && $0.holdReason == .inference(.resourcePressure)
        })
        let payload = try EngineSessionPayload(sessionID: imported.sessionID)

        do {
            _ = try await fixture.app.core.reprocess(payload, context: fixture.context)
            Issue.record("reprocess should reject its already queued session")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
            #expect(error.stage == .finalization)
        }

        #expect(fixture.app.core.processingQueue.summaries.contains { $0.requestID == existing.requestID })
        #expect(fixture.app.core.processingQueue.claimedSessionIDs.isEmpty)
        #expect(fixture.app.core.processingQueue.containsProcessing(sessionID))
    }

    @Test func retryDecisionsRejectsAlreadyQueuedSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        fixture.inference.failPrepare(with: EngineAdapterError(
            code: .modelMissing, message: "モデルがありません", recoveryAction: .prepareModels, details: []
        ))
        try await setDecisionsEnabled(fixture)
        await fixture.app.core.awaitModelPreparation()

        let sessionID = UUID()
        let existing = PendingProcessing.finalize(sessionID: sessionID, metadataPolicy: .reject)
        fixture.app.core.processingCoordinator.enqueue(existing)
        await fixture.app.core.processingCoordinator.waitUntilIdle()
        #expect(fixture.app.core.processingQueue.modelHeld.contains {
            $0.sessionID == sessionID && $0.requestID == existing.requestID
        })
        let payload = try EngineSessionPayload(sessionID: sessionID.uuidString.lowercased())

        do {
            _ = try await fixture.app.core.retryDecisions(payload, context: fixture.context)
            Issue.record("decision retry should not duplicate queued work")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        }

        #expect(fixture.app.core.processingQueue.modelHeld.map(\.requestID) == [existing.requestID])
    }
}
