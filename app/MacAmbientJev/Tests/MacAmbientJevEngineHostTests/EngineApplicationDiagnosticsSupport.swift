import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private struct DiagnosticsDecisionFailure: LocalizedError, Sendable {
    let operation: String
    var errorDescription: String? { "host-test \(operation) decision request failed" }
}

private enum DiagnosticsUsageOverride: Sendable {
    case none
    case failure(any Error)
    case snapshot(DecisionUsageSnapshot)
}

struct DiagnosticsDecisionFailurePlan: Sendable {
    var boundaryCallNumbers: Set<Int> = []
    var priorityCallNumbers: Set<Int> = []
}

private final class DiagnosticsDecisionProvider: DecisionProvider, @unchecked Sendable {
    private let calls: CallCounter
    private let failurePlan: LockedBox<DiagnosticsDecisionFailurePlan>

    init(calls: CallCounter, failurePlan: LockedBox<DiagnosticsDecisionFailurePlan>) {
        self.calls = calls
        self.failurePlan = failurePlan
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        calls.increment("boundary")
        if failurePlan.get().boundaryCallNumbers.contains(calls.count("boundary")) {
            throw DiagnosticsDecisionFailure(operation: "boundary")
        }
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next == nil ? nil : 0.1,
            fillerRanges: [],
            inputTokens: 11
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        calls.increment("priority")
        if failurePlan.get().priorityCallNumbers.contains(calls.count("priority")) {
            throw DiagnosticsDecisionFailure(operation: "priority")
        }
        let primary = try ContentPriorityDecision(
            priority: .primary, confidence: 1,
            probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, primary) }),
            inputTokens: 17
        )
    }
}

/// A host inference adapter with the real process-shared usage actor and cached provider factory.
final class DiagnosticsInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    let calls = CallCounter()
    let usageCounter = DecisionUsageCounter()
    let decisionProviderFactory: DecisionProviderFactory

    private let usageOverride = LockedBox<DiagnosticsUsageOverride>(.none)
    private let inspectionFailure = LockedBox<EngineAdapterError?>(nil)
    private let failurePlan = LockedBox(DiagnosticsDecisionFailurePlan())

    init() throws {
        let identity = try ClauseTaggerModelIdentity(
            backend: "host-test",
            modelID: "test-tagger",
            revision: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64)
        )
        let provider = DiagnosticsDecisionProvider(calls: calls, failurePlan: failurePlan)
        decisionProviderFactory = DecisionProviderFactory(usageCounter: usageCounter) { [calls] in
            calls.increment("providerLoad")
            return LoadedDecisionProvider(provider: provider, identity: identity)
        }
    }

    func setFailurePlan(_ plan: DiagnosticsDecisionFailurePlan) {
        failurePlan.set(plan)
    }

    func failDecisionUsage(with error: any Error) {
        usageOverride.set(.failure(error))
    }

    func returnMalformedDecisionUsage(_ snapshot: DecisionUsageSnapshot) {
        usageOverride.set(.snapshot(snapshot))
    }

    func failInspection(with error: EngineAdapterError?) {
        inspectionFailure.set(error)
    }

    func makeDecisionCoordinator() throws -> DecisionCoordinator {
        try decisionProviderFactory.makeCoordinator()
    }

    func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        calls.increment("prepare")
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        calls.increment("makeInference")
        let factory = decisionProviderFactory
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: FakeASR(calls: calls),
                diarization: FakeDiarizer(calls: calls),
                finalTranscriptVAD: FakeFinalVAD()
            ),
            contentPriority: .localTagger({ try factory.makeCoordinator() }, usageCounter: usageCounter),
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in FakeLiveVAD(segmentationRunID: runID) }
        )
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        switch usageOverride.get() {
        case .none:
            return await usageCounter.snapshot()
        case let .failure(error):
            throw error
        case let .snapshot(snapshot):
            return snapshot
        }
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        if let error = inspectionFailure.get() { throw error }
        return try decisionProviderFactory.localModelIdentity()
    }
}

struct DiagnosticsUsageFailure: LocalizedError, Sendable {
    let errorDescription: String? = "host-test decision usage collection failure"
}

/// Exercises the complete NDJSON command path with an injectable inference adapter.
@MainActor
final class DiagnosticsApplicationHarness {
    let root: URL
    let paths: AppPaths
    let source = ScriptedSource()
    let sink = ScriptedSink()
    let capture = FakeCapture()
    let inference: DiagnosticsInferenceProvider
    let transport: EngineTransport
    let app: EngineApplication
    let controller: EngineController

    private var runTask: Task<EngineExit, Never>?
    private var nextRequestID: UInt64 = 1

