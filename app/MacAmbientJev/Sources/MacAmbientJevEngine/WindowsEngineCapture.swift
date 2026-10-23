import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevWindowsSupport

/// WASAPI capture for the engine: one `WindowsCaptureSource` per recording, writing the session's durable audio.
@MainActor
final class WindowsEngineCapture: EngineCaptureProviding {
    /// The same chunk length the Mac capture engine uses.
    static let chunkDurationSeconds = 5.0

    private let factory: any WindowsCaptureSourceFactory

    init(factory: any WindowsCaptureSourceFactory) {
        self.factory = factory
    }

    func devices(source: EngineSource) throws -> EngineDevicesResult {
        let endpoints: [WindowsCaptureEndpoint]
        do {
            endpoints = try factory.devices(source: Self.captureSource(source))
        } catch {
            throw EngineAdapterError(
                code: .deviceFailure, message: "録音デバイスを列挙できません: \(error.localizedDescription)",
                recoveryAction: .retry, details: [EngineAdapterError.detail(for: error)]
            )
        }
        return try EngineDevicesResult(
            source: source,
            devices: try endpoints.map { try EngineDeviceInfo(id: $0.id, name: $0.name, isDefault: $0.isDefault) },
            defaultDeviceID: endpoints.first(where: \.isDefault)?.id
        )
    }

    func startCapture(
        sessionID: UUID,
        sessionURL: URL,
        source: EngineSource,
        device: EngineDevice,
        callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession {
        let writer = try DurableAudioWriter(
            directory: SessionLayout(sessionURL: sessionURL).processingDirectory,
            chunkDurationSeconds: Self.chunkDurationSeconds,
            sessionURL: sessionURL
        )
        let selection: WindowsCaptureDeviceSelection
        switch device {
        case .default: selection = .systemDefault
        case let .id(id): selection = .endpointID(id)
        }
        let capture = WindowsCaptureSource(
            source: Self.captureSource(source),
            device: selection,
            directory: sessionURL,
            writer: writer,
            factory: factory,
            diskSpace: WindowsCaptureDiskSpaceProvider(),
            power: WindowsRecordingPowerProvider(),
            clock: SystemCaptureClock(),
            qpc100ns: { try WindowsCaptureQPCClock.now100ns() },
            onWarning: callbacks.onWarning,
            onFailure: callbacks.onFailure,
            onSilenceChanged: callbacks.onSilenceChanged
        )
        try await capture.start()
        return WindowsEngineCaptureSession(capture: capture)
    }

    static func captureSource(_ source: EngineSource) -> CaptureSource {
        switch source {
        case .microphone: .microphone
        case .systemAudio: .systemAudio
        }
    }
}

@MainActor
final class WindowsEngineCaptureSession: EngineCaptureSession {
    private let capture: WindowsCaptureSource

    init(capture: WindowsCaptureSource) {
        self.capture = capture
    }

    func committedCheckpoint() async throws -> AudioCheckpoint {
        try await capture.committedSnapshot()
    }

    func stop() async throws -> AudioCaptureStopResult {
        try Self.stopResult(await capture.stop())
    }

    static func stopResult(_ result: WindowsCaptureStopResult) throws -> AudioCaptureStopResult {
        guard let checkpoint = result.checkpoint else {
            throw EngineAdapterError(
                code: .captureFailure,
                message: "録音の停止結果に音声チェックポイントがありません: \(result.errors.joined(separator: "; "))",
                recoveryAction: .inspectSession, details: result.errors.map {
                    EngineAdapterError.detail(domain: "capture", code: "stop", message: $0)
                }
            )
        }
        // A writer that failed to finish leaves only the healthy durable prefix; any other error is a cleanup
        // failure of a recording that was saved whole.
        let joined = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        if result.healthyPrefixOnly,
           !result.errors.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw EngineAdapterError(
                code: .captureFailure,
                message: "録音の停止結果で保存済み音声の失敗理由がありません",
                recoveryAction: .inspectSession, details: []
            )
        }
        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: checkpoint.gapEvents.contains { $0.reason == .overflow },
            dropoutCount: UInt64(checkpoint.gapEvents.count),
            gapCount: checkpoint.gapEvents.count,
            totalGapFrames: checkpoint.gapEvents.reduce(0) { $0 + $1.frameCount },
            sleepAssertionHeld: false,
            writerFailure: result.healthyPrefixOnly ? joined : nil,
            systemAudioReleaseFailure: result.healthyPrefixOnly ? nil : joined
        )
    }
}
