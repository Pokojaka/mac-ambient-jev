import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

@testable import MacAmbientJevEngineHost

extension EngineApplicationCore {
    /// Returns once no failure worker runs. A worker clears `failureEventTask` as its last step.
    func failureWorkerFinished() async {
        while let task = failureEventTask { await task.value }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationFailureDeliveryTests {
    private struct Fixture {
        let root: URL
        let source: ScriptedSource
        let sink: ScriptedSink
        let transport: EngineTransport
        let app: EngineApplication
    }

    private func fixture() throws -> Fixture {
        let root = try ApplicationHarness.makeRoot()
        let source = ScriptedSource()
        let sink = ScriptedSink(blocked: true)
        let limits = EngineTransportLimits(
            maxQueuedRecords: 4, maxQueuedBytes: 16_384,
            reservedControlRecords: 1, reservedControlBytes: 1_024,
            maxPendingInputLines: 4, readChunkBytes: 4_096,
            writeDeadlineNanoseconds: 5_000_000_000
        )
        let transport = EngineTransport(source: source, sink: sink, limits: limits)
        // The unstarted queue isolates MainActor producer scheduling; live writer backpressure/deadlines are covered by EngineTransportOutputTests and EngineDiagnosticWriterTests.
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(5)
            ),
            capture: FakeCapture(), inference: FakeInferenceProvider(),
            events: EngineEventEmitter(transport: transport)
        )
        return Fixture(root: root, source: source, sink: sink, transport: transport, app: app)
    }

    private func reportableFailure(_ message: String) -> EngineFailure {
        EngineFailures.failure(
            code: .filesystem, message: message, stage: .finalization,
            sessionID: nil, severity: .error, recoveryAction: .none,
            details: [], cleanupErrors: []
        )
    }

    @Test func repeatedPendingFailureIsRetainedAndDeliveredOnce() async throws {
        let fixture = try fixture()
        defer {
            fixture.sink.release()
            fixture.transport.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = try await fixture.app.handlers.state.hello()
        fixture.app.handlers.state.helloDidComplete()
        let oversized = EngineFailures.failure(
            code: .rowTooLarge, message: "oversized transcript row",
            stage: .finalization, sessionID: nil, severity: .error,
            recoveryAction: .inspectSession, details: [], cleanupErrors: []
        )

        for _ in 0..<2_000 { fixture.app.core.report(oversized) }

        #expect(fixture.app.core.failures == [oversized])
        #expect(fixture.app.core.pendingFailureEvents == [oversized])
        #expect(fixture.app.core.failureEventTask != nil)
        fixture.sink.release()
        fixture.transport.start()
        await fixture.app.core.failureWorkerFinished()
        await fixture.transport.drain()

        let errors = try fixture.sink.outputs().compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event { failure } else { nil }
        }
        #expect(errors == [oversized])
    }

    @Test func historicalFailureCanBeReportedAndDeliveredAgain() async throws {
        let fixture = try fixture()
        defer {
            fixture.sink.release()
            fixture.transport.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = try await fixture.app.handlers.state.hello()
        fixture.app.handlers.state.helloDidComplete()
        let sessionID = UUID()
        let captureWarning = EngineFailures.failure(
            code: .captureFailure, message: "録音は保存しましたが、一部の音声が欠落した可能性があります", stage: .capture,
            sessionID: sessionID, severity: .warning, recoveryAction: .none,
            details: [], cleanupErrors: []
        )

        fixture.app.core.report(captureWarning)
        #expect(fixture.app.core.failures == [captureWarning])
        await fixture.app.core.failureWorkerFinished()
        fixture.sink.release()
        fixture.transport.start()
        await fixture.transport.drain()

        fixture.app.core.report(captureWarning)
        #expect(fixture.app.core.failures == [captureWarning, captureWarning])
        await fixture.app.core.failureWorkerFinished()
        await fixture.transport.drain()

        let outputs = try fixture.sink.outputs()
        let errors = outputs.compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event { failure } else { nil }
        }
        #expect(errors == [captureWarning, captureWarning])

        let stateFailures = outputs.compactMap { output -> [EngineFailure]? in
            if case let .state(state) = output.event { state.failures } else { nil }
        }
        #expect(stateFailures.contains([captureWarning]))
        #expect(stateFailures.contains([captureWarning, captureWarning]))
    }

