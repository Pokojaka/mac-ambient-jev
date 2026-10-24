import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private final class OutOfOrderModelProgressProvider: EngineInferenceProviding, @unchecked Sendable {
    private let engineProvider = FakeInferenceProvider()
    let completionGate: LifecycleContinuationGate

    init(completionGate: LifecycleContinuationGate) {
        self.completionGate = completionGate
    }

    func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        let updates: [EngineModelProgress] = [
            EngineModelProgress(stage: .validating, completed: 0, total: 10),
            EngineModelProgress(stage: .loading, completed: 8, total: 10),
            EngineModelProgress(stage: .loading, completed: 2, total: 10),
            EngineModelProgress(stage: .validating, completed: 9, total: 10),
            EngineModelProgress(stage: .loading, completed: 10, total: 10),
            EngineModelProgress(stage: .loading, completed: 9, total: 10)
        ]
        for update in updates { onProgress(update) }
        try await completionGate.suspend()
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        try engineProvider.makeInference(settings: settings)
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        try await engineProvider.decisionUsage()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        try await engineProvider.inspectClauseTagger()
    }
}

@MainActor
private final class ModelProgressFixture {
    let root: URL
    let paths: AppPaths
    let source = ScriptedSource()
    let sink = ScriptedSink()
    let capture = FakeCapture()
    let transport: EngineTransport
    let provider: OutOfOrderModelProgressProvider
    let app: EngineApplication
    let context: EngineRequestContext
    private var isTransportClosed = false

    init(root: URL, completionGate: LifecycleContinuationGate) throws {
        self.root = root
        paths = engineTestPaths(root: root)
        transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        provider = OutOfOrderModelProgressProvider(completionGate: completionGate)
        let events = EngineEventEmitter(transport: transport)
        app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(20)
            ),
            capture: capture,
            inference: provider,
            events: events
        )
        context = EngineRequestContext(requestID: try EngineID(1), events: events)
    }

    func start() async throws {
        transport.start()
        app.start()
        await app.waitForStartupRecovery()
        _ = try await app.handlers.state.hello()
        app.handlers.state.helloDidComplete()
    }

    func replaceSettings() async throws {
        _ = try await app.handlers.settings.replace(
            EngineSettingsReplacePayload(
                expectedRevision: nil,
                settings: try engineTestSettings(decisions: false, automaticExport: false, exportPath: nil)
            ),
            context: context
        )
    }

    func currentState() async throws -> EngineState {
        try await app.handlers.state.state()
    }

    func stateEvents() throws -> [EngineState] {
        try sink.outputs().compactMap { output in
            guard case let .state(state) = output.event else { return nil }
            return state
        }
    }

    func progressEvents() throws -> [EngineProgressPayload] {
        try sink.outputs().compactMap { output in
            guard output.requestID?.value == 1, case let .progress(progress) = output.event else { return nil }
            return progress
        }
    }

    func waitForState(after revision: UInt64, matching predicate: (EngineState) -> Bool) async throws -> EngineState {
        try await sink.changes.wait("model progress state after revision \(revision)") {
            try self.stateEvents().contains { $0.revision.value > revision && predicate($0) }
        }
        guard let state = try stateEvents().first(where: { $0.revision.value > revision && predicate($0) }) else {
            throw TestTimeout(description: "matching model progress state disappeared after revision \(revision)")
        }
        return state
    }

    func shutdown() async throws {
        try await app.handlers.shutdown.shutdown(reason: .requested)
        await transport.drain()
        closeTransport()
    }

    func closeTransport() {
        guard !isTransportClosed else { return }
        isTransportClosed = true
        transport.close()
    }

    func removeRoot() {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        precondition(resolvedRoot.deletingLastPathComponent() == temporaryDirectory)
        precondition(resolvedRoot.lastPathComponent.hasPrefix("engine-model-progress-"))
        do {
            try FileManager.default.removeItem(at: resolvedRoot)
        } catch {
            Issue.record("could not remove model progress test root: \(error)")
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(2))) struct EngineApplicationModelProgressTests {
    @Test
    func progressIsOrderedMonotonicAndDoesNotCompletePreparationAtOneHundredPercent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "engine-model-progress-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let completionGate = LifecycleContinuationGate()
        let fixture = try ModelProgressFixture(root: root, completionGate: completionGate)
        defer {
            fixture.closeTransport()
            fixture.removeRoot()
        }

        try await fixture.start()
        try await fixture.replaceSettings()
        let initial = try await fixture.currentState()
        #expect(initial.setup == .modelsRequired)

        let preparationTask = Task { @MainActor in
            try await fixture.app.handlers.models.prepare(context: fixture.context)
        }
        defer { preparationTask.cancel() }
        try await completionGate.waitUntilEntered()
        let completeProgress = try await fixture.waitForState(after: initial.revision.value) { state in
            state.presentation.preparationPhase == .preparing
                && state.presentation.preparationStatusText == "音声認識モデルを読み込み中（100%）"
        }

        #expect(fixture.app.core.isPreparingModels)
        #expect(fixture.app.core.presentation.preparationID != nil)
        #expect(fixture.app.core.setupStatus == .modelsRequired)
        #expect(fixture.app.core.inference == nil)
        #expect(completeProgress.setup == .modelsRequired)

        await completionGate.release()
        try await preparationTask.value
        let ready = try await fixture.waitForState(after: completeProgress.revision.value) { state in
            state.setup == .ready
                && state.presentation.preparationPhase == .ready
                && state.presentation.preparationStatusText == nil
        }
        await fixture.transport.drain()
        #expect(!fixture.app.core.isPreparingModels)
        #expect(fixture.app.core.setupStatus == .ready)
        #expect(fixture.app.core.inference != nil)
        #expect(ready.setup == .ready)
        #expect(ready.presentation.preparationPhase == .ready)
        #expect(ready.presentation.preparationStatusText == nil)

        let observedStates = try fixture.stateEvents()
        let loadingPrefix = "音声認識モデルを読み込み中（"
        let observedLoadingPercentages = observedStates.compactMap { state -> Int? in
            guard let text = state.presentation.preparationStatusText,
                  text.hasPrefix(loadingPrefix),
                  text.hasSuffix("%）") else { return nil }
            return Int(text.dropFirst(loadingPrefix.count).dropLast(2))
        }
        #expect(!observedLoadingPercentages.isEmpty)
        #expect(zip(observedLoadingPercentages, observedLoadingPercentages.dropFirst()).allSatisfy(<=))
        #expect(observedLoadingPercentages.last == 100)

        let progress = try fixture.progressEvents()
        let loadingProgress = progress.filter { $0.stage == .loadingModels }
        let loadingPercentages = loadingProgress.map(\.completedUnits)
        #expect(progress.allSatisfy { $0.totalUnits == 100 })
        #expect(loadingPercentages == [80, 80, 100, 100] || loadingPercentages == [80, 100] || loadingPercentages == [100])
        #expect(zip(loadingPercentages, loadingPercentages.dropFirst()).allSatisfy(<=))
        if let firstLoadingIndex = progress.firstIndex(where: { $0.stage == .loadingModels }) {
            #expect(!progress.dropFirst(firstLoadingIndex + 1).contains { $0.stage == .validatingModels })
        } else {
            Issue.record("model loading did not emit progress")
        }
        try await fixture.shutdown()
    }
}
