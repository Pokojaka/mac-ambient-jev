import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private struct DecisionRetryTaggerFailure: LocalizedError, Sendable {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

private actor DecisionRetryPriorityGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let changes = ChangeSignal()

    func suspend() async {
        entered = true
        changes.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func waitUntilEntered() async throws {
        try await changes.wait("retry priority batch entry") { entered }
    }

    func release() {
        guard !released else { return }
        released = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private enum DecisionRetryFailureWriteTiming: Sendable {
    case beforeWrite
    case afterDurableWrite
}

private enum DecisionRetryFailureWriterMode: Sendable {
    case gateBeforeWrite(DecisionRetryPriorityGate)
    case gateAfterDurableWrite(DecisionRetryPriorityGate)
    case failAfterGate(DecisionRetryPriorityGate)
}

private actor DecisionRetryFailureEventWriter: DecisionEventWriting {
    nonisolated let eventsURL: URL
    private let writer: SessionWriter
    private let mode: DecisionRetryFailureWriterMode
    private var gatedFailedCompletion = false

    init(sessionURL: URL, mode: DecisionRetryFailureWriterMode) throws {
        let writer = try SessionWriter(sessionURL: sessionURL)
        eventsURL = sessionURL.appending(path: "events.jsonl")
        self.writer = writer
        self.mode = mode
    }

    func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) async throws -> EventEnvelope<Payload> {
        if let completion = draft.payload as? ProcessingRunCompletedPayload, !completion.succeeded {
            return try await appendFailedCompletion { try await writer.append(draft) }
        }
        return try await writer.append(draft)
    }

    func appendFailedRetryCompletion(
        _ draft: EventDraft<ProcessingRunCompletedPayload>
    ) async throws -> EventEnvelope<ProcessingRunCompletedPayload> {
        precondition(!draft.payload.succeeded)
        return try await appendFailedCompletion { try await writer.appendFailedRetryCompletion(draft) }
    }

    private func appendFailedCompletion<Envelope: Sendable>(
        _ append: () async throws -> Envelope
    ) async throws -> Envelope {
        precondition(!gatedFailedCompletion, "the failed retry completion gate must run exactly once")
        gatedFailedCompletion = true

        let gate: DecisionRetryPriorityGate
        let gateAfterWrite: Bool
        let failAfterGate: Bool
        switch mode {
        case let .gateBeforeWrite(value):
            gate = value
            gateAfterWrite = false
            failAfterGate = false
        case let .gateAfterDurableWrite(value):
            gate = value
            gateAfterWrite = true
            failAfterGate = false
        case let .failAfterGate(value):
            gate = value
            gateAfterWrite = false
            failAfterGate = true
        }

        if !gateAfterWrite { await gate.suspend() }
        if failAfterGate { throw POSIXError(.EIO) }
        let envelope = try await append()
        if gateAfterWrite { await gate.suspend() }
        return envelope
    }
}

private actor DecisionRetryFailureTagger: DecisionProvider {
    private enum RetryBehavior {
        case unconfigured
        case failure
        case suspended(DecisionRetryPriorityGate)
    }

    private var priorityCalls = 0
    private var retryBehavior: RetryBehavior = .unconfigured

    func configureRetryFailure() {
        retryBehavior = .failure
    }

    func configureRetrySuspension(_ gate: DecisionRetryPriorityGate) {
        retryBehavior = .suspended(gate)
    }

    func priorityCallCount() -> Int {
        priorityCalls
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: request.next == nil ? nil : 0.1,
            fillerRanges: [],
            inputTokens: 11
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityCalls += 1
        if priorityCalls == 1 {
            throw DecisionRetryTaggerFailure("初回の判定を保留します")
        }
        switch retryBehavior {
        case .unconfigured:
            preconditionFailure("retry behavior must be configured before the retry batch")
        case .failure:
            throw DecisionRetryTaggerFailure("テスト判定エンジンに失敗しました")
        case let .suspended(gate):
            await gate.suspend()
        }
        let primary = try ContentPriorityDecision(
            priority: .primary, confidence: 1, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, primary) }), inputTokens: 17
        )
    }
}