    @Test func distinctFailureFloodIsBoundedAndShutdownPreventsLateErrors() async throws {
        let fixture = try fixture()
        defer {
            fixture.sink.release()
            fixture.transport.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = try await fixture.app.handlers.state.hello()
        fixture.app.handlers.state.helloDidComplete()
        let changes = ChangeSignal()
        fixture.app.core.onBackgroundEventStateChange = { changes.signal() }

        for index in 0..<2_000 {
            fixture.app.core.report(reportableFailure("background failure \(index)"))
        }
        #expect(fixture.app.core.failures.count == EngineApplicationCore.failureLimit)
        #expect(fixture.app.core.pendingFailureEvents.count <= EngineApplicationCore.failureLimit)
        #expect(fixture.app.core.failureEventTask != nil)

        try await changes.wait("the single failure worker to fill the transport queue") {
            fixture.app.core.inFlightFailureEvent?.message == "background failure 1987"
                && fixture.app.core.pendingFailureEvents.count == 12
        }
        #expect(fixture.app.core.pendingFailureEvents.map(\.message) == (1_988..<2_000).map { "background failure \($0)" })
        #expect(fixture.app.core.failureEventTask != nil)
        #expect(fixture.app.core.failures.map(\.message) == (1_984..<2_000).map { "background failure \($0)" })

        let shutdownReturned = LockedBox(false)
        let shutdownTask = Task { @MainActor in
            defer { shutdownReturned.set(true) }
            try await fixture.app.core.shutdown(reason: .requested)
        }
        try await changes.wait("shutdown to close background events") { fixture.app.core.eventsClosed }
        #expect(fixture.app.core.pendingFailureEvents.isEmpty)
        #expect(fixture.app.core.inFlightFailureEvent?.message == "background failure 1987")
        #expect(fixture.app.core.failureEventTask != nil)
        #expect(!shutdownReturned.get())

        fixture.sink.release()
        fixture.transport.start()
        try await shutdownTask.value
        #expect(shutdownReturned.get())
        #expect(fixture.app.core.failureEventTask == nil)
        #expect(fixture.app.core.inFlightFailureEvent == nil)

        try await fixture.transport.send(.completed(.shutdown), requestID: EngineID(1))
        fixture.app.core.report(reportableFailure("late background failure"))
        #expect(fixture.app.core.pendingFailureEvents.isEmpty)
        #expect(fixture.app.core.failureEventTask == nil)
        await fixture.transport.drain()

        let outputs = try fixture.sink.outputs()
        guard let terminalIndex = outputs.firstIndex(where: { output in
            guard output.requestID?.value == 1 else { return false }
            if case .completed(.shutdown) = output.event { return true }
            return false
        }) else {
            Issue.record("missing synthetic completed shutdown event")
            return
        }
        let errorIndices = outputs.indices.filter { index in
            if case .error = outputs[index].event { return true }
            return false
        }
        #expect(!errorIndices.isEmpty)
        #expect(errorIndices.allSatisfy { $0 < terminalIndex })
    }

    @Test func helloCompletionOpensBackgroundEventsWithCurrentStateAndShutdownKeepsGateClosed() async throws {
        let fixture = try fixture()
        defer {
            fixture.sink.release()
            fixture.transport.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = try await fixture.app.handlers.state.hello()
        #expect(!fixture.app.core.eventsEnabled)
        #expect(try fixture.sink.outputs().isEmpty)

        let failure = reportableFailure("failure before hello completion")
        fixture.app.core.report(failure)
        #expect(fixture.app.core.failures == [failure])
        #expect(fixture.app.core.pendingFailureEvents.isEmpty)
        #expect(fixture.app.core.publishedState?.failures == [failure])
        #expect(try fixture.sink.outputs().isEmpty)

        fixture.app.handlers.state.helloDidComplete()
        #expect(fixture.app.core.eventsEnabled)
        fixture.sink.release()
        fixture.transport.start()
        await fixture.transport.drain()

        let states = try fixture.sink.outputs().compactMap { output -> EngineState? in
            if case let .state(state) = output.event { state } else { nil }
        }
        #expect(states.count == 1)
        #expect(states.first?.failures == [failure])

        try await fixture.app.core.shutdown(reason: .requested)
        #expect(fixture.app.core.eventsClosed)
        #expect(!fixture.app.core.eventsEnabled)
        let outputCountAfterShutdown = try fixture.sink.outputs().count
        fixture.app.handlers.state.helloDidComplete()
        await fixture.transport.drain()
        #expect(!fixture.app.core.eventsEnabled)
        #expect(try fixture.sink.outputs().count == outputCountAfterShutdown)
    }

    @Test func recoveryMaintenanceFailuresDistinguishShutdownInterruptionFromFailure() async throws {
        let fixture = try fixture()
        defer {
            fixture.sink.release()
            fixture.transport.close()
            try? FileManager.default.removeItem(at: fixture.root)
        }

        _ = try await fixture.app.handlers.state.hello()
        fixture.app.handlers.state.helloDidComplete()
        let interruptedSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let failedSessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let interruptionReason = "終了処理のため保存整理を中断しました。次回起動時に再実行します"
        let failureReason = "permission denied"

        fixture.app.core.recoveryDidChange(.reportedFailures(
            scanFailures: [],
            maintenanceFailures: [
                interruptedSessionID: .interruptedByShutdown(interruptionReason),
                failedSessionID: .failed(failureReason)
            ],
            hasRecoveries: false
        ))

        fixture.sink.release()
        fixture.transport.start()
        await fixture.app.core.failureWorkerFinished()
        await fixture.transport.drain()

        let errors = try fixture.sink.outputs().compactMap { output -> EngineFailure? in
            if case let .error(failure) = output.event { failure } else { nil }
        }
        #expect(errors.map(\.sessionID) == [
            EngineFailures.wireID(interruptedSessionID), EngineFailures.wireID(failedSessionID)
        ])
        let interruptedFailure = try #require(errors.first { $0.sessionID == EngineFailures.wireID(interruptedSessionID) })
        #expect(interruptedFailure.code == .cancelled)
        #expect(interruptedFailure.stage == .maintenance)
        #expect(interruptedFailure.severity == .warning)
        #expect(interruptedFailure.recoveryAction == .restart)
        #expect(interruptedFailure.sessionID == EngineFailures.wireID(interruptedSessionID))
        #expect(interruptedFailure.message == interruptionReason)

        let failedFailure = try #require(errors.first { $0.sessionID == EngineFailures.wireID(failedSessionID) })
        #expect(failedFailure.code == .filesystem)
        #expect(failedFailure.stage == .maintenance)
        #expect(failedFailure.severity == .error)
        #expect(failedFailure.recoveryAction == .inspectSession)
        #expect(failedFailure.sessionID == EngineFailures.wireID(failedSessionID))
        #expect(failedFailure.message == "保存済み録音の音声を整理できませんでした: \(failureReason)")
        #expect(errors.filter { $0.code == .filesystem }.map(\.sessionID) == [EngineFailures.wireID(failedSessionID)])
    }
}
