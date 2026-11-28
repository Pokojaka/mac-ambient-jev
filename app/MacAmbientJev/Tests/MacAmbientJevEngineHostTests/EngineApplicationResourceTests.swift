import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline
import MacAmbientJevTestSupport

private enum Pressure: CaseIterable, Equatable, Sendable {
    case pressure, monitorFailed
    var signal: InferenceResourceSignal { self == .pressure ? .pressure : .monitorFailed("test") }
    var hold: InferenceHoldReason { self == .pressure ? .resourcePressure : .monitorFailed }
}

@MainActor private final class ResourceFixture {
    let root: URL, paths: AppPaths, settings: EngineSettings, resources: FakeResourceMonitor
    let capture = FakeCapture()
    let app: EngineApplication
    let context: EngineRequestContext
    init(
        inference: any EngineInferenceProviding, resources: FakeResourceMonitor, shutdownPauseTimeout: Duration
    ) throws {
        root = try ApplicationHarness.makeRoot(); paths = engineTestPaths(root: root)
        settings = try engineTestSettings(); self.resources = resources
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        app = EngineApplication(configuration: EngineApplicationConfiguration(
            paths: paths, logicalCPUCount: 4, resourceMonitor: resources,
            sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: shutdownPauseTimeout, timeZone: TimeZone(identifier: "Asia/Tokyo")!), capture: capture, inference: inference, events: events)
        context = EngineRequestContext(requestID: try EngineID(1), events: events, terminalReplyClaim: {})
    }
    func start() async throws {
        app.start(); await app.waitForStartupRecovery()
        _ = try await app.core.replace(.init(expectedRevision: nil, settings: settings), context: context)
    }
    func prepare() async {
        await app.core.awaitModelPreparation(); await app.core.processingCoordinator.waitUntilIdle()
    }
    func shutdown() async throws { try await app.core.shutdown(reason: .requested) }
}

private actor RPCCompletionProbe {
    private var returned = false
    func markReturned() { returned = true }
    func hasReturned() -> Bool { returned }
}

private protocol ResourceASRGate: Sendable {
    func suspend() async throws
}

extension LifecycleContinuationGate: ResourceASRGate {}

private actor UncancellableResourceGate: ResourceASRGate {
    private var armed: Bool
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let changes = ChangeSignal()

    init(armed: Bool = true) { self.armed = armed }

    func arm() {
        guard !released else { preconditionFailure("released gate cannot be armed again") }
        armed = true
    }

    func suspend() async throws {
        guard armed else { return }
        armed = false
        entered = true
        changes.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released { continuation.resume() }
            else { self.continuation = continuation }
        }
    }

    func waitUntilEntered() async throws {
        try await changes.wait("uncancellable inference gate entry") { entered }
    }

    func release() {
        guard !released else { preconditionFailure("uncancellable gate released more than once") }
        released = true
        continuation?.resume()
        continuation = nil
    }

    func releaseFromCleanup() {
        guard !released else { return }
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ResourceGatedASR: ASREngine {
    let gate: any ResourceASRGate, calls: CallCounter, holdCall: Int
    let unloadGate: (any ResourceASRGate)?
    let provenance = RunProvenance(engine: "resource-gated-asr", model: nil, version: "test", configuration: [:])
    func prepare() async throws {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        if calls.count("asr") == holdCall { try await gate.suspend() }
        return ASRResult(text: "日本語のテストです。", detectedLanguage: "ja")
    }
    func unload() async {
        calls.increment("asr.unload")
        try? await unloadGate?.suspend()
    }
}

private struct ResourceFinalVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "resource-final-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        [SegmentReference(segmentationRunID: runID, segmentID: "first", speechRanges: [0..<16_000]),
         SegmentReference(segmentationRunID: runID, segmentID: "second", speechRanges: [16_000..<32_000])]
    }
}