private final class DecisionRetryFailureInference: EngineInferenceProviding, @unchecked Sendable {
    let calls = CallCounter()
    let usageCounter = DecisionUsageCounter()
    let tagger = DecisionRetryFailureTagger()
    let identity: ClauseTaggerModelIdentity
    let factory: DecisionProviderFactory

    init() throws {
        identity = try ClauseTaggerModelIdentity(
            backend: "host-test",
            modelID: "retry-failure-tagger",
            revision: String(repeating: "a", count: 64),
            tokenizerSHA256: String(repeating: "b", count: 64)
        )
        let tagger = self.tagger
        let identity = self.identity
        factory = DecisionProviderFactory(usageCounter: usageCounter) {
            LoadedDecisionProvider(provider: tagger, identity: identity)
        }
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 0, total: 1))
        onProgress(EngineModelProgress(stage: .loading, completed: 1, total: 1))
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let factory = self.factory
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
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        identity
    }
}

/// The same injected-inference composition as the shared host harness, with a test-local tagger.
@MainActor
private final class DecisionRetryFailureApplicationHarness {
    let root: URL
    let paths: AppPaths
    let source = ScriptedSource()
    let sink = ScriptedSink()
    let capture = FakeCapture()
    let inference: DecisionRetryFailureInference
    let transport: EngineTransport
    let app: EngineApplication
    let controller: EngineController

    private var runTask: Task<EngineExit, Never>?
    private var nextRequestID: UInt64 = 1
    private(set) var lastRequestID: UInt64 = 0