    init(root: URL, inference: DiagnosticsInferenceProvider) {
        self.root = root
        self.paths = engineTestPaths(root: root)
        self.inference = inference
        let transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        self.transport = transport
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: 4,
                sleep: { _ in },
                shutdownPauseTimeout: .seconds(20)
            ),
            capture: capture,
            inference: inference,
            events: EngineEventEmitter(transport: transport)
        )
        self.app = app
        controller = EngineController(transport: transport, handlers: app.handlers, admission: .production)
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "engine-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func start() {
        app.start()
        runTask = Task { await controller.run() }
    }

    func exit() async -> EngineExit {
        await runTask!.value
    }

    var outputs: [EngineOutput] {
        get throws { try sink.outputs() }
    }

    @discardableResult
    func call(_ command: String, payload: String = "{}") async throws -> EngineResult {
        let id = nextRequestID
        nextRequestID += 1
        source.feed(requestLine(id, command, payload: payload))
        let sink = self.sink
        try await sink.changes.wait("terminal reply to \(command)") {
            ((try? sink.outputs()) ?? []).contains {
                $0.requestID?.value == id && Self.isTerminal($0.event)
            }
        }
        if command == EngineCommandName.diagnosticsGet.rawValue
            || command == EngineCommandName.modelsInspect.rawValue {
            try expectAcceptedThenCompleted(for: id, command: command)
        }
        for output in try outputs where output.requestID?.value == id {
            switch output.event {
            case let .completed(result): return result
            case let .error(failure): throw CommandFailure(failure: failure)
            default: continue
            }
        }
        preconditionFailure("terminal reply vanished")
    }

    private func expectAcceptedThenCompleted(for id: UInt64, command: String) throws {
        let requestOutputs = try outputs.filter { $0.requestID?.value == id }
        #expect(requestOutputs.map { $0.event.name } == [.accepted, .completed])
        if requestOutputs.count == 2, case let .accepted(accepted) = requestOutputs[0].event {
            #expect(accepted.command.rawValue == command)
        } else {
            #expect(Bool(false), "expected accepted then completed for \(command)")
        }
    }

    func hello() async throws {
        try await call("hello")
    }

    func state() async throws -> EngineState {
        guard case let .stateGet(state) = try await call("state.get") else {
            preconditionFailure("state.get returned another result")
        }
        return state
    }

    func diagnostics() async throws -> EngineDiagnosticsResult {
        guard case let .diagnosticsGet(result) = try await call("diagnostics.get") else {
            preconditionFailure("diagnostics.get returned another result")
        }
        return result
    }

    func inspectModels() async throws -> EngineModelsInspection {
        guard case let .modelsInspect(result) = try await call("models.inspect") else {
            preconditionFailure("models.inspect returned another result")
        }
        return result
    }

    func replaceSettings(_ settings: EngineSettings, expectedRevision: UInt64?) async throws {
        let request = EngineSettingsReplacePayload(
            expectedRevision: try expectedRevision.map { try EngineID($0) }, settings: settings
        )
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try await call("settings.replace", payload: payload)
    }

    func sessions() async throws -> [EngineSessionSummary] {
        guard case let .sessionList(result) = try await call("session.list", payload: "{\"cursor\":null,\"limit\":100}") else {
            preconditionFailure("session.list returned another result")
        }
        return result.sessions
    }

    /// Rechecks the session listing only after a state publication, not after a delay.
    func waitForSession(status: EngineSessionStatus) async throws -> EngineSessionSummary {
        while true {
            let stateCountBefore = stateEventCount
            if let session = try await sessions().first(where: { $0.status == status }) { return session }
            try await sink.changes.wait("session to reach \(status)") { stateEventCount > stateCountBefore }
        }
    }

    var stateEventCount: Int {
        ((try? outputs) ?? []).filter {
            if case .state = $0.event { true } else { false }
        }.count
    }

    func shutdown() async throws -> EngineExit {
        try await call("shutdown")
        return await exit()
    }

    private nonisolated static func isTerminal(_ event: EngineEvent) -> Bool {
        switch event {
        case .completed, .error: true
        default: false
        }
    }
}

@MainActor
func withDiagnosticsHarness<T>(
    inference: DiagnosticsInferenceProvider,
    _ body: @MainActor (DiagnosticsApplicationHarness) async throws -> T
) async throws -> T {
    let root = try DiagnosticsApplicationHarness.makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = DiagnosticsApplicationHarness(root: root, inference: inference)
    harness.start()

    let result: T
    do {
        result = try await body(harness)
    } catch {
        _ = try? await harness.shutdown()
        throw error
    }
    _ = try await harness.shutdown()
    return result
}

func diagnosticsEngineSettings(decisions: Bool = true, asrSize: EngineASRSize = .small) throws -> EngineSettings {
    try EngineSettings(
        schemaVersion: 2, source: .microphone, device: .default, asrSize: asrSize,
        executionProvider: .cpu, threads: 1, lowHeat: false,
        decisionsEnabled: decisions, automaticExport: false, exportDestinationPath: nil
    )
}

func diagnosticsBoundaryRequest() throws -> ClauseBoundaryRequest {
    let source = try SegmentTextReference(
        segmentationRunID: "host-test-segmentation", segmentID: "host-test-segment-1",
        asrRunID: "host-test-asr", asrEventSeq: 1
    )
    let nextSource = try SegmentTextReference(
        segmentationRunID: "host-test-segmentation", segmentID: "host-test-segment-2",
        asrRunID: "host-test-asr", asrEventSeq: 2
    )
    let next = try NextSegmentHead(source: nextSource, text: "次の発話です")
    return try ClauseBoundaryRequest(source: source, text: "前半です。後半です？続き", next: next)
}

func diagnosticsPriorityTargets() -> [PriorityTextTarget] {
    [
        PriorityTextTarget(key: "u0001", text: "主題の文章です"),
        PriorityTextTarget(key: "u0002", text: "補足の文章です")
    ]
}

func diagnosticsJSONString(_ value: String) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
