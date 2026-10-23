import Foundation
import MacAmbientJevEngineProtocol

/// Builders for the wire failures the application raises. Every text field is nonempty by construction.
enum EngineFailures {
    static func detail(domain: String, code: String, message: String, path: String? = nil) -> EngineErrorDetail {
        do {
            return try EngineErrorDetail(
                domain: domain, code: code, message: nonempty(message), path: path.flatMap { $0.isEmpty ? nil : $0 }, deviceID: nil
            )
        } catch {
            preconditionFailure("error detail fields are nonempty: \(error)")
        }
    }

    static func detail(for error: any Error) -> EngineErrorDetail {
        detail(domain: "swift", code: String(describing: type(of: error)), message: error.localizedDescription)
    }

    static func nonempty(_ text: String) -> String {
        text.isEmpty ? "(empty)" : text
    }

    static func failure(
        code: EngineErrorCode,
        message: String,
        stage: EngineStage,
        sessionID: UUID?,
        severity: EngineSeverity,
        recoveryAction: EngineRecoveryAction,
        details: [EngineErrorDetail] = [],
        cleanupErrors: [EngineErrorDetail] = []
    ) -> EngineFailure {
        do {
            return try EngineFailure(
                code: code, message: nonempty(message), stage: stage, requestID: nil,
                sessionID: sessionID.map(wireID), severity: severity, recoveryAction: recoveryAction,
                details: details, cleanupErrors: cleanupErrors
            )
        } catch {
            preconditionFailure("failure fields are nonempty: \(error)")
        }
    }

    static func commandError(
        _ code: EngineErrorCode,
        _ message: String,
        stage: EngineStage,
        sessionID: UUID? = nil,
        severity: EngineSeverity = .error,
        recoveryAction: EngineRecoveryAction = .none,
        details: [EngineErrorDetail] = [],
        cleanupErrors: [EngineErrorDetail] = []
    ) -> EngineCommandError {
        do {
            return try EngineCommandError(
                code: code, message: nonempty(message), stage: stage, sessionID: sessionID.map(wireID),
                severity: severity, recoveryAction: recoveryAction, details: details, cleanupErrors: cleanupErrors
            )
        } catch {
            preconditionFailure("command error fields are nonempty: \(error)")
        }
    }

    /// An adapter error keeps its code, message, recovery action and details; any other error becomes `fallback`.
    static func commandError(
        from error: any Error,
        fallback: EngineErrorCode,
        stage: EngineStage,
        sessionID: UUID? = nil,
        recoveryAction: EngineRecoveryAction = .none
    ) -> EngineCommandError {
        if let command = error as? EngineCommandError { return command }
        if let adapter = error as? EngineAdapterError {
            return commandError(
                adapter.code, adapter.message, stage: stage, sessionID: sessionID,
                recoveryAction: adapter.recoveryAction, details: adapter.details
            )
        }
        return commandError(
            fallback, error.localizedDescription, stage: stage, sessionID: sessionID,
            recoveryAction: recoveryAction, details: [detail(for: error)]
        )
    }

    static func wireID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func sessionID(_ wire: String, stage: EngineStage) throws -> UUID {
        guard let id = UUID(uuidString: wire) else {
            throw commandError(.sessionNotFound, "session_id が UUID ではありません: \(wire)", stage: stage)
        }
        return id
    }
}