private final class ResourceGatedProvider: EngineInferenceProviding, @unchecked Sendable {
    let base = FakeInferenceProvider(), gate: any ResourceASRGate, holdCall: Int
    let unloadGate: (any ResourceASRGate)?
    init(gate: any ResourceASRGate, holdCall: Int, unloadGate: (any ResourceASRGate)? = nil) {
        self.gate = gate
        self.holdCall = holdCall
        self.unloadGate = unloadGate
    }
    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        try await base.prepare(settings: settings, onProgress: onProgress)
    }
    func decisionUsage() async throws -> DecisionUsageSnapshot { try await base.decisionUsage() }
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity { try await base.inspectClauseTagger() }
    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let standard = try base.makeInference(settings: settings)
        return EngineInference(engines: SessionProcessingEngines(
            asr: ResourceGatedASR(
                gate: gate, calls: base.calls, holdCall: holdCall, unloadGate: unloadGate
            ), finalTranscriptVAD: ResourceFinalVAD()),
            contentPriority: standard.contentPriority, timelineBuilder: standard.timelineBuilder,
            makeLiveVADSession: standard.makeLiveVADSession)
    }
}

@MainActor @Suite struct EngineApplicationResourceTests {
    @Test
    fileprivate func idleMonitorFailureIsPublishedOncePerDistinctDetail() async throws {
        let f = try ResourceFixture(
            inference: FakeInferenceProvider(), resources: FakeResourceMonitor(), shutdownPauseTimeout: .seconds(30)
        )
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start()
        await f.prepare()
        #expect(f.app.core.processingQueue.summaries.isEmpty)

        let detail = "idle monitor probe failed"
        f.resources.setSignal(.monitorFailed(detail))
        let first = EngineFailures.failure(
            code: .internalError,
            message: "Windows の推論リソース監視に失敗しました（\(detail)）。アプリを再起動してください。",
            stage: .finalization, sessionID: nil, severity: .error, recoveryAction: .restart
        )
        #expect(f.app.core.publishedState?.failures == [first])

        f.resources.setSignal(.healthy)
        f.resources.setSignal(.monitorFailed(detail))
        #expect(f.app.core.publishedState?.failures == [first])

        let secondDetail = "another idle monitor probe failure"
        f.resources.setSignal(.monitorFailed(secondDetail))
        let monitorFailure = EngineFailures.failure(
            code: .internalError,
            message: "Windows の推論リソース監視に失敗しました（\(secondDetail)）。アプリを再起動してください。",
            stage: .finalization, sessionID: nil, severity: .error, recoveryAction: .restart
        )
        #expect(f.app.core.publishedState?.failures == [monitorFailure])

        let ordinaryFailures = (0..<20).map { index in
            EngineFailures.failure(
                code: .processingFailure, message: "ordinary failure \(index)", stage: .finalization,
                sessionID: nil, severity: .error, recoveryAction: .retry
            )
        }
        for failure in ordinaryFailures { f.app.core.report(failure) }
        let publishedFailures = try #require(f.app.core.publishedState?.failures)
        #expect(publishedFailures.count == EngineApplicationCore.failureLimit)
        #expect(publishedFailures.first == monitorFailure)
        #expect(!publishedFailures.contains(first))
        #expect(Array(publishedFailures.dropFirst()) == Array(ordinaryFailures.suffix(EngineApplicationCore.failureLimit - 1)))
        try await f.shutdown()
    }

