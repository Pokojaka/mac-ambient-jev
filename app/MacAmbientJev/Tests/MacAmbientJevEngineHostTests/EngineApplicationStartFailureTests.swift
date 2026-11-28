import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPipeline

@testable import MacAmbientJevEngineHost

@MainActor
@Suite struct EngineApplicationStartFailureTests {
    private struct Fixture {
        let root: URL
        let app: EngineApplication
    }

    private func fixture(capture: any EngineCaptureProviding) throws -> Fixture {
        let root = try ApplicationHarness.makeRoot()
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4, resourceMonitor: FakeResourceMonitor(),
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20), timeZone: TimeZone(identifier: "Asia/Tokyo")!),
            capture: capture, inference: FakeInferenceProvider(), events: events
        )
        return Fixture(root: root, app: app)
    }

    private func typedFailure(
        sessionID: UUID,
        message: String,
        cleanupErrors: [EngineErrorDetail] = []
    ) -> EngineCommandError {
        EngineFailures.commandError(
            .diskSpace, message, stage: .capture, sessionID: sessionID,
            severity: .fatal, recoveryAction: .freeDiskSpace,
            details: [EngineFailures.detail(domain: "native", code: "E_STORAGE", message: "native storage detail")],
            cleanupErrors: cleanupErrors
        )
    }

    @Test func combinedStartFailureKeepsTypedFailureAndRecordsCleanupText() throws {
        let fixture = try fixture(capture: FakeCapture())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = UUID()
        let priorCleanup = EngineFailures.detail(domain: "previous", code: "cleanup", message: "prior cleanup")
        let original = typedFailure(sessionID: sessionID, message: "original", cleanupErrors: [priorCleanup])
        fixture.app.core.startAttempt = .init(
            source: .microphone, device: .default, sessionURL: nil, error: original
        )

        let combined = "original。cleanup"
        fixture.app.core.recordingStartDidFail(.failed(combined))

        let actual = try #require(fixture.app.core.startAttempt?.error)
        #expect(actual.code == original.code)
        #expect(actual.sessionID == original.sessionID)
        #expect(actual.severity == original.severity)
        #expect(actual.recoveryAction == original.recoveryAction)
        #expect(actual.details == original.details)
        #expect(actual.message == combined)
        #expect(actual.cleanupErrors == [
            priorCleanup,
            EngineFailures.detail(domain: "recording_start", code: "cleanup", message: combined)
        ])
    }

    @Test func unchangedStartFailureDoesNotInventCleanupError() throws {
        let fixture = try fixture(capture: FakeCapture())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = UUID()
        let original = typedFailure(sessionID: sessionID, message: "unchanged")
        fixture.app.core.startAttempt = .init(
            source: .microphone, device: .default, sessionURL: nil, error: original
        )

        fixture.app.core.recordingStartDidFail(.failed(original.message))

        #expect(fixture.app.core.startAttempt?.error == original)
    }

    @Test func cancellationKeepsTypedStartFailure() throws {
        let fixture = try fixture(capture: FakeCapture())
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let original = typedFailure(sessionID: UUID(), message: "typed failure")
        fixture.app.core.startAttempt = .init(
            source: .microphone, device: .default, sessionURL: nil, error: original
        )

        fixture.app.core.recordingStartDidFail(.cancelled)

        #expect(fixture.app.core.startAttempt?.error == original)
    }

    @Test func bootstrappedAudioCaptureErrorKeepsSessionAndUnderlyingDetail() async throws {
        let captureError = AudioCaptureEngineError.diskSpaceUnavailable("volume query failed")
        let fixture = try fixture(capture: FailingStartCapture(error: captureError))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = UUID()
        fixture.app.core.startAttempt = .init(
            source: .microphone, device: .default, sessionURL: nil, error: nil
        )
        _ = try fixture.app.core.bootstrapSession(sessionID: sessionID)
        do {
            try await fixture.app.core.startCapture(sessionID: sessionID, onFailure: { _ in })
            Issue.record("capture start should fail")
        } catch let error as AudioCaptureEngineError {
            #expect(error.localizedDescription == captureError.localizedDescription)
        }
        fixture.app.core.recordingStartDidFail(.failed(captureError.localizedDescription))

        let error = try #require(fixture.app.core.startAttempt?.error)
        #expect(error.code == .diskSpace)
        #expect(error.recoveryAction == .freeDiskSpace)
        #expect(error.message == captureError.localizedDescription)
        #expect(error.details.count == 1)
        #expect(error.details.first?.domain == "swift")
        #expect(error.details.first?.code == "AudioCaptureEngineError")
        #expect(error.details.first?.message == error.message)
        #expect(error.sessionID == EngineFailures.wireID(sessionID))
    }
    @Test(.timeLimit(.minutes(10)))
    func failedRecordingStartResumesUnclaimedModelHeldFinalization() async throws {
        let root = try ApplicationHarness.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepareGate = EngineApplicationTestGate()
        await prepareGate.arm()
        let provider = PreparationGatedProvider(gate: prepareGate)
        let startGate = EngineApplicationTestGate()
        await startGate.arm()
        defer { Task { await prepareGate.release(); await startGate.release() } }
        let capture = GatedFailingStartCapture(gate: startGate)
        let resources = FakeResourceMonitor()
        let transport = EngineTransport(source: ScriptedSource(), sink: ScriptedSink(), limits: testLimits())
        let events = EngineEventEmitter(transport: transport)
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4, resourceMonitor: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20),
                timeZone: TimeZone(identifier: "Asia/Tokyo")!
            ),
            capture: capture, inference: provider, events: events
        )
        app.start()
        await app.waitForStartupRecovery()
        let settingsContext = EngineRequestContext(requestID: try EngineID(1), events: events, terminalReplyClaim: {})
        let importContext = EngineRequestContext(requestID: try EngineID(2), events: events, terminalReplyClaim: {})
        let startContext = EngineRequestContext(requestID: try EngineID(3), events: events, terminalReplyClaim: {})
        _ = try await app.core.replace(
            .init(expectedRevision: nil, settings: engineTestSettings()), context: settingsContext
        )
        await prepareGate.waitUntilSuspended()

        let input = root.appending(path: "model-held-finalization.wav")
        try Data("fake wav".utf8).write(to: input)
        let imported = try await app.core.importSession(
            try EngineImportPayload(inputPath: input.path), context: importContext
        )
        await app.core.processingCoordinator.waitUntilIdle()
        let sessionID = try #require(UUID(uuidString: imported.sessionID))
        #expect(app.core.processingQueue.modelHeld.contains { $0.sessionID == sessionID })
        #expect(!app.core.processingQueue.claimedSessionIDs.contains(sessionID))

        let recordingStart = Task { @MainActor in
            try await app.core.start(
                EngineRecordingStartPayload(source: .microphone, device: .default), context: startContext
            )
        }
        await startGate.waitUntilSuspended()
        #expect(app.core.recording.phase == .starting)

        await prepareGate.release()
        await app.core.awaitModelPreparation()
        #expect(app.core.modelsPrepared)
        #expect(app.core.recording.phase == .starting)
        #expect(app.core.processingQueue.modelHeld.contains { $0.sessionID == sessionID })

        let completionEpoch = app.core.processingCompletionEpoch
        await startGate.release()
        do {
            _ = try await recordingStart.value
            Issue.record("capture startup should fail")
        } catch let error as EngineCommandError {
            #expect(error.code == .captureFailure)
        }
        #expect(app.core.recording.phase == .idle)
        await app.core.processingCoordinator.waitUntilIdle()
        #expect(app.core.processingCompletionEpoch == completionEpoch + 1)
        #expect(!app.core.processingQueue.containsProcessing(sessionID))
        try await app.core.shutdown(reason: .requested)
    }
}

