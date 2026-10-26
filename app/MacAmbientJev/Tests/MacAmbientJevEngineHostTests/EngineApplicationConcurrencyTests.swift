import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

@testable import MacAmbientJevEngineHost

private actor PreparationGate {
    private var didEnter = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var didRelease = false

    func suspend() async {
        didEnter = true
        let waiters = enteredWaiters
        enteredWaiters = []
        for waiter in waiters { waiter.resume() }

        await withCheckedContinuation { continuation in
            if didRelease {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        didRelease = true
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private enum GatedMutationFailure: Error {
    case expected
}

private actor StartupCancellationProbe {
    private var thermalWasCritical: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func waitForCancellation(thermalMonitor: WindowsNoThermalMonitoring) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    self.cancellationContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }

        let wasCritical = thermalMonitor.isCritical
        thermalWasCritical = wasCritical
        let waiter = waiter
        self.waiter = nil
        waiter?.resume(returning: wasCritical)
    }

    private func observeCancellation() {
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        continuation?.resume()
    }

    func waitUntilObserved() async -> Bool {
        if let thermalWasCritical { return thermalWasCritical }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class CancellationOnSecondReadTimelineAudio: TimelineAudioReading, @unchecked Sendable {
    let info: TimelineAudioInfo
    private let samples: [Float]
    private let cancelsOnSecondRead: Bool
    private let lock = NSLock()
    private var recordedRequests: [Range<Int64>] = []

    init(samples: [Float], cancelsOnSecondRead: Bool) throws {
        self.samples = samples
        self.cancelsOnSecondRead = cancelsOnSecondRead
        info = try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: [])
    }

    var requests: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        lock.lock()
        recordedRequests.append(frameRange)
        let shouldCancel = cancelsOnSecondRead && recordedRequests.count == 2
        lock.unlock()
        if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
        return Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
    }

    func validateAudio() throws {}
}

private struct MultipleSegmentLiveVAD: LiveVADProcessing {
    let segmentationRunID: String

    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        LiveVADProgress(emittedSegments: [], totalSegmentCount: 0, committedFrames: checkpoint.committedFrames, micSpeechLevels: [])
    }

    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress {
        let midpoint = checkpoint.committedFrames / 2
        guard midpoint > 0 else {
            return LiveVADProgress(emittedSegments: [], totalSegmentCount: 0, committedFrames: 0, micSpeechLevels: [])
        }
        let segments = [
            SegmentReference(segmentationRunID: segmentationRunID, segmentID: "live_segment_1", startFrame: 0, endFrame: midpoint),
            SegmentReference(
                segmentationRunID: segmentationRunID, segmentID: "live_segment_2",
                startFrame: midpoint, endFrame: checkpoint.committedFrames
            ),
        ]
        return LiveVADProgress(
            emittedSegments: segments, totalSegmentCount: segments.count,
            committedFrames: checkpoint.committedFrames, micSpeechLevels: []
        )
    }
}

private struct GatedASREngine: ASREngine {
    let gate: PreparationGate
    let calls: CallCounter
    let provenance = RunProvenance(engine: "host-test-gated-asr", model: nil, version: "test", configuration: [:])

    func prepare() async throws {}

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls.increment("asr")
        await gate.suspend()
        return ASRResult(text: "日本語のテストです。", detectedLanguage: "ja")
    }

    func unload() async {}
}

private final class GatedASRInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    let gate: PreparationGate
    let calls: CallCounter
    let usageCounter = DecisionUsageCounter()
    private let inspectionProvider = FakeInferenceProvider()

    init(gate: PreparationGate, calls: CallCounter) {
        self.gate = gate
        self.calls = calls
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        onProgress(EngineModelProgress(stage: .validating, completed: 1, total: 1))
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        try await inspectionProvider.inspectClauseTagger()
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        return EngineInference(
            engines: SessionProcessingEngines(
                asr: GatedASREngine(gate: gate, calls: calls),
                diarization: FakeDiarizer(calls: calls),
                finalTranscriptVAD: FakeFinalVAD()
            ),
            contentPriority: .disabled,
            timelineBuilder: FakeTimelineBuilder(),
            makeLiveVADSession: { _, _, _, runID in MultipleSegmentLiveVAD(segmentationRunID: runID) }
        )
    }
}