    @Test(arguments: Pressure.allCases)
    fileprivate func liveResourceHoldKeepsRecordingAndDurableAudio(_ pressure: Pressure) async throws {
        let f = try ResourceFixture(
            inference: FakeInferenceProvider(), resources: FakeResourceMonitor(), shutdownPauseTimeout: .seconds(30)
        )
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); await f.prepare()
        let recording = try await f.app.core.start(.init(source: .microphone, device: .default), context: f.context)
        let id = try #require(UUID(uuidString: recording.sessionID)), capture = try #require(f.capture.session)
        try await capture.appendSpeech(seconds: 1); let before = try await capture.committedCheckpoint()
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.recording.phase == .recording)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        f.resources.setSignal(.healthy)
        try await capture.appendSpeech(seconds: 1)
        #expect((try await capture.committedCheckpoint()).committedFrames > before.committedFrames)
        #expect(!capture.isStopped && f.app.core.recording.phase == .recording)
        #expect(f.app.core.liveTranscription.failure(sessionID: id) != nil)
        try await f.shutdown()
    }

    @Test
    fileprivate func completionRegistryUsesRequestIdentityAndKeepsHeldWaiters() async throws {
        let registry = EngineCompletionRegistry()
        let sessionID = UUID()
        var admission = SessionProcessingQueue()
        let admitted = admission.enqueueAdmittedReplacement(sessionID: sessionID)
        let admittedRequestID = try #require(admitted)
        let firstRequest = try #require(admission.pending.first)
        #expect(firstRequest.requestID == admittedRequestID)
        let secondRequest = PendingProcessing.finalize(
            requestID: UUID(), sessionID: sessionID, metadataPolicy: .reject
        )
        let pausedRequest = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        registry.register(requestID: firstRequest.requestID, terminalReplyClaim: {})
        registry.register(requestID: secondRequest.requestID, terminalReplyClaim: {})
        registry.register(requestID: pausedRequest.requestID, terminalReplyClaim: {})
        let heldItem = ProcessingQueueItemSummary(
            requestID: firstRequest.requestID, sessionID: sessionID, kind: .replacement,
            holdReason: .inference(.resourcePressure)
        )
        let secondItem = ProcessingQueueItemSummary(
            requestID: secondRequest.requestID, sessionID: secondRequest.sessionID, kind: .finalization, holdReason: nil
        )
        let pausedItem = ProcessingQueueItemSummary(
            requestID: pausedRequest.requestID, sessionID: pausedRequest.sessionID, kind: .finalization,
            holdReason: .paused
        )
        let probe = RPCCompletionProbe()
        let first = Task {
            let outcome = try await registry.wait(requestID: firstRequest.requestID)
            await probe.markReturned()
            return outcome
        }
        await Task.yield()
        registry.finished(
            heldItem,
            result: .paused(
                metrics: nil, retained: .nothing, message: "held", reason: .resourcePressure,
                replacementGeneration: .notOpened
            ),
            isShutdownCancellation: false
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await probe.hasReturned()))

        let paused = Task { try await registry.wait(requestID: pausedRequest.requestID) }
        await Task.yield()
        registry.finished(
            pausedItem,
            result: .paused(
                metrics: nil, retained: .nothing, message: "paused", replacementGeneration: .notOpened
            ),
            isShutdownCancellation: false
        )
        if case .paused = try await paused.value {} else {
            Issue.record("a user-paused request must resolve its RPC waiter immediately")
        }

        let second = Task { try await registry.wait(requestID: secondRequest.requestID) }
        await Task.yield()
        registry.finished(
            secondItem, result: .completed(metrics: nil, noSpeech: false, replacementGeneration: .notOpened),
            isShutdownCancellation: false
        )
        if case .completed = try await second.value {} else {
            Issue.record("completion of another request resolved with the wrong outcome")
        }
        #expect(!(await probe.hasReturned()))

        registry.finished(
            ProcessingQueueItemSummary(
                requestID: firstRequest.requestID, sessionID: sessionID, kind: .replacement, holdReason: nil
            ),
            result: .completed(metrics: nil, noSpeech: false, replacementGeneration: .notOpened),
            isShutdownCancellation: false
        )
        if case .completed = try await first.value {} else {
            Issue.record("held request did not complete after resuming")
        }
        #expect(await probe.hasReturned())
    }

    @Test func shutdownSweepsQueuedWaitersButPreservesActiveAndReportedOutcomes() async throws {
        let registry = EngineCompletionRegistry()
        let pending = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        let held = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        let modelHeld = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        let active = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        let reported = PendingProcessing.finalize(sessionID: UUID(), metadataPolicy: .reject)
        var queue = SessionProcessingQueue()
        try queue.enqueue(pending)
        queue.hold(held, reason: .inference(.resourcePressure))
        queue.holdForModels(modelHeld)
        queue.begin(active)
        for request in [pending, held, modelHeld, active, reported] {
            registry.register(requestID: request.requestID, terminalReplyClaim: {})
        }
        let activeProbe = RPCCompletionProbe()
        let pendingWaiter = Task { try await registry.wait(requestID: pending.requestID) }
        let heldWaiter = Task { try await registry.wait(requestID: held.requestID) }
        let modelHeldWaiter = Task { try await registry.wait(requestID: modelHeld.requestID) }
        let activeWaiter = Task {
            let outcome = try await registry.wait(requestID: active.requestID)
            await activeProbe.markReturned()
            return outcome
        }
        await Task.yield()
        registry.finished(
            ProcessingQueueItemSummary(
                requestID: reported.requestID, sessionID: reported.sessionID, kind: .finalization, holdReason: nil
            ),
            result: .failed(
                message: "durable failure", metrics: nil, retained: nil, replacementGeneration: .notOpened
            ),
            isShutdownCancellation: false
        )

        registry.finishPendingAndHeldForShutdown(summaries: queue.summaries)
        registry.finishPendingAndHeldForShutdown(summaries: queue.summaries)
        if case .paused = try await pendingWaiter.value {} else { Issue.record("pending waiter not paused") }
        if case .paused = try await heldWaiter.value {} else { Issue.record("held waiter not paused") }
        if case .paused = try await modelHeldWaiter.value {} else { Issue.record("model-held waiter not paused") }
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await activeProbe.hasReturned()))

        registry.finishRemainingForShutdown()
        registry.finishRemainingForShutdown()
        if case .paused = try await activeWaiter.value {} else {
            Issue.record("timed-out active waiter was not resolved as paused")
        }
        if case .failed(let message) = try await registry.wait(requestID: reported.requestID) {
            #expect(message == "durable failure")
        } else {
            Issue.record("shutdown replaced an already reported durable failure")
        }
    }

    @Test(.timeLimit(.minutes(10)))
    fileprivate func shutdownDeadlineResolvesActiveReprocessWhilePreparationWaits() async throws {
        let gate = UncancellableResourceGate()
        let preparationGate = UncancellableResourceGate()
        let provider = ResourceGatedProvider(gate: gate, holdCall: 3)
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(
            root: root, provider: provider, shutdownPauseTimeout: .milliseconds(120)
        )
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let input = root.appending(path: "shutdown-held.wav")
        try Data("fake wav".utf8).write(to: input)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(input.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()

        let probe = RPCCompletionProbe()
        let reprocess = Task {
            let code: EngineErrorCode?
            do {
                _ = try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
                code = nil
            } catch let error as CommandFailure {
                code = error.failure.code
            } catch {
                code = nil
            }
            await probe.markReturned()
            return code
        }
        try await gate.waitUntilEntered()
        h.app.core.preparationTask = Task { try? await preparationGate.suspend() }
        try await preparationGate.waitUntilEntered()
        let shutdown = Task { try await h.call("shutdown") }
        while !h.app.core.isShuttingDown { await Task.yield() }

        #expect(await reprocess.value == .cancelled)
        #expect(await probe.hasReturned())
        await gate.release()
        await h.app.core.processingCoordinator.waitUntilIdle()
        await preparationGate.release()
        _ = try await shutdown.value
        _ = await h.exit()
    }

    @Test(.timeLimit(.minutes(10)))
    fileprivate func reprocessRPCRemainsPendingThroughAResourceHold() async throws {
        let gate = LifecycleContinuationGate()
        let provider = ResourceGatedProvider(gate: gate, holdCall: 3)
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root, provider: provider)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let input = root.appending(path: "reprocess-held.wav")
        try Data("fake wav".utf8).write(to: input)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(input.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()
        #expect(provider.base.calls.count("asr") == 2)

        let probe = RPCCompletionProbe()
        let rpc = Task {
            let result = try await h.call(
                "session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}"
            )
            await probe.markReturned()
            return result
        }
        try await gate.waitUntilEntered()
        h.resources.setSignal(.pressure)
        await gate.release()
        await h.app.core.processingCoordinator.waitUntilIdle()
        let held = try #require(h.app.core.processingQueue.summaries.first(where: {
            $0.sessionID == UUID(uuidString: imported.sessionID) && $0.kind == .replacement
        }))
        #expect(held.holdReason == .inference(.resourcePressure))
        let heldSessionID = try #require(UUID(uuidString: imported.sessionID))
        let heldSessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(
            sessionsRoot: h.paths.sessionsRoot, sessionID: heldSessionID
        )
        let generationID = try #require(try ProcessingMetadataStore(sessionURL: heldSessionURL).load()?.generationID)
        for _ in 0..<20 { await Task.yield() }
        #expect(!(await probe.hasReturned()))

        h.resources.setSignal(.healthy)
        await h.app.core.processingCoordinator.waitUntilIdle()
        guard case let .sessionReprocess(result) = try await rpc.value else {
            Issue.record("session.reprocess did not return its terminal wire reply")
            return
        }
        #expect(result.sessionID == imported.sessionID)
        #expect(await probe.hasReturned())
        #expect(h.app.core.processingQueue.summaries.isEmpty)
        let id = try #require(UUID(uuidString: imported.sessionID))
        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(
            sessionsRoot: h.paths.sessionsRoot, sessionID: id
        )
        #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.generationID == generationID)
        #expect(provider.base.calls.count("asr") == 4)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(10)))
    fileprivate func monitorFailureFinishesHeldReprocessRPCWithoutDroppingItsJob() async throws {
        let gate = LifecycleContinuationGate()
        let cleanupGate = UncancellableResourceGate(armed: false)
        let provider = ResourceGatedProvider(gate: gate, holdCall: 3, unloadGate: cleanupGate)
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = ApplicationHarness(root: root, provider: provider)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let input = root.appending(path: "monitor-failed-reprocess.wav")
        try Data("fake wav".utf8).write(to: input)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(input.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()
        await cleanupGate.arm()

        let rpc = Task {
            try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
        }
        try await gate.waitUntilEntered()
        h.resources.setSignal(.pressure)
        await gate.release()
        try await cleanupGate.waitUntilEntered()
        #expect(h.app.core.processingQueue.summaries.contains {
            $0.sessionID == UUID(uuidString: imported.sessionID) && $0.holdReason == .inference(.resourcePressure)
        })

        h.resources.setSignal(.healthy)
        let requeued = try #require(h.app.core.processingQueue.summaries.first(where: {
            $0.kind == .replacement && $0.sessionID == UUID(uuidString: imported.sessionID)
        }))
        #expect(requeued.holdReason == .inference(.resourcePressure))
        h.resources.setSignal(.monitorFailed("test"))
        do {
            _ = try await rpc.value
            Issue.record("monitor failure must terminate the held reprocess RPC")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .internalError)
            #expect(error.failure.recoveryAction == .restart)
            #expect(error.failure.message.contains("アプリを再起動してください"))
        }
        await cleanupGate.release()
        await h.app.core.processingCoordinator.waitUntilIdle()
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        #expect(h.app.core.processingQueue.summaries.filter {
            $0.sessionID == sessionID && $0.holdReason != nil
        }.count == 1)
        #expect(h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        do {
            _ = try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
            Issue.record("new reprocess requests must fail while the monitor remains failed")
        } catch let error as CommandFailure {
            #expect(error.failure.code == .busy)
            #expect(error.failure.message == "このセッションは処理待ち・保留中または実行中のため再処理できません")
        }
        #expect(h.app.core.processingQueue.summaries.filter {
            $0.sessionID == sessionID && $0.holdReason != nil
        }.count == 1)
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(10)))
    fileprivate func pausedReprocessRPCCompletesAtHoldPublicationBeforeCleanup() async throws {
        let inferenceGate = UncancellableResourceGate()
        let cleanupGate = UncancellableResourceGate(armed: false)
        let provider = ResourceGatedProvider(gate: inferenceGate, holdCall: 3, unloadGate: cleanupGate)
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { Task { await cleanupGate.releaseFromCleanup() } }
        let h = ApplicationHarness(root: root, provider: provider)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let input = root.appending(path: "paused-reprocess.wav")
        try Data("fake wav".utf8).write(to: input)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(input.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()
        await cleanupGate.arm()

        let probe = RPCCompletionProbe()
        let rpc = Task {
            let failure: EngineFailure?
            do {
                _ = try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
                failure = nil
            } catch let error as CommandFailure {
                failure = error.failure
            } catch {
                failure = nil
            }
            await probe.markReturned()
            return failure
        }
        try await inferenceGate.waitUntilEntered()
        h.resources.setSignal(.pressure)
        h.app.core.processingCoordinator.requestPause()
        await inferenceGate.release()
        try await cleanupGate.waitUntilEntered()
        for _ in 0..<20 { await Task.yield() }

        #expect(await probe.hasReturned())
        #expect(await rpc.value?.code == .cancelled)
        await cleanupGate.release()
        await h.app.core.processingCoordinator.waitUntilIdle()
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        #expect(h.app.core.processingQueue.held.contains {
            $0.sessionID == sessionID && $0.holdReason == .paused
        })
        #expect(h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(.timeLimit(.minutes(10)))
    fileprivate func monitorFailureBetweenPauseAndHoldAnswersRPCBeforeResourceCleanup() async throws {
        let inferenceGate = UncancellableResourceGate()
        let cleanupGate = UncancellableResourceGate(armed: false)
        let provider = ResourceGatedProvider(gate: inferenceGate, holdCall: 3, unloadGate: cleanupGate)
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { Task { await cleanupGate.releaseFromCleanup() } }
        let h = ApplicationHarness(root: root, provider: provider)
        h.start()
        try await h.hello()
        try await h.replaceSettings(engineTestSettings(), expectedRevision: nil)
        await h.awaitModels()
        let input = root.appending(path: "monitor-race-reprocess.wav")
        try Data("fake wav".utf8).write(to: input)
        guard case let .sessionImport(imported) = try await h.call(
            "session.import", payload: "{\"input_path\":\(String(decoding: try JSONEncoder().encode(input.path), as: UTF8.self))}"
        ) else {
            Issue.record("session.import did not return a session")
            return
        }
        _ = try await h.waitForSession(status: .finalized)
        await h.app.core.processingCoordinator.waitUntilIdle()
        await cleanupGate.arm()

        let probe = RPCCompletionProbe()
        let rpc = Task {
            let code: EngineErrorCode?
            do {
                _ = try await h.call("session.reprocess", payload: "{\"session_id\":\"\(imported.sessionID)\"}")
                code = nil
            } catch let error as CommandFailure {
                code = error.failure.code
            } catch {
                code = nil
            }
            await probe.markReturned()
            return code
        }
        try await inferenceGate.waitUntilEntered()
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        h.resources.setSignal(.pressure)
        await inferenceGate.release()
        try await h.sink.changes.wait("processor reports resource pressure before publishing its hold") {
            h.app.core.processingQueue.currentSessionID == sessionID
                && h.app.core.currentState().presentation.processingStatusText
                    == InferenceHoldReason.resourcePressure.finalizationExplanation
        }
        h.resources.setSignal(.monitorFailed("raced failure"))
        try await cleanupGate.waitUntilEntered()
        #expect(h.app.core.processingQueue.summaries.contains {
            $0.sessionID == sessionID && $0.holdReason == .inference(.monitorFailed)
        })
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.hasReturned())
        await cleanupGate.release()
        #expect(await rpc.value == .internalError)
        #expect(h.app.core.processingQueue.summaries.filter {
            $0.sessionID == sessionID && $0.holdReason != nil
        }.count == 1)
        #expect(h.app.core.processingQueue.claimedSessionIDs.contains(sessionID))
        #expect(try await h.shutdown() == .shutdownRequested)
    }

    @Test(arguments: Pressure.allCases, [false, true])
    fileprivate func finalizationPausesAndRecoversOnlyWhileRunning(_ pressure: Pressure, _ shutsDown: Bool) async throws {
        let gate = LifecycleContinuationGate(), resources = FakeResourceMonitor()
        let provider = ResourceGatedProvider(gate: gate, holdCall: 1), f = try ResourceFixture(inference: provider, resources: resources, shutdownPauseTimeout: .seconds(30))
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); await f.prepare()
        let input = f.root.appending(path: "import.wav"), bytes = Data("fake wav".utf8)
        try bytes.write(to: input)
        let imported = try await f.app.core.importSession(try EngineImportPayload(inputPath: input.path), context: f.context)
        try await gate.waitUntilEntered()
        #expect(provider.base.calls.count("asr") == 1)
        let id = try #require(UUID(uuidString: imported.sessionID))
        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: f.paths.sessionsRoot, sessionID: id)
        let store = ProcessingMetadataStore(sessionURL: sessionURL), generationID = try #require(try store.load()?.generationID)
        f.resources.setSignal(pressure.signal)
        #expect(f.app.core.currentState().presentation.processingStatusText == pressure.hold.finalizationExplanation + "（実行中の処理の終了待ち）")
        await gate.release(); await f.app.core.processingCoordinator.waitUntilIdle()
        let paused = try #require(try store.load())
        #expect(paused.state == .paused && paused.generationID == generationID && provider.base.calls.count("asr") == 1)
        #expect(f.app.core.processingQueue.summaries.contains {
            $0.sessionID == id && $0.holdReason == .inference(pressure.hold)
        })
        #expect(f.app.core.currentState().presentation.processingStatusText == pressure.hold.finalizationExplanation)
        #expect(provider.base.calls.count("asr.unload") > 0)
        let original = try SessionLayout(sessionURL: sessionURL).importedOriginalURL()
        #expect(try Data(contentsOf: original) == bytes)
        if shutsDown {
            try await f.shutdown(); f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let stopped = try #require(try store.load())
            #expect(provider.base.calls.count("asr") == 1 && stopped.state == .paused && stopped.generationID == generationID)
            #expect(try Data(contentsOf: original) == bytes)
        } else {
            f.resources.setSignal(.healthy); await f.app.core.processingCoordinator.waitUntilIdle()
            let completed = try #require(try store.load())
            #expect(completed.state == .complete && completed.generationID == generationID && provider.base.calls.count("asr") == 2)
            #expect(try Data(contentsOf: original) == bytes)
            try await f.shutdown()
        }
    }

    @Test(arguments: Pressure.allCases)
    fileprivate func pressureAtStopReleasesModelsOnceAndFinalizesAfterRecovery(_ pressure: Pressure) async throws {
        let provider = FakeInferenceProvider(), resources = FakeResourceMonitor()
        let f = try ResourceFixture(inference: provider, resources: resources, shutdownPauseTimeout: .seconds(30))
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.start(); await f.prepare()
        let recording = try await f.app.core.start(.init(source: .microphone, device: .default), context: f.context)
        let id = try #require(UUID(uuidString: recording.sessionID))
        try await #require(f.capture.session).appendSpeech(seconds: 2)
        let unloadsBefore = provider.calls.count("asr.unload")
        resources.setSignal(pressure.signal)
        _ = try await f.app.core.stop(recording, context: f.context)
        await f.app.core.processingCoordinator.waitUntilIdle()
        let held = try #require(f.app.core.processingQueue.summaries.first(where: {
            $0.sessionID == id && $0.holdReason == .inference(pressure.hold)
        }))
        #expect(held.kind == .finalization)
        #expect(provider.calls.count("asr.unload") - unloadsBefore == 1)
        resources.setSignal(.healthy)
        await f.app.core.processingCoordinator.waitUntilIdle()
        let sessionURL = try SessionDirectoryLocator(fileManager: .default).resolve(sessionsRoot: f.paths.sessionsRoot, sessionID: id)
        #expect(try ProcessingMetadataStore(sessionURL: sessionURL).load()?.state == .complete)
        try await f.shutdown()
    }
}
