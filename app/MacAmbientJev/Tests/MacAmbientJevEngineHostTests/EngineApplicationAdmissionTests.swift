import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@testable import MacAmbientJevEngineHost

@MainActor
@Suite struct EngineApplicationAdmissionTests {
    private struct Fixture {
        let root: URL
        let app: EngineApplication
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
        let claimedIDs: Set<UUID>
    }

    private func fixture() throws -> Fixture {
        let root = try ApplicationHarness.makeRoot()
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let resources = FakeResourceMonitor()
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                resourceMonitor: resources, memoryProber: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)
            ),
            capture: FakeCapture(), inference: FakeInferenceProvider(), events: events
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: events)
        return Fixture(root: root, app: app, context: context)
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

    private func seedQueue(in fixture: Fixture) -> QueueSnapshot {
        let pendingID = UUID()
        let currentID = UUID()
        let heldID = UUID()
        var queue = SessionProcessingQueue()
        queue.enqueue(.finalize(sessionID: pendingID, metadataPolicy: .reject))
        queue.begin(.finalize(sessionID: currentID, metadataPolicy: .reject))
        queue.hold(.retryContentPriority(sessionID: heldID, boundarySegments: [], clauses: []), reason: .thermal)
        fixture.app.core.processingQueue = queue
        return QueueSnapshot(
            pendingIDs: queue.pending.map(\.sessionID), currentID: queue.currentSessionID,
            heldIDs: queue.held.map { $0.request.sessionID }, claimedIDs: queue.claimedSessionIDs
        )
    }

    private func queueSnapshot(in fixture: Fixture) -> QueueSnapshot {
        let queue = fixture.app.core.processingQueue
        return QueueSnapshot(
            pendingIDs: queue.pending.map(\.sessionID), currentID: queue.currentSessionID,
            heldIDs: queue.held.map { $0.request.sessionID }, claimedIDs: queue.claimedSessionIDs
        )
    }

    private func completionWaiterCount(in fixture: Fixture) -> Int? {
        guard let waiters = Mirror(reflecting: fixture.app.core.completions).children
            .first(where: { $0.label == "waiters" })?.value else { return nil }
        return Mirror(reflecting: waiters).children.count
    }

    @Test func fullQueueRejectsImportBeforeCreatingSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)

        for _ in 0..<EngineApplicationCore.queueLimit {
            fixture.app.core.processingQueue.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
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
        #expect(try fixture.app.core.currentSessions().isEmpty)
    }

    @Test func fifteenthQueuedRequestAllowsImportButSixteenthRejectsAnother() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)

        for _ in 0..<(EngineApplicationCore.queueLimit - 1) {
            fixture.app.core.processingQueue.enqueue(.finalize(sessionID: UUID(), metadataPolicy: .reject))
        }
        let input = fixture.root.appending(path: "retained-audio.wav")
        try Data("retained audio".utf8).write(to: input)
        let payload = try EngineImportPayload(inputPath: input.path)
        let imported = try await fixture.app.core.importSession(payload, context: fixture.context)

        #expect(fixture.app.core.processingQueue.pending.count == EngineApplicationCore.queueLimit)
        #expect(try fixture.app.core.currentSessions().count == 1)

        do {
            _ = try await fixture.app.core.importSession(payload, context: fixture.context)
            Issue.record("the seventeenth queued request should be busy")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        }

        #expect(fixture.app.core.processingQueue.pending.count == EngineApplicationCore.queueLimit)
        #expect(try fixture.app.core.currentSessions().count == 1)
        #expect(fixture.app.core.processingQueue.pending.last?.sessionID == UUID(uuidString: imported.sessionID))
    }

    @Test func sessionProcessingRequiresPreparedModelsBeforeInspectingSessions() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)

        let queueBefore = seedQueue(in: fixture)
        let sessionID = UUID()
        let payload = try EngineSessionPayload(sessionID: sessionID.uuidString.lowercased())
        #expect(completionWaiterCount(in: fixture) == 0)

        for operation in SessionOperation.allCases {
            do {
                _ = try await operation.call(in: fixture, payload: payload)
                Issue.record("\(operation) should require prepared models")
            } catch let error as EngineCommandError {
                #expect(error.code == .modelMissing)
                #expect(error.stage == operation.stage)
                #expect(error.recoveryAction == .prepareModels)
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

    @Test func sessionProcessingRemainsBusyDuringModelPreparation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)
        fixture.app.core.isPreparingModels = true
        defer { fixture.app.core.isPreparingModels = false }
        let payload = try EngineSessionPayload(sessionID: UUID().uuidString.lowercased())

        for operation in SessionOperation.allCases {
            do {
                _ = try await operation.call(in: fixture, payload: payload)
                Issue.record("\(operation) should remain busy during model preparation")
            } catch let error as EngineCommandError {
                #expect(error.code == .busy)
                #expect(error.stage == operation.stage)
                #expect(error.recoveryAction == .retry)
            } catch {
                Issue.record("unexpected \(operation) error: \(error)")
            }
        }
    }

    @Test func retryDecisionsIsBusyDuringRecordingEvenWhenDecisionsAreEnabled() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)
        try await acknowledgeResourceWarning(fixture.app, workload: .load, context: fixture.context)
        try await fixture.app.core.prepare(context: fixture.context)
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
    }

    @Test func retryDecisionsRejectsAlreadyQueuedSession() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await start(fixture)
        try await setDecisionsEnabled(fixture)
        try await acknowledgeResourceWarning(fixture.app, workload: .load, context: fixture.context)
        try await fixture.app.core.prepare(context: fixture.context)

        let sessionID = UUID()
        fixture.app.core.processingQueue.enqueue(
            .retryContentPriority(sessionID: sessionID, boundarySegments: [], clauses: [])
        )
        let payload = try EngineSessionPayload(sessionID: sessionID.uuidString.lowercased())

        do {
            _ = try await fixture.app.core.retryDecisions(payload, context: fixture.context)
            Issue.record("decision retry should not duplicate queued work")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        }

        #expect(fixture.app.core.processingQueue.pending.count == 1)
    }
}
