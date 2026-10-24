import Foundation
import MacAmbientJevEngineProtocol

public enum EngineShutdownReason: Equatable, Sendable {
    /// The client sent `shutdown`.
    case requested
    /// stdin reached EOF at a record boundary.
    case inputClosed
    /// stdin carried a framing or protocol violation, or a partial final line.
    case protocolError
    /// stdin could not be read.
    case inputFailed
    /// stdout failed: broken pipe, write error or the write deadline.
    case outputFailed
    /// Capture failed; the host must finish durable shutdown before exiting.
    case captureFailed
}

/// Emits unsolicited and request-correlated events. Replaceable events never suspend and may be coalesced
/// by the transport; `failure` is reliable.
public struct EngineEventEmitter: Sendable {
    private let transport: EngineTransport

    public init(transport: EngineTransport) {
        self.transport = transport
    }

    public func state(_ state: EngineState) throws {
        try transport.sendReplaceable(.state(state), requestID: nil)
    }

    public func progress(_ progress: EngineProgressPayload, requestID: EngineID?) throws {
        try transport.sendReplaceable(.progress(progress), requestID: requestID)
    }

    public func rows(_ rows: EngineRowsPayload) throws {
        try transport.sendReplaceable(.rows(rows), requestID: nil)
    }

    public func captureFailed(_ message: String) -> Void {
        transport.captureFailed(message)
    }

    /// A background failure that no request awaits.
    public func failure(_ failure: EngineFailure) async throws {
        try await transport.send(.error(failure), requestID: failure.requestID)
    }
}

public struct EngineRequestContext: Sendable {
    public let requestID: EngineID
    public let events: EngineEventEmitter

    public init(requestID: EngineID, events: EngineEventEmitter) {
        self.requestID = requestID
        self.events = events
    }
}

/// What a handler throws to fail its request with a specific wire error. Any other thrown error becomes
/// `internal_error`, and `CancellationError` becomes `cancelled`.
public struct EngineCommandError: Error, Sendable, Equatable {
    public let code: EngineErrorCode
    public let message: String
    public let stage: EngineStage
    public let sessionID: String?
    public let severity: EngineSeverity
    public let recoveryAction: EngineRecoveryAction
    public let details: [EngineErrorDetail]
    public let cleanupErrors: [EngineErrorDetail]

    public init(
        code: EngineErrorCode,
        message: String,
        stage: EngineStage,
        sessionID: String?,
        severity: EngineSeverity,
        recoveryAction: EngineRecoveryAction,
        details: [EngineErrorDetail],
        cleanupErrors: [EngineErrorDetail]
    ) throws {
        // Validate once here so the controller can build the wire failure without a second failure path.
        _ = try EngineFailure(
            code: code, message: message, stage: stage, requestID: nil, sessionID: sessionID,
            severity: severity, recoveryAction: recoveryAction, details: details, cleanupErrors: cleanupErrors
        )
        self.code = code
        self.message = message
        self.stage = stage
        self.sessionID = sessionID
        self.severity = severity
        self.recoveryAction = recoveryAction
        self.details = details
        self.cleanupErrors = cleanupErrors
    }

    func failure(requestID: EngineID?) -> EngineFailure {
        do {
            return try EngineFailure(
                code: code, message: message, stage: stage, requestID: requestID, sessionID: sessionID,
                severity: severity, recoveryAction: recoveryAction, details: details, cleanupErrors: cleanupErrors
            )
        } catch {
            preconditionFailure("EngineCommandError was validated at init: \(error)")
        }
    }
}

@MainActor
public protocol EngineStateHandling {
    /// The payload of the unsolicited `ready` event, produced before the first request is read.
    func ready() async throws -> EngineReadyPayload
    /// The `hello` result. It follows `ready`.
    func hello() async throws -> EngineReadyPayload
    /// Called synchronously only after the successful terminal `hello` reply has been queued on reliable FIFO stdout.
    /// Implementations may begin unsolicited app state, error, and rows events only after this hook.
    func helloDidComplete()
    func state() async throws -> EngineState
    func diagnostics(context: EngineRequestContext) async throws -> EngineDiagnosticsResult
}