    init(root: URL, inference: DecisionRetryFailureInference) {
        self.root = root
        paths = engineTestPaths(root: root)
        self.inference = inference
        transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths, logicalCPUCount: 4, sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(20)
            ),
            capture: capture,
            inference: inference,
            events: EngineEventEmitter(transport: transport)
        )
        controller = EngineController(transport: transport, handlers: app.handlers, admission: .production)
    }

    func start() {
        app.start()
        runTask = Task { await controller.run() }
    }

    func call(_ command: String, payload: String = "{}") async throws -> EngineResult {
        let id = nextRequestID
        nextRequestID += 1
        lastRequestID = id
        source.feed(requestLine(id, command, payload: payload))
        let sink = self.sink
        try await sink.changes.wait("terminal reply to \(command)") {
            try sink.outputs().contains {
                $0.requestID?.value == id && Self.isTerminal($0.event)
            }
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

    var outputs: [EngineOutput] {
        get throws { try sink.outputs() }
    }

    func sessions() async throws -> [EngineSessionSummary] {
        guard case let .sessionList(result) = try await call("session.list", payload: "{\"cursor\":null,\"limit\":100}") else {
            preconditionFailure("session.list returned another result")
        }
        return result.sessions
    }

    func state() async throws -> EngineState {
        guard case let .stateGet(state) = try await call("state.get") else {
            preconditionFailure("state.get returned another result")
        }
        return state
    }

    func waitForSession(status: EngineSessionStatus) async throws -> EngineSessionSummary {
        while true {
            let stateCountBefore = try stateEventCount
            if let session = try await sessions().first(where: { $0.status == status }) { return session }
            try await sink.changes.wait("session to reach \(status)") { try stateEventCount > stateCountBefore }
        }
    }

    var stateEventCount: Int {
        get throws {
            try outputs.filter { if case .state = $0.event { true } else { false } }.count
        }
    }

    func shutdown() async throws -> EngineExit {
        _ = try await call("shutdown")
        return await runTask!.value
    }

    private nonisolated static func isTerminal(_ event: EngineEvent) -> Bool {
        switch event {
        case .completed, .error: true
        default: false
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineApplicationDecisionRetryFailureTests {
    @Test func retryTaggerThrowFailsTheComposedControllerCommand() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeRoot(root) }
        let inference = try DecisionRetryFailureInference()
        let harness = DecisionRetryFailureApplicationHarness(root: root, inference: inference)
        harness.start()

        do {
            _ = try await harness.call("hello")
            _ = try await harness.call("settings.replace", payload: settingsPayload(try engineTestSettings(decisions: true)))
            _ = try await harness.call("models.prepare")

            let audio = root.appending(path: "pending-decisions.wav")
            try Data("RIFF-not-decoded-by-the-fake-timeline".utf8).write(to: audio)
            let importResult = try await harness.call(
                "session.import", payload: "{\"input_path\":\(jsonString(audio.path))}"
            )
            let imported = try #require({
                if case let .sessionImport(imported) = importResult { return imported }
                return nil
            }())
            let finalized = try await harness.waitForSession(status: .finalized)
            #expect(finalized.sessionID == imported.sessionID)

            let sessionURL = harness.paths.sessionsRoot.appending(path: finalized.folderID, directoryHint: .isDirectory)
            let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
            #expect(metadata.pendingClauseBoundarySegments.isEmpty)
            #expect(metadata.pendingContentPriorityClauses.count == 1)

            await inference.tagger.configureRetryFailure()
            var commandFailure: EngineFailure?
            do {
                _ = try await harness.call(
                    "session.retry_decisions", payload: "{\"session_id\":\(jsonString(imported.sessionID))}"
                )
            } catch let error as CommandFailure {
                commandFailure = error.failure
            }
            let retryRequestID = harness.lastRequestID
            let terminal = try #require(try harness.outputs.first {
                $0.requestID?.value == retryRequestID && ($0.event.name == .error || $0.event.name == .completed)
            })
            let terminalFailure = try #require(Self.failure(in: terminal.event))

            #expect(await inference.tagger.priorityCallCount() == 2)
            #expect(commandFailure != nil)
            #expect(terminalFailure.recoveryAction == .retryDecisions)

            let expectedMessage = "発話文の判定を再試行できませんでした: テスト判定エンジンに失敗しました"
            #expect(terminalFailure.message == expectedMessage)
            let expectedStateFailure = try EngineFailure(
                code: .processingFailure,
                message: expectedMessage,
                stage: .decisions,
                requestID: nil,
                sessionID: imported.sessionID,
                severity: .error,
                recoveryAction: .retryDecisions,
                details: [],
                cleanupErrors: []
            )
            #expect(commandFailure == terminalFailure)

            await harness.app.core.failureEventTask?.value
            let state = try #require(harness.app.core.publishedState)
            let sessionFailures = state.failures.filter { $0.sessionID == imported.sessionID }
            let backgroundFailures = try Self.backgroundFailures(in: harness.outputs, sessionID: imported.sessionID)
            #expect(sessionFailures == [expectedStateFailure])
            #expect(backgroundFailures == [expectedStateFailure])

            let actualSessionID = try #require(UUID(uuidString: imported.sessionID))
            let scanner = SessionRecoveryScanner(sessionsRoot: harness.paths.sessionsRoot)
            let failureInspection = try scanner.inspect(sessionID: actualSessionID)
            let failurePlan = SessionRecoveryPlan(failureInspection.recovery?.action)
            #expect(failurePlan.launchRecoveryRequest(sessionID: actualSessionID) == nil)

            let startupScan = try scanner.pendingSessions()
            let startupSessionPlans = startupScan.candidates
                .filter { $0.manifest.sessionID == actualSessionID }
                .map { SessionRecoveryPlan($0.action) }
            #expect(startupSessionPlans == [.retryContentPriority(
                boundarySegments: metadata.pendingClauseBoundarySegments,
                clauses: metadata.pendingContentPriorityClauses
            )])
            let sessionLaunchRequests = startupSessionPlans.compactMap {
                $0.launchRecoveryRequest(sessionID: actualSessionID)
            }
            #expect(sessionLaunchRequests.isEmpty)

            let interruptedRunID = "retry_crashed_after_failure"
            _ = try await SessionWriter(sessionURL: sessionURL).append(EventDraft(
                eventType: "processing.run.started", sessionID: actualSessionID,
                processingRunID: interruptedRunID,
                payload: ProcessingRunStartedPayload(
                    stage: .contentPriority,
                    provenance: DecisionRunProvenance.priority(
                        mode: "retry", identity: inference.identity.decisionIdentity
                    )
                )
            ))
            let interruptedInspection = try scanner.inspect(sessionID: actualSessionID)
            let interruptedPlan = SessionRecoveryPlan(interruptedInspection.recovery?.action)
            let interruptedLaunchRequest = interruptedPlan.launchRecoveryRequest(sessionID: actualSessionID)
            #expect({
                guard case let .retryContentPriority(sessionID, boundarySegments, clauses)? = interruptedLaunchRequest else {
                    return false
                }
                return sessionID == actualSessionID
                    && boundarySegments == metadata.pendingClauseBoundarySegments
                    && clauses == metadata.pendingContentPriorityClauses
            }())
            _ = try await harness.shutdown()
        } catch {
            do {
                _ = try await harness.shutdown()
            } catch {
                Issue.record("could not stop retry-failure harness after test error: \(error)")
            }
            throw error
        }
    }

    @Test func cancelledRetryDiscardsLatePriorityResponseAndHoldsRequest() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeRoot(root) }
        let inference = try DecisionRetryFailureInference()
        let harness = DecisionRetryFailureApplicationHarness(root: root, inference: inference)
        let gate = DecisionRetryPriorityGate()
        var retryTask: Task<EngineResult, Error>?
        harness.start()

        do {
            _ = try await harness.call("hello")
            _ = try await harness.call("settings.replace", payload: settingsPayload(try engineTestSettings(decisions: true)))
            _ = try await harness.call("models.prepare")

            let audio = root.appending(path: "pending-decisions.wav")
            try Data("RIFF-not-decoded-by-the-fake-timeline".utf8).write(to: audio)
            let importResult = try await harness.call(
                "session.import", payload: "{\"input_path\":\(jsonString(audio.path))}"
            )
            let imported = try #require({
                if case let .sessionImport(imported) = importResult { return imported }
                return nil
            }())
            let finalized = try await harness.waitForSession(status: .finalized)
            #expect(finalized.sessionID == imported.sessionID)

            let sessionURL = harness.paths.sessionsRoot.appending(path: finalized.folderID, directoryHint: .isDirectory)
            let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
            #expect(metadata.pendingClauseBoundarySegments.isEmpty)
            #expect(metadata.pendingContentPriorityClauses.count == 1)

            await inference.tagger.configureRetrySuspension(gate)
            let importedSessionID = try #require(UUID(uuidString: imported.sessionID))
            let task = Task {
                try await harness.call(
                    "session.retry_decisions", payload: "{\"session_id\":\(try jsonString(imported.sessionID))}"
                )
            }
            retryTask = task
            try await gate.waitUntilEntered()
            #expect(await inference.tagger.priorityCallCount() == 2)

            harness.app.core.processingCoordinator.requestPause()
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()
            var commandFailure: EngineFailure?
            do {
                _ = try await task.value
            } catch let error as CommandFailure {
                commandFailure = error.failure
            }
            let failure = try #require(commandFailure)
            await harness.app.core.failureEventTask?.value
            let state = try #require(harness.app.core.publishedState)
            let hasSessionFailure = state.failures.contains { $0.sessionID == imported.sessionID }
            let isHeld = harness.app.core.processingQueue.held.contains { $0.request.sessionID == importedSessionID }
            let backgroundProcessingFailures = try Self.backgroundFailures(
                in: harness.outputs, sessionID: imported.sessionID
            ).filter { $0.code == .processingFailure }
            let canceledMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())

            #expect(failure.code == .cancelled)
            #expect(failure.message == "処理は中断されました。次回の起動時に再開できます")
            #expect(failure.stage == .decisions)
            #expect(failure.severity == .warning)
            #expect(failure.sessionID == imported.sessionID)
            #expect(!hasSessionFailure)
            #expect(isHeld)
            #expect(backgroundProcessingFailures.isEmpty)
            #expect(canceledMetadata == metadata)

            let cancellationInspection = try SessionRecoveryScanner(sessionsRoot: harness.paths.sessionsRoot)
                .inspect(sessionID: importedSessionID)
            #expect(cancellationInspection.recovery?.action == .recoverDecisionRun(
                boundarySegments: metadata.pendingClauseBoundarySegments,
                clauses: metadata.pendingContentPriorityClauses
            ))
            let eventLines = try String(
                contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL, encoding: .utf8
            )
            let eventObjects = try eventLines.split(whereSeparator: \.isNewline).enumerated().map { entry in
                guard let event = try JSONSerialization.jsonObject(with: Data(entry.element.utf8)) as? [String: Any] else {
                    throw EventLogTranscriptReaderError.unreadableLine(index: entry.offset)
                }
                return event
            }
            let failedRunEnds = eventObjects.filter { event in
                event["event_type"] as? String == "processing.run.completed"
                    && (event["payload"] as? [String: Any])?["succeeded"] as? Bool == false
            }
            #expect(failedRunEnds.isEmpty)
            _ = try await harness.shutdown()
        } catch {
            harness.app.core.processingCoordinator.requestPause()
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()
            if let retryTask { _ = await retryTask.result }
            do {
                _ = try await harness.shutdown()
            } catch {
                Issue.record("could not stop retry-cancellation harness after test error: \(error)")
            }
            throw error
        }
    }

    @Test(arguments: [DecisionRetryFailureWriteTiming.beforeWrite, .afterDurableWrite])
    fileprivate func latePauseDuringFailedEndReportsOnlyFailure(_ timing: DecisionRetryFailureWriteTiming) async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeRoot(root) }
        let inference = try DecisionRetryFailureInference()
        let harness = DecisionRetryFailureApplicationHarness(root: root, inference: inference)
        let gate = DecisionRetryPriorityGate()
        let writerMode: DecisionRetryFailureWriterMode
        switch timing {
        case .beforeWrite: writerMode = .gateBeforeWrite(gate)
        case .afterDurableWrite: writerMode = .gateAfterDurableWrite(gate)
        }
        var retryTask: Task<EngineResult, Error>?
        harness.start()

        do {
            let prepared = try await preparePendingRetrySession(
                harness, inference: inference, root: root, writerMode: writerMode
            )
            let eventsBefore = try Self.eventObjects(sessionURL: prepared.sessionURL)
            let retryRunIDsBefore = Self.retryRunIDs(in: eventsBefore)
            let importedSessionID = try #require(UUID(uuidString: prepared.sessionID))
            let task = Task {
                try await harness.call(
                    "session.retry_decisions", payload: "{\"session_id\":\(try jsonString(prepared.sessionID))}"
                )
            }
            retryTask = task
            try await gate.waitUntilEntered()
            #expect(await inference.tagger.priorityCallCount() == 2)

            harness.app.core.processingCoordinator.requestPause()
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()

            var commandFailure: EngineFailure?
            do {
                _ = try await task.value
            } catch let error as CommandFailure {
                commandFailure = error.failure
            }
            let retryRequestID = harness.lastRequestID
            let terminal = try #require(try harness.outputs.first {
                $0.requestID?.value == retryRequestID && ($0.event.name == .error || $0.event.name == .completed)
            })
            let terminalFailure = try #require(Self.failure(in: terminal.event))
            let expectedMessage = "発話文の判定を再試行できませんでした: テスト判定エンジンに失敗しました"
            let expectedFailure = try EngineFailure(
                code: .processingFailure,
                message: expectedMessage,
                stage: .decisions,
                requestID: nil,
                sessionID: prepared.sessionID,
                severity: .error,
                recoveryAction: .retryDecisions,
                details: [],
                cleanupErrors: []
            )
            #expect(commandFailure == terminalFailure)
            #expect(terminalFailure.code == .processingFailure)
            #expect(terminalFailure.message == expectedMessage)
            #expect(terminalFailure.stage == .decisions)
            #expect(terminalFailure.severity == .error)
            #expect(terminalFailure.sessionID == prepared.sessionID)
            #expect(terminalFailure.recoveryAction == .retryDecisions)

            await harness.app.core.failureEventTask?.value
            let state = try #require(harness.app.core.publishedState)
            #expect(state.failures.filter { $0.sessionID == prepared.sessionID } == [expectedFailure])
            let backgroundProcessingFailures = try Self.backgroundFailures(
                in: harness.outputs, sessionID: prepared.sessionID
            ).filter { $0.code == .processingFailure }
            #expect(backgroundProcessingFailures == [expectedFailure])
            let cancelledEvents = try Self.cancelledFailures(in: harness.outputs, sessionID: prepared.sessionID)
            #expect(cancelledEvents.isEmpty)
            #expect(harness.app.core.processingQueue.held.isEmpty)
            #expect(harness.app.core.processingQueue.pending.isEmpty)
            #expect(harness.app.core.processingQueue.currentSessionID == nil)
            let unchangedMetadata = try #require(
                try ProcessingMetadataStore(sessionURL: prepared.sessionURL).load()
            )
            #expect(unchangedMetadata == prepared.metadata)

            let eventObjects = try Self.eventObjects(sessionURL: prepared.sessionURL)
            let retryRunIDs = Self.retryRunIDs(in: eventObjects).subtracting(retryRunIDsBefore)
            #expect(retryRunIDs.count == 1)
            #expect(Self.failedCompletionEvents(in: eventObjects, runIDs: retryRunIDs).count == 1)

            let scanner = SessionRecoveryScanner(sessionsRoot: harness.paths.sessionsRoot)
            let failureInspection = try scanner.inspect(sessionID: importedSessionID)
            let failurePlan = SessionRecoveryPlan(failureInspection.recovery?.action)
            #expect(failurePlan.launchRecoveryRequest(sessionID: importedSessionID) == nil)
            let startupPlans = try scanner.pendingSessions().candidates
                .filter { $0.manifest.sessionID == importedSessionID }
                .map { SessionRecoveryPlan($0.action) }
            #expect(startupPlans == [.retryContentPriority(
                boundarySegments: prepared.metadata.pendingClauseBoundarySegments,
                clauses: prepared.metadata.pendingContentPriorityClauses
            )])
            #expect(startupPlans.compactMap { $0.launchRecoveryRequest(sessionID: importedSessionID) }.isEmpty)
            _ = try await harness.shutdown()
        } catch {
            harness.app.core.processingCoordinator.requestPause()
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()
            if let retryTask { _ = await retryTask.result }
            do {
                _ = try await harness.shutdown()
            } catch {
                Issue.record("could not stop failed-end harness after test error: \(error)")
            }
            throw error
        }
    }

    @Test(arguments: [false, true])
    func failedEndWriteIOFailureReportsFailureAndRemainsRecoverable(cancelDuringWrite: Bool) async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { removeRoot(root) }
        let inference = try DecisionRetryFailureInference()
        let harness = DecisionRetryFailureApplicationHarness(root: root, inference: inference)
        let gate = DecisionRetryPriorityGate()
        var retryTask: Task<EngineResult, Error>?
        harness.start()

        do {
            let prepared = try await preparePendingRetrySession(
                harness, inference: inference, root: root, writerMode: .failAfterGate(gate)
            )
            let eventsBefore = try Self.eventObjects(sessionURL: prepared.sessionURL)
            let retryRunIDsBefore = Self.retryRunIDs(in: eventsBefore)
            let importedSessionID = try #require(UUID(uuidString: prepared.sessionID))
            let task = Task {
                try await harness.call(
                    "session.retry_decisions", payload: "{\"session_id\":\(try jsonString(prepared.sessionID))}"
                )
            }
            retryTask = task
            try await gate.waitUntilEntered()
            #expect(await inference.tagger.priorityCallCount() == 2)

            if cancelDuringWrite {
                harness.app.core.processingCoordinator.requestPause()
            }
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()

            var commandFailure: EngineFailure?
            do {
                _ = try await task.value
            } catch let error as CommandFailure {
                commandFailure = error.failure
            }
            let retryRequestID = harness.lastRequestID
            let terminal = try #require(try harness.outputs.first {
                $0.requestID?.value == retryRequestID && ($0.event.name == .error || $0.event.name == .completed)
            })
            let terminalFailure = try #require(Self.failure(in: terminal.event))
            let failure = try #require(commandFailure)
            #expect(commandFailure == terminalFailure)
            #expect(failure.code == .processingFailure)
            #expect(failure.stage == .decisions)
            #expect(failure.severity == .error)
            #expect(failure.sessionID == prepared.sessionID)
            #expect(failure.recoveryAction == .retryDecisions)
            #expect(failure.message.contains("テスト判定エンジンに失敗しました"))
            #expect(failure.message.contains(POSIXError(.EIO).localizedDescription))
            let expectedStateFailure = try EngineFailure(
                code: failure.code,
                message: failure.message,
                stage: failure.stage,
                requestID: nil,
                sessionID: failure.sessionID,
                severity: failure.severity,
                recoveryAction: failure.recoveryAction,
                details: failure.details,
                cleanupErrors: failure.cleanupErrors
            )

            await harness.app.core.failureEventTask?.value
            let state = try #require(harness.app.core.publishedState)
            let stateProcessingFailures = state.failures.filter {
                $0.sessionID == prepared.sessionID && $0.code == .processingFailure
            }
            #expect(stateProcessingFailures == [expectedStateFailure])
            let backgroundProcessingFailures = try Self.backgroundFailures(
                in: harness.outputs, sessionID: prepared.sessionID
            ).filter { $0.code == .processingFailure }
            #expect(backgroundProcessingFailures == [expectedStateFailure])
            let cancelledEvents = try Self.cancelledFailures(in: harness.outputs, sessionID: prepared.sessionID)
            #expect(cancelledEvents.isEmpty)
            #expect(harness.app.core.processingQueue.held.isEmpty)
            #expect(harness.app.core.processingQueue.pending.isEmpty)
            #expect(harness.app.core.processingQueue.currentSessionID == nil)
            let unchangedMetadata = try #require(
                try ProcessingMetadataStore(sessionURL: prepared.sessionURL).load()
            )
            #expect(unchangedMetadata == prepared.metadata)

            let eventObjects = try Self.eventObjects(sessionURL: prepared.sessionURL)
            let retryRunIDs = Self.retryRunIDs(in: eventObjects).subtracting(retryRunIDsBefore)
            #expect(retryRunIDs.count == 1)
            #expect(Self.failedCompletionEvents(in: eventObjects, runIDs: retryRunIDs).isEmpty)

            let scanner = SessionRecoveryScanner(sessionsRoot: harness.paths.sessionsRoot)
            let inspection = try scanner.inspect(sessionID: importedSessionID)
            let recoveryPlan = SessionRecoveryPlan(inspection.recovery?.action)
            #expect(recoveryPlan == .recoverDecisionRun(
                boundarySegments: prepared.metadata.pendingClauseBoundarySegments,
                clauses: prepared.metadata.pendingContentPriorityClauses
            ))
            let launchRequest = recoveryPlan.launchRecoveryRequest(sessionID: importedSessionID)
            #expect({
                guard case let .retryContentPriority(sessionID, boundarySegments, clauses)? = launchRequest else {
                    return false
                }
                return sessionID == importedSessionID
                    && boundarySegments == prepared.metadata.pendingClauseBoundarySegments
                    && clauses == prepared.metadata.pendingContentPriorityClauses
            }())
            _ = try await harness.shutdown()
        } catch {
            harness.app.core.processingCoordinator.requestPause()
            await gate.release()
            await harness.app.core.processingCoordinator.waitUntilIdle()
            if let retryTask { _ = await retryTask.result }
            do {
                _ = try await harness.shutdown()
            } catch {
                Issue.record("could not stop failed-end harness after test error: \(error)")
            }
            throw error
        }
    }

    private func preparePendingRetrySession(
        _ harness: DecisionRetryFailureApplicationHarness,
        inference: DecisionRetryFailureInference,
        root: URL,
        writerMode: DecisionRetryFailureWriterMode
    ) async throws -> (sessionID: String, sessionURL: URL, metadata: ProcessingMetadata) {
        _ = try await harness.call("hello")
        _ = try await harness.call(
            "settings.replace", payload: settingsPayload(try engineTestSettings(decisions: true))
        )
        _ = try await harness.call("models.prepare")

        let audio = root.appending(path: "pending-decisions.wav")
        try Data("RIFF-not-decoded-by-the-fake-timeline".utf8).write(to: audio)
        let importResult = try await harness.call(
            "session.import", payload: "{\"input_path\":\(jsonString(audio.path))}"
        )
        let imported = try #require({
            if case let .sessionImport(imported) = importResult { return imported }
            return nil
        }())
        let finalized = try await harness.waitForSession(status: .finalized)
        #expect(finalized.sessionID == imported.sessionID)

        let sessionURL = harness.paths.sessionsRoot.appending(
            path: finalized.folderID, directoryHint: .isDirectory
        )
        let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
        #expect(metadata.pendingClauseBoundarySegments.isEmpty)
        #expect(metadata.pendingContentPriorityClauses.count == 1)

        let bundle = try inference.makeInference(settings: try engineTestSettings(decisions: true))
        let processor = NativeSessionProcessor(
            paths: harness.paths,
            engines: bundle.engines,
            audioHandling: SessionProcessingAudio(timelineBuilder: bundle.timelineBuilder),
            contentPriority: bundle.contentPriority,
            sleep: { _ in },
            makeDecisionEventWriter: { sessionURL in
                try DecisionRetryFailureEventWriter(sessionURL: sessionURL, mode: writerMode)
            }
        )
        harness.app.core.gateway.install(processor, pacing: .normal)
        await inference.tagger.configureRetryFailure()
        return (imported.sessionID, sessionURL, metadata)
    }

    private static func eventObjects(sessionURL: URL) throws -> [[String: Any]] {
        let eventLines = try String(
            contentsOf: SessionLayout(sessionURL: sessionURL).eventsURL, encoding: .utf8
        )
        return try eventLines.split(whereSeparator: \.isNewline).enumerated().map { entry in
            guard let event = try JSONSerialization.jsonObject(with: Data(entry.element.utf8)) as? [String: Any] else {
                throw EventLogTranscriptReaderError.unreadableLine(index: entry.offset)
            }
            return event
        }
    }

    private static func retryRunIDs(in events: [[String: Any]]) -> Set<String> {
        Set(events.compactMap { event in
            guard event["event_type"] as? String == "processing.run.started",
                  let payload = event["payload"] as? [String: Any],
                  payload["stage"] as? String == ProcessingStage.contentPriority.rawValue,
                  let provenance = payload["provenance"] as? [String: Any],
                  let configuration = provenance["configuration"] as? [String: String],
                  configuration["mode"] == "retry",
                  let runID = event["processing_run_id"] as? String else {
                return nil
            }
            return runID
        })
    }

    private static func failedCompletionEvents(
        in events: [[String: Any]], runIDs: Set<String>
    ) -> [[String: Any]] {
        events.filter { event in
            event["event_type"] as? String == "processing.run.completed"
                && (event["processing_run_id"] as? String).map(runIDs.contains) == true
                && (event["payload"] as? [String: Any])?["succeeded"] as? Bool == false
        }
    }

    private static func cancelledFailures(in outputs: [EngineOutput], sessionID: String) -> [EngineFailure] {
        outputs.compactMap { output in
            guard case let .error(failure) = output.event,
                  failure.sessionID == sessionID,
                  failure.code == .cancelled else {
                return nil
            }
            return failure
        }
    }

    private static func failure(in event: EngineEvent) -> EngineFailure? {
        guard case let .error(failure) = event else { return nil }
        return failure
    }

    private static func backgroundFailures(in outputs: [EngineOutput], sessionID: String) -> [EngineFailure] {
        outputs.compactMap { output in
            guard output.requestID == nil,
                  case let .error(failure) = output.event,
                  failure.sessionID == sessionID else {
                return nil
            }
            return failure
        }
    }

    private func settingsPayload(_ settings: EngineSettings) throws -> String {
        let payload = EngineSettingsReplacePayload(expectedRevision: nil, settings: settings)
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    private func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func removeRoot(_ root: URL) {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        precondition(resolvedRoot.deletingLastPathComponent() == temporaryDirectory)
        precondition(resolvedRoot.lastPathComponent.hasPrefix("engine-app-"))
        do {
            try FileManager.default.removeItem(at: resolvedRoot)
        } catch {
            Issue.record("could not remove test root: \(error)")
        }
    }
}
