import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

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
        let resources = FakeResourceMonitor()
        let app = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: engineTestPaths(root: root), logicalCPUCount: 4,
                resourceMonitor: resources, memoryProber: resources,
                sleep: { try await Task.sleep(for: $0) }, shutdownPauseTimeout: .seconds(20)
            ),
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
