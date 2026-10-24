import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

/// A failure raised by a platform adapter (capture, installed models) that already knows its wire error code.
public struct EngineAdapterError: Error, LocalizedError, Sendable, Equatable {
    public let code: EngineErrorCode
    public let message: String
    public let recoveryAction: EngineRecoveryAction
    public let details: [EngineErrorDetail]

    public init(code: EngineErrorCode, message: String, recoveryAction: EngineRecoveryAction, details: [EngineErrorDetail]) {
        self.code = code
        self.message = message
        self.recoveryAction = recoveryAction
        self.details = details
    }

    public var errorDescription: String? { message }

    /// A nonempty error detail for adapters that report native failures.
    public static func detail(domain: String, code: String, message: String) -> EngineErrorDetail {
        EngineFailures.detail(domain: domain, code: code, message: message)
    }

    public static func detail(for error: any Error) -> EngineErrorDetail {
        EngineFailures.detail(for: error)
    }
}

// MARK: Capture

public struct EngineCaptureCallbacks: Sendable {
    /// Capture failed after it started. The engine stops the recording and finalizes the saved audio.
    public let onFailure: @MainActor @Sendable (String) -> Void
    public let onWarning: @MainActor @Sendable (String) -> Void
    public let onDropouts: @MainActor @Sendable (UInt64) -> Void
    public let onSilenceChanged: @MainActor @Sendable (Bool) -> Void

    public init(
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.onFailure = onFailure
        self.onWarning = onWarning
        self.onDropouts = onDropouts
        self.onSilenceChanged = onSilenceChanged
    }
}

/// One running capture. It owns the durable audio writer of its session.
@MainActor
public protocol EngineCaptureSession: AnyObject {
    func committedCheckpoint() async throws -> AudioCheckpoint
    /// Stops native capture, then finishes the durable audio. Called once.
    func stop() async throws -> AudioCaptureStopResult
}

/// The platform's audio capture. The Windows engine supplies WASAPI; tests supply a file-backed fake.
@MainActor
public protocol EngineCaptureProviding {
    func devices(source: EngineSource) throws -> EngineDevicesResult
    /// Returns once capture delivers valid audio. A throw leaves no running capture.
    func startCapture(
        sessionID: UUID,
        sessionURL: URL,
        source: EngineSource,
        device: EngineDevice,
        callbacks: EngineCaptureCallbacks
    ) async throws -> any EngineCaptureSession
}

// MARK: Inference

public struct EngineInference: Sendable {
    public typealias LiveVADFactory = @Sendable (
        _ processingDirectory: URL,
        _ sessionURL: URL,
        _ initialCheckpoint: AudioCheckpoint,
        _ segmentationRunID: String
    ) throws -> any LiveVADProcessing

    public let engines: SessionProcessingEngines
    public let contentPriority: ContentPriorityAccess
    public let timelineBuilder: any ImportedAudioTimelineBuilding
    public let makeLiveVADSession: LiveVADFactory

    public init(
        engines: SessionProcessingEngines,
        contentPriority: ContentPriorityAccess,
        timelineBuilder: any ImportedAudioTimelineBuilding,
        makeLiveVADSession: @escaping LiveVADFactory
    ) {
        self.engines = engines
        self.contentPriority = contentPriority
        self.timelineBuilder = timelineBuilder
        self.makeLiveVADSession = makeLiveVADSession
    }
}

public struct EngineModelProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case validating
        case loading
    }

    public let stage: Stage
    public let completed: Int
    public let total: Int

    public init(stage: Stage, completed: Int, total: Int) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

/// The installed-model inference stack. The Host never imports ONNX or PortableRuntime; the Windows engine
/// composes `PortableRuntime` behind this protocol and tests compose deterministic fakes.
public protocol EngineInferenceProviding: Sendable {
    /// Verifies the installed models of the settings' profile and loads each once. Throws
    /// `EngineAdapterError` with `model_missing`, `model_corrupt` or `model_failure`. Never downloads.
    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws
    /// The engines of the profile. Models load on first use; a failure there fails the operation.
    func makeInference(settings: EngineSettings) throws -> EngineInference
    /// Returns current-process accounting shared by the process's `DecisionCoordinator`.
    func decisionUsage() async throws -> DecisionUsageSnapshot
    /// Returns the installed, validated clause-tagger identity after metadata validation and loading.
    /// This performs no inference or accounting and is independent of settings and preparation.
    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity
}
