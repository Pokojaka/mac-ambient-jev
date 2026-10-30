import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

actor LifecycleContinuationGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Error>?
    private let changes = ChangeSignal()

    func suspend() async throws {
        guard !entered else { preconditionFailure("a one-shot gate was entered more than once") }
        entered = true
        changes.signal()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if released {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async throws {
        try await changes.wait("lifecycle gate entry") { entered }
    }

    func release() {
        guard !released else { preconditionFailure("a one-shot gate was released more than once") }
        released = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    private func cancel() {
        guard !released else { return }
        released = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

actor LifecyclePollingSleepGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Error>?
    private let changes = ChangeSignal()

    func sleep(_ duration: Duration) async throws {
        guard !entered else { preconditionFailure("live polling sleep was entered more than once") }
        entered = true
        changes.signal()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async throws {
        try await changes.wait("live polling sleep entry") { entered }
    }

    private func cancel() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

final class LifecycleInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    private let engineProvider: FakeInferenceProvider
    private let validatingGate: LifecycleContinuationGate?
    private let preparationGate: LifecycleContinuationGate?
    private let preparationFailure: EngineAdapterError?
    private let liveVADFactoryFailure: EngineAdapterError?

    init(
        engineProvider: FakeInferenceProvider,
        validatingGate: LifecycleContinuationGate?,
        preparationGate: LifecycleContinuationGate?,
        preparationFailure: EngineAdapterError?,
        liveVADFactoryFailure: EngineAdapterError?
    ) {
        self.engineProvider = engineProvider
        self.validatingGate = validatingGate
        self.preparationGate = preparationGate
        self.preparationFailure = preparationFailure
        self.liveVADFactoryFailure = liveVADFactoryFailure
    }

    func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        if let validatingGate {
            try await validatingGate.suspend()
        }
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
        if let preparationGate {
            try await preparationGate.suspend()
        }
        if let preparationFailure {
            throw preparationFailure
        }
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let engineInference = try engineProvider.makeInference(settings: settings)
        let liveVADFactoryFailure = self.liveVADFactoryFailure
        return EngineInference(
            engines: engineInference.engines,
            contentPriority: engineInference.contentPriority,
            timelineBuilder: engineInference.timelineBuilder,
            makeLiveVADSession: { processingDirectory, sessionURL, checkpoint, segmentationRunID in
                if let liveVADFactoryFailure {
                    throw liveVADFactoryFailure
                }
                return try engineInference.makeLiveVADSession(
                    processingDirectory, sessionURL, checkpoint, segmentationRunID
                )
            }
        )
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        try await engineProvider.decisionUsage()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        try await engineProvider.inspectClauseTagger()
    }
}

@MainActor
final class LifecycleCaptureAdapter: EngineCaptureProviding {
    let fake: FakeCapture
    private let startGate: LifecycleContinuationGate?
    private let stopGate: LifecycleContinuationGate?

    init(
        startGate: LifecycleContinuationGate?,
        stopGate: LifecycleContinuationGate?,
        startFailure: EngineAdapterError?
    ) {
        fake = FakeCapture()
        fake.startError = startFailure
        self.startGate = startGate
        self.stopGate = stopGate
    }

    func devices(source: EngineSource) throws -> EngineDevicesResult {
        try fake.devices(source: source)
    }

    func startCapture(
        sessionID: UUID,
        sessionURL: URL,
        source: EngineSource,
        device: EngineDevice,
        callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        if let startGate {
            try await startGate.suspend()
        }
        let session = try await fake.startCapture(
            sessionID: sessionID,
            sessionURL: sessionURL,
            source: source,
            device: device,
            callbacks: callbacks
        )
        guard let stopGate else { return session }
        return LifecycleGatedCaptureSession(session: session, stopGate: stopGate)
    }
}

@MainActor
private final class LifecycleGatedCaptureSession: EngineCaptureSession {
    private let session: any EngineCaptureSession
    private let stopGate: LifecycleContinuationGate

    init(session: any EngineCaptureSession, stopGate: LifecycleContinuationGate) {
        self.session = session
        self.stopGate = stopGate
    }

    func committedCheckpoint() async throws -> AudioCheckpoint {
        try await session.committedCheckpoint()
    }

    func stop() async throws -> AudioCaptureStopResult {
        try await stopGate.suspend()
        return try await session.stop()
    }
}

@MainActor
final class EngineApplicationPresentationLifecycleFixture {
    let root: URL
    let paths: AppPaths
    let source: ScriptedSource
    let sink: ScriptedSink
    let transport: EngineTransport
    let app: EngineApplication
    let context: EngineRequestContext
    let capture: LifecycleCaptureAdapter
    let inference: LifecycleInferenceProvider
    let livePollingSleep: LifecyclePollingSleepGate
    private var isStarted = false
    private var isTransportClosed = false

    init(
        root: URL,
        validatingGate: LifecycleContinuationGate?,
        preparationGate: LifecycleContinuationGate?,
        preparationFailure: EngineAdapterError?,
        captureStartGate: LifecycleContinuationGate?,
        captureStopGate: LifecycleContinuationGate?,
        captureStartFailure: EngineAdapterError?,
        liveVADFactoryFailure: EngineAdapterError?
    ) throws {
        self.root = root
        paths = engineTestPaths(root: root)
        source = ScriptedSource()
        sink = ScriptedSink()
        transport = EngineTransport(
            source: source,
            sink: sink,
            limits: testLimits(
                maxRecords: 128,
                maxBytes: 8 * 1_048_576,
                reservedRecords: 32,
                reservedBytes: 2 * 1_048_576,
                pendingLines: 32,
                deadline: 5
            )
        )
        let engineProvider = FakeInferenceProvider()
        inference = LifecycleInferenceProvider(
            engineProvider: engineProvider,
            validatingGate: validatingGate,
            preparationGate: preparationGate,
            preparationFailure: preparationFailure,
            liveVADFactoryFailure: liveVADFactoryFailure
        )
        capture = LifecycleCaptureAdapter(
            startGate: captureStartGate,
            stopGate: captureStopGate,
            startFailure: captureStartFailure
        )
        let pollingSleep = LifecyclePollingSleepGate()
        livePollingSleep = pollingSleep
        let resourceMonitor = FakeResourceMonitor()
        let events = EngineEventEmitter(transport: transport)
        app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: 4,
                resourceMonitor: resourceMonitor,
                memoryProber: resourceMonitor,
                sleep: { duration in try await pollingSleep.sleep(duration) },
                shutdownPauseTimeout: .seconds(20)
            ),
            capture: capture,
            inference: inference,
            events: events
        )
        context = EngineRequestContext(requestID: try EngineID(1), events: events)
    }

    func start() async throws {
        guard !isStarted else { preconditionFailure("lifecycle fixture was started more than once") }
        isStarted = true
        transport.start()
        app.start()
        await app.waitForStartupRecovery()
        _ = try await app.handlers.state.hello()
        app.handlers.state.helloDidComplete()
        _ = try await waitForState(after: 0) { $0.revision.value > 0 }
    }

    func replaceSettings() async throws {
        let settings = try engineTestSettings(decisions: false, automaticExport: false, exportPath: nil)
        _ = try await app.handlers.settings.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings),
            context: context
        )
    }

    func prepareModels() async throws {
        try await acknowledgeResourceWarning(app, workload: .load, context: context)
        try await app.handlers.models.prepare(context: context)
        await app.core.processingCoordinator.waitUntilIdle()
    }

    func startRecording(source recordingSource: EngineSource) async throws -> EngineSessionPayload {
        try await acknowledgeResourceWarning(app, workload: .live, context: context)
        let payload = try EngineRecordingStartPayload(source: recordingSource, device: .default)
        return try await app.handlers.recording.start(payload, context: context)
    }

    func stopRecording(sessionID: String) async throws {
        let payload = try EngineSessionPayload(sessionID: sessionID)
        _ = try await app.handlers.recording.stop(payload, context: context)
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

    func waitForState(
        after revision: UInt64,
        matching predicate: (EngineState) -> Bool
    ) async throws -> EngineState {
        try await sink.changes.wait("engine state after revision \(revision)") {
            try stateEvents().contains { state in
                state.revision.value > revision && predicate(state)
            }
        }
        guard let state = try stateEvents().first(where: { state in
            state.revision.value > revision && predicate(state)
        }) else {
            throw TestTimeout(description: "matching engine state disappeared after revision \(revision)")
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
        precondition(resolvedRoot.lastPathComponent.hasPrefix("engine-presentation-lifecycle-"))
        do {
            try FileManager.default.removeItem(at: resolvedRoot)
        } catch {
            Issue.record("could not remove lifecycle test root: \(error)")
        }
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "engine-presentation-lifecycle-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

