import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationInspectionCancellationTests {
    private final class CancellingInspectionInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
        private let base = FakeInferenceProvider()

        func prepare(
            settings: EngineSettings,
            onProgress: @escaping @Sendable (EngineModelProgress) -> Void
        ) async throws {
            try await base.prepare(settings: settings, onProgress: onProgress)
        }

        func makeInference(settings: EngineSettings) throws -> EngineInference {
            try base.makeInference(settings: settings)
        }

        func decisionUsage() async throws -> DecisionUsageSnapshot {
            try await base.decisionUsage()
        }

        func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
            throw CancellationError()
        }
    }

    @Test func cancelledModelsInspectionIsReturnedAsCorrelatedCommandError() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = ScriptedSource()
        let sink = ScriptedSink()
        let transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)
            ),
            capture: FakeCapture(), inference: CancellingInspectionInferenceProvider(), events: events
        )
        let controller = EngineController(transport: transport, handlers: app.handlers, admission: .production)
        app.start()
        let runTask = Task { await controller.run() }
        defer { source.finish() }

        source.feed(requestLine(1, "hello"))
        try await sink.changes.wait("hello completion") {
            ((try? sink.outputs()) ?? []).contains { output in
                output.requestID?.value == 1 && { if case .completed = output.event { true } else { false } }()
            }
        }

        source.feed(requestLine(2, "models.inspect"))
        try await sink.changes.wait("models.inspect terminal reply") {
            ((try? sink.outputs()) ?? []).contains { output in
                guard output.requestID?.value == 2 else { return false }
                switch output.event {
                case .completed, .error: return true
                default: return false
                }
            }
        }

        let requestOutputs = try sink.outputs().filter { $0.requestID?.value == 2 }
        #expect(requestOutputs.count == 2)
        guard let terminal = requestOutputs.last else {
            Issue.record("models.inspect did not produce a terminal reply")
            return
        }
        switch terminal.event {
        case let .error(failure):
            #expect(failure.code == .cancelled)
            #expect(failure.stage == .validatingModels)
            #expect(failure.requestID?.value == 2)
        case .completed:
            Issue.record("cancelled inspection must not complete with an invalid result")
        default:
            Issue.record("models.inspect terminal reply was not an error")
        }

        source.finish()
        #expect(await runTask.value == .inputClosed)
    }
}