@MainActor
private final class FailingStartCapture: EngineCaptureProviding {
    private let error: AudioCaptureEngineError

    init(error: AudioCaptureEngineError) {
        self.error = error
    }

    func devices(source: EngineSource) throws -> EngineDevicesResult {
        try EngineDevicesResult(
            source: source,
            devices: [try EngineDeviceInfo(id: "test-device", name: "Test device", isDefault: true)],
            defaultDeviceID: "test-device"
        )
    }

    func startCapture(
        sessionID: UUID,
        sessionURL: URL,
        source: EngineSource,
        device: EngineDevice,
        callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        throw error
    }
}

private final class PreparationGatedProvider: EngineInferenceProviding, @unchecked Sendable {
    private let base = FakeInferenceProvider()
    private let gate: EngineApplicationTestGate

    init(gate: EngineApplicationTestGate) {
        self.gate = gate
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        await gate.suspendIfArmed()
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
private final class GatedFailingStartCapture: EngineCaptureProviding {
    private let gate: EngineApplicationTestGate

    init(gate: EngineApplicationTestGate) {
        self.gate = gate
    }

    func devices(source: EngineSource) throws -> EngineDevicesResult {
        try EngineDevicesResult(
            source: source,
            devices: [try EngineDeviceInfo(id: "test-device", name: "Test device", isDefault: true)],
            defaultDeviceID: "test-device"
        )
    }

    func startCapture(
        sessionID: UUID,
        sessionURL: URL,
        source: EngineSource,
        device: EngineDevice,
        callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        await gate.suspendIfArmed()
        throw AudioCaptureEngineError.captureFailure("capture failed after start gate")
    }
}