@MainActor
public protocol EngineRecordingHandling {
    func devices(_ payload: EngineDevicesListPayload, context: EngineRequestContext) async throws -> EngineDevicesResult
    func start(_ payload: EngineRecordingStartPayload, context: EngineRequestContext) async throws -> EngineSessionPayload
    func stop(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload
}

@MainActor
public protocol EngineSessionHandling {
    func importSession(_ payload: EngineImportPayload, context: EngineRequestContext) async throws -> EngineSessionPayload
    func reprocess(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload
    func retryDecisions(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload
    func inspect(_ payload: EngineSessionInspectPayload, context: EngineRequestContext) async throws -> EngineSessionSummary
    func list(_ payload: EngineSessionListPayload, context: EngineRequestContext) async throws -> EngineSessionListResult
    func export(_ payload: EngineExportPayload, context: EngineRequestContext) async throws -> EngineExportResult
}

@MainActor
public protocol EngineTranscriptHandling {
    func read(_ payload: EngineTranscriptReadPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage
    func watch(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage
}

@MainActor
public protocol EngineSettingsHandling {
    func get(context: EngineRequestContext) async throws -> EngineSettingsResult
    func replace(_ payload: EngineSettingsReplacePayload, context: EngineRequestContext) async throws -> EngineSettingsResult
}

@MainActor
public protocol EngineModelsHandling {
    func prepare(context: EngineRequestContext) async throws
    func inspect(context: EngineRequestContext) async throws -> EngineModelsInspection
}

@MainActor
public protocol EngineShutdownHandling {
    /// Stops capture durably, cancels further inference safely and releases resources. Called exactly once.
    func shutdown(reason: EngineShutdownReason) async throws
}

public struct EngineHandlers {
    public let state: any EngineStateHandling
    public let recording: any EngineRecordingHandling
    public let sessions: any EngineSessionHandling
    public let transcript: any EngineTranscriptHandling
    public let settings: any EngineSettingsHandling
    public let models: any EngineModelsHandling
    public let shutdown: any EngineShutdownHandling

    public init(
        state: any EngineStateHandling,
        recording: any EngineRecordingHandling,
        sessions: any EngineSessionHandling,
        transcript: any EngineTranscriptHandling,
        settings: any EngineSettingsHandling,
        models: any EngineModelsHandling,
        shutdown: any EngineShutdownHandling
    ) {
        self.state = state
        self.recording = recording
        self.sessions = sessions
        self.transcript = transcript
        self.settings = settings
        self.models = models
        self.shutdown = shutdown
    }
}

/// `settings.get` / `settings.replace` backed by the job 5 `EngineSettingsStore`.
@MainActor
public struct EngineSettingsStoreHandler: EngineSettingsHandling {
    private let store: EngineSettingsStore
    private let rejectsReplacement: @MainActor (_ current: EngineSettings?, _ proposed: EngineSettings) -> Bool

    /// `rejectsReplacement` decides which replacements conflict with running work; `current` is nil while
    /// no valid settings exist (first setup or repair).
    public init(
        store: EngineSettingsStore,
        rejectsReplacement: @escaping @MainActor (_ current: EngineSettings?, _ proposed: EngineSettings) -> Bool
    ) {
        self.store = store
        self.rejectsReplacement = rejectsReplacement
    }

    public func get(context: EngineRequestContext) async throws -> EngineSettingsResult {
        do {
            return try store.load()
        } catch let error as EngineSettingsError {
            throw try Self.commandError(error)
        }
    }

    public func replace(_ payload: EngineSettingsReplacePayload, context: EngineRequestContext) async throws -> EngineSettingsResult {
        do {
            let current: EngineSettings?
            do {
                current = try store.load().settings
            } catch EngineSettingsError.required {
                current = nil
            } catch EngineSettingsError.corrupt {
                current = nil
            }
            if rejectsReplacement(current, payload.settings) {
                throw try EngineCommandError(
                    code: .busy,
                    message: "録音または処理の実行中のため、この設定変更は適用できません",
                    stage: .settings,
                    sessionID: nil,
                    severity: .error,
                    recoveryAction: .retry,
                    details: [],
                    cleanupErrors: []
                )
            }
            return try store.replace(expectedRevision: payload.expectedRevision, settings: payload.settings)
        } catch let error as EngineSettingsError {
            throw try Self.commandError(error)
        }
    }

    private static func commandError(_ error: EngineSettingsError) throws -> EngineCommandError {
        try EngineCommandError(
            code: error.errorCode,
            message: error.errorDescription ?? String(describing: error),
            stage: .settings,
            sessionID: nil,
            severity: .error,
            recoveryAction: error.recoveryAction,
            details: [],
            cleanupErrors: []
        )
    }
}