private final class GatedInferenceProvider: EngineInferenceProviding, @unchecked Sendable {
    let gate: PreparationGate
    private let base = FakeInferenceProvider()

    init(gate: PreparationGate) {
        self.gate = gate
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        await gate.suspend()
        try await base.prepare(settings: settings, onProgress: onProgress)
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        try await base.decisionUsage()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        try await base.inspectClauseTagger()
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        try base.makeInference(settings: settings)
    }
}

@MainActor
@Suite struct EngineApplicationConcurrencyTests {
    private struct Fixture {
        let root: URL
        let app: EngineApplication
        let gate: PreparationGate
        let context: EngineRequestContext
    }

    private struct ASRShutdownFixture {
        let root: URL
        let app: EngineApplication
        let capture: FakeCapture
        let gate: PreparationGate
        let calls: CallCounter
        let context: EngineRequestContext
    }

    private func fixture() throws -> Fixture {
        let root = try ApplicationHarness.makeRoot()
        let gate = PreparationGate()
        let source = ScriptedSource()
        let sink = ScriptedSink()
        let transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)
            ),
            capture: FakeCapture(), inference: GatedInferenceProvider(gate: gate),
            events: EngineEventEmitter(transport: transport)
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: EngineEventEmitter(transport: transport))
        return Fixture(root: root, app: app, gate: gate, context: context)
    }

    private func gatedASRFixture() throws -> ASRShutdownFixture {
        let root = try ApplicationHarness.makeRoot()
        let gate = PreparationGate()
        let calls = CallCounter()
        let source = ScriptedSource()
        let sink = ScriptedSink()
        let transport = EngineTransport(source: source, sink: sink, limits: testLimits())
        let capture = FakeCapture()
        let events = EngineEventEmitter(transport: transport)
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(30)
            ),
            capture: capture,
            inference: GatedASRInferenceProvider(gate: gate, calls: calls),
            events: events
        )
        let context = EngineRequestContext(requestID: try EngineID(1), events: events)
        return ASRShutdownFixture(root: root, app: app, capture: capture, gate: gate, calls: calls, context: context)
    }

    private func prepareForRecording(_ fixture: ASRShutdownFixture) async throws {
        let settings = try engineTestSettings()
        _ = try await fixture.app.core.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings), context: fixture.context
        )
        try await fixture.app.core.prepare(context: fixture.context)
        while fixture.app.core.processingCoordinator.isDraining { await Task.yield() }
    }

    private func configureSettings(for fixture: Fixture) async throws -> EngineSettings {
        let settings = try engineTestSettings()
        _ = try await fixture.app.core.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings), context: fixture.context
        )
        return settings
    }

    @Test func profileReplacementIsBusyDuringInitialModelPreparation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try await configureSettings(for: fixture)
        let prepareTask = Task { @MainActor in try await fixture.app.core.prepare(context: fixture.context) }
        await fixture.gate.waitUntilEntered()

        let proposed = try EngineSettings(
            schemaVersion: 1, source: .microphone, device: .default, asrSize: .large, executionProvider: .cpu,
            threads: 1, lowHeat: false, decisionsEnabled: false, automaticExport: false, exportDestinationPath: nil
        )
        let replacement = EngineSettingsReplacePayload(expectedRevision: try EngineID(1), settings: proposed)
        do {
            _ = try await fixture.app.core.replace(replacement, context: fixture.context)
            Issue.record("settings.replace should be busy while models are preparing")
        } catch let error as EngineCommandError {
            #expect(error.code == .busy)
        } catch {
            Issue.record("unexpected settings replacement error: \(error)")
        }

        let saved = try fixture.app.core.settingsStore.load()
        #expect(saved.revision.value == 1)
        #expect(saved.settings == original)

        await fixture.gate.release()
        try await prepareTask.value
    }

    @Test func preparationResumedAfterShutdownIsCancelledWithoutInstallingProcessor() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await configureSettings(for: fixture)
        let prepareTask = Task { @MainActor in try await fixture.app.core.prepare(context: fixture.context) }
        await fixture.gate.waitUntilEntered()

        try await fixture.app.core.shutdown(reason: .requested)
        #expect(fixture.app.core.isShuttingDown)
        await fixture.gate.release()

        do {
            try await prepareTask.value
            Issue.record("model preparation should be cancelled after shutdown")
        } catch let error as EngineCommandError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("unexpected model preparation error: \(error)")
        }

        #expect(fixture.app.core.currentState().setup == .modelsRequired)
        #expect(!fixture.app.core.gateway.isInstalled)
    }

    @Test func shutdownWaitsForStartupRecoveryBeforeReleasingRootLock() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rootLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        fixture.app.core.startupTask = Task { await fixture.gate.suspend() }
        await fixture.gate.waitUntilEntered()

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .requested)
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed while waiting for startup recovery: \(error)")
            }
        }
        while !fixture.app.core.isShuttingDown { await Task.yield() }

        #expect(!shutdownReturned)
        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("root lock should remain held while startup recovery is gated")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error: \(error)")
        }

        await fixture.gate.release()
        await shutdownTask.value
        #expect(shutdownReturned)
        rootLock.release()
        let reacquiredLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        reacquiredLock.release()
    }

    @Test func shutdownCancelsStartupWithoutThermalPauseAndLeavesRootLockToOwner() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rootLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        let probe = StartupCancellationProbe()
        fixture.app.core.startupTask = Task {
            await probe.waitForCancellation(thermalMonitor: fixture.app.core.thermalMonitor)
        }

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .requested)
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed while cancelling startup recovery: \(error)")
            }
        }

        let thermalWasCriticalOnCancellation = await probe.waitUntilObserved()
        #expect(!thermalWasCriticalOnCancellation)
        await shutdownTask.value
        #expect(shutdownReturned)
        #expect(!fixture.app.core.thermalMonitor.isCritical)
        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("shutdown must not release the process-owned root lock")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error after shutdown: \(error)")
        }

        rootLock.release()
        let reacquiredLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        reacquiredLock.release()
    }

    @Test func shutdownCancelsStoppedRecordingLiveASRWithoutDrainingItsBacklog() async throws {
        let fixture = try gatedASRFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await prepareForRecording(fixture)

        let recording = try await fixture.app.core.start(
            EngineRecordingStartPayload(source: .microphone, device: .default), context: fixture.context
        )
        let sessionID = try #require(UUID(uuidString: recording.sessionID))
        try await fixture.capture.session?.appendSpeech(seconds: 2)
        _ = try await fixture.app.core.stop(recording, context: fixture.context)
        await fixture.gate.waitUntilEntered()

        #expect(fixture.calls.count("asr") == 1)
        #expect(fixture.app.core.processingQueue.sessionIDs.contains(sessionID))

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .requested)
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed while cancelling live ASR: \(error)")
            }
        }
        while !fixture.app.core.isShuttingDown { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!shutdownReturned)

        await fixture.gate.release()
        await shutdownTask.value
        #expect(shutdownReturned)
        #expect(fixture.calls.count("asr") == 1)
        #expect(!fixture.app.core.processingCoordinator.isDraining)
        #expect(fixture.app.core.processingQueue.sessionIDs.contains(sessionID))
        #expect(fixture.app.core.liveCoordinator.isASRIdle)
    }

    @Test func shutdownTearsDownLiveASRForFatalCaptureFailureAfterRecordingFinishes() async throws {
        let fixture = try gatedASRFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await prepareForRecording(fixture)

        let recording = try await fixture.app.core.start(
            EngineRecordingStartPayload(source: .microphone, device: .default), context: fixture.context
        )
        let sessionID = try #require(UUID(uuidString: recording.sessionID))
        try await fixture.capture.session?.appendSpeech(seconds: 2)
        let onFailure = try #require(fixture.capture.callbacks?.onFailure)
        onFailure("test capture fault")
        await fixture.gate.waitUntilEntered()
        await fixture.app.core.stopTask?.value

        #expect(fixture.app.core.recording.phase == .idle)
        #expect(fixture.app.core.processingQueue.pending.contains { $0.sessionID == sessionID })
        #expect(fixture.calls.count("asr") == 1)

        var shutdownReturned = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .captureFailed)
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed after fatal capture failure: \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!shutdownReturned)

        await fixture.gate.release()
        await shutdownTask.value
        #expect(shutdownReturned)
        #expect(fixture.calls.count("asr") == 1)
        #expect(!fixture.app.core.processingCoordinator.isDraining)
        #expect(fixture.app.core.processingQueue.sessionIDs.contains(sessionID))
        #expect(fixture.app.core.liveCoordinator.isASRIdle)
    }

    @Test func shutdownWaitsForCancelledMutationAndItsFilesystemCleanup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rootLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        let gate = PreparationGate()
        let mutationURL = fixture.root.appending(path: "mutation-marker")
        let mutationCompleted = LockedBox(false)
        let mutationTask = Task { @MainActor in
            try await fixture.app.core.performMutation {
                defer { try? FileManager.default.removeItem(at: mutationURL) }
                await gate.suspend()
                try Data("mutation completed".utf8).write(to: mutationURL)
                mutationCompleted.set(true)
            }
        }
        await gate.waitUntilEntered()
        mutationTask.cancel()
        #expect(mutationTask.isCancelled)
        #expect(fixture.app.core.mutationTasks.count == 1)

        var shutdownReturned = false
        var shutdownObservedMutation = false
        var shutdownObservedCleanup = false
        var shutdownObservedEmptyRegistry = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .requested)
                shutdownObservedMutation = mutationCompleted.get()
                shutdownObservedCleanup = !FileManager.default.fileExists(atPath: mutationURL.path)
                shutdownObservedEmptyRegistry = fixture.app.core.mutationTasks.isEmpty
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed while waiting for the cancelled mutation: \(error)")
            }
        }
        while !fixture.app.core.isShuttingDown { await Task.yield() }

        #expect(fixture.app.core.mutationTasks.count == 1)
        #expect(!shutdownReturned)
        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("root lock should remain held while the mutation is gated")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error during mutation shutdown: \(error)")
        }

        await gate.release()
        await shutdownTask.value
        #expect(shutdownReturned)
        #expect(shutdownObservedMutation)
        #expect(shutdownObservedCleanup)
        #expect(shutdownObservedEmptyRegistry)
        do {
            try await mutationTask.value
        } catch {
            Issue.record("cancelled mutation caller failed after the operation completed: \(error)")
        }

        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("shutdown must leave the process-owned root lock to its owner")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error after mutation shutdown: \(error)")
        }
        rootLock.release()
        let reacquiredLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        reacquiredLock.release()
    }

    @Test func shutdownWaitsForThrowingMutationCleanup() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rootLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        let gate = PreparationGate()
        let mutationURL = fixture.root.appending(path: "throwing-mutation-marker")
        let mutationCompleted = LockedBox(false)
        let callerObservedFailure = LockedBox(false)
        let mutationTask = Task { @MainActor in
            do {
                try await fixture.app.core.performMutation {
                    defer { try? FileManager.default.removeItem(at: mutationURL) }
                    await gate.suspend()
                    try Data("mutation before throw".utf8).write(to: mutationURL)
                    mutationCompleted.set(true)
                    throw GatedMutationFailure.expected
                }
                Issue.record("the gated mutation should throw")
            } catch GatedMutationFailure.expected {
                callerObservedFailure.set(true)
            } catch {
                Issue.record("unexpected gated mutation error: \(error)")
            }
        }
        await gate.waitUntilEntered()
        mutationTask.cancel()

        var shutdownReturned = false
        var shutdownObservedMutation = false
        var shutdownObservedCleanup = false
        var shutdownObservedEmptyRegistry = false
        let shutdownTask = Task { @MainActor in
            do {
                try await fixture.app.core.shutdown(reason: .requested)
                shutdownObservedMutation = mutationCompleted.get()
                shutdownObservedCleanup = !FileManager.default.fileExists(atPath: mutationURL.path)
                shutdownObservedEmptyRegistry = fixture.app.core.mutationTasks.isEmpty
                shutdownReturned = true
            } catch {
                Issue.record("shutdown failed while waiting for the throwing mutation: \(error)")
            }
        }
        while !fixture.app.core.isShuttingDown { await Task.yield() }

        #expect(fixture.app.core.mutationTasks.count == 1)
        #expect(!shutdownReturned)
        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("root lock should remain held while the throwing mutation is gated")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error during throwing mutation shutdown: \(error)")
        }

        await gate.release()
        await shutdownTask.value
        #expect(shutdownReturned)
        #expect(shutdownObservedMutation)
        #expect(shutdownObservedCleanup)
        #expect(shutdownObservedEmptyRegistry)
        await mutationTask.value
        #expect(callerObservedFailure.get())
        do {
            let concurrentLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
            concurrentLock.release()
            Issue.record("shutdown must leave the process-owned root lock to its owner")
        } catch let error as ApplicationRootLockError {
            #expect(error == .alreadyRunning(path: rootLock.lockURL.path))
        } catch {
            Issue.record("unexpected root lock error after throwing mutation shutdown: \(error)")
        }
        rootLock.release()
        let reacquiredLock = try ApplicationRootLock.acquire(paths: fixture.app.core.paths)
        reacquiredLock.release()
    }

    @Test func performMutationRejectsWorkAfterShutdown() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.app.core.shutdown(reason: .requested)
        let closureRan = LockedBox(false)

        do {
            try await fixture.app.core.performMutation {
                closureRan.set(true)
            }
            Issue.record("performMutation should reject work after shutdown")
        } catch let error as EngineCommandError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("unexpected post-shutdown mutation error: \(error)")
        }
        #expect(!closureRan.get())
        #expect(fixture.app.core.mutationTasks.isEmpty)
    }

    @Test func pausedAutoExportDoesNotReportMissingDestinationOrStartMutation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let settings = try engineTestSettings(automaticExport: true, exportPath: nil)
        _ = try await fixture.app.core.replace(
            EngineSettingsReplacePayload(expectedRevision: nil, settings: settings), context: fixture.context
        )

        #expect(fixture.app.core.pausesProcessing)
        #expect(fixture.app.core.failures.isEmpty)
        #expect(fixture.app.core.mutationTasks.isEmpty)
        await fixture.app.core.autoExportIfEnabled(sessionID: UUID())
        #expect(fixture.app.core.failures.isEmpty)
        #expect(fixture.app.core.mutationTasks.isEmpty)
    }

    @Test func recordingFLACStopsReadingAtCancellationBoundaryAndCanBeRetried() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cancelledOutput = root.appending(path: "cancelled.flac")
        let completedOutput = root.appending(path: "completed.flac")
        let samples: [Float] = (0..<(3 * 4_096 + 17)).map { index -> Float in
            Float((index % 101) - 50) / 64
        }
        let cancelledReader = try CancellationOnSecondReadTimelineAudio(samples: samples, cancelsOnSecondRead: true)
        let cancelledTask = Task.detached(executorPreference: BlockingIOExecutor.shared) {
            try RecordingFLAC.write(reader: cancelledReader, to: cancelledOutput, sessionURL: root)
        }

        do {
            try await cancelledTask.value
            Issue.record("FLAC encoding should stop after the reader cancels its task")
        } catch is CancellationError {
        }
        let cancelledReadCount: Int = cancelledReader.requests.count
        let completeReadCount: Int = (samples.count + 4_095) / 4_096
        #expect(cancelledReadCount == 2)
        #expect(cancelledReadCount < completeReadCount)

        try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
            let completeReader = try CancellationOnSecondReadTimelineAudio(samples: samples, cancelsOnSecondRead: false)
            try RecordingFLAC.write(reader: completeReader, to: completedOutput, sessionURL: root)
            let decoded = try FLACTimelineReader(url: completedOutput, info: completeReader.info, sessionURL: root)
            try decoded.validateAudio(against: completeReader)
        }.value
    }
}
