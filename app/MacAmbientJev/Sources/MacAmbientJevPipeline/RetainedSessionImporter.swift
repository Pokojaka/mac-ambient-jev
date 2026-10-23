import Foundation
import MacAmbientJevCore

/// A sessions root that file operations may write to. A root chosen outside the application is checked against the
/// protected application roots; the application's own root is trusted without that check.
public struct ValidatedSessionPaths: Sendable {
    public let paths: AppPaths

    private init(paths: AppPaths) {
        self.paths = paths
    }

    public static func externalRoot(_ paths: AppPaths, protectedRoots: [URL]) throws -> ValidatedSessionPaths {
        let root = try SessionsRootPolicy.validated(
            paths.sessionsRoot,
            protectedRoots: protectedRoots,
            fileManager: .default
        )
        return ValidatedSessionPaths(paths: AppPaths(
            applicationSupportURL: paths.applicationSupportURL,
            cacheURL: paths.cacheURL,
            sessionsRootOverride: root
        ))
    }

    public static func trustedApplication(_ paths: AppPaths) -> ValidatedSessionPaths {
        ValidatedSessionPaths(paths: paths)
    }
}

/// The single request that finalizes a session. Whoever owns processing admission hands it to
/// `SessionProcessingCoordinator`, or the CLI awaits it directly. Nothing else finalizes the session.
public struct SessionFinalizeRequest: Sendable, Equatable {
    public let sessionID: UUID
    public let metadataPolicy: UnreadableMetadataPolicy

    public init(sessionID: UUID, metadataPolicy: UnreadableMetadataPolicy) {
        self.sessionID = sessionID
        self.metadataPolicy = metadataPolicy
    }

    public var pending: PendingProcessing {
        .finalize(sessionID: sessionID, metadataPolicy: metadataPolicy)
    }
}

public struct RetainedSession: Sendable, Equatable {
    public let sessionID: UUID
    public let sessionURL: URL
    public let finalize: SessionFinalizeRequest

    public init(sessionID: UUID, sessionURL: URL, finalize: SessionFinalizeRequest) {
        self.sessionID = sessionID
        self.sessionURL = sessionURL
        self.finalize = finalize
    }
}

public enum RetainedImportError: LocalizedError {
    case bootstrap(underlying: any Error)
    case copy(sessionID: UUID, sessionURL: URL, underlying: any Error)

    public var underlying: any Error {
        switch self {
        case .bootstrap(let underlying), .copy(_, _, let underlying): underlying
        }
    }

    /// The session folder the failed import left behind, for the caller to remove or keep.
    public var createdSession: (sessionID: UUID, sessionURL: URL)? {
        switch self {
        case .bootstrap: nil
        case .copy(let sessionID, let sessionURL, _): (sessionID, sessionURL)
        }
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

/// Creates a session for an audio file and copies the original into it once. It neither processes the session nor
/// renders output; the caller finalizes the returned request.
public struct RetainedSessionImporter: Sendable {
    private let validated: ValidatedSessionPaths

    public init(paths: ValidatedSessionPaths) {
        self.validated = paths
    }

    public func importRetainedSession(audioURL: URL) throws -> RetainedSession {
        let sessionID = UUID()
        let sessionURL: URL
        do {
            sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
                paths: validated.paths,
                sessionID: sessionID,
                source: .imported(originalFilename: audioURL.lastPathComponent),
                createdAt: Date(),
                timeZone: .current
            )
        } catch {
            throw RetainedImportError.bootstrap(underlying: error)
        }
        do {
            _ = try AudioImporter().importFile(audioURL, into: sessionURL)
        } catch {
            throw RetainedImportError.copy(sessionID: sessionID, sessionURL: sessionURL, underlying: error)
        }
        return RetainedSession(
            sessionID: sessionID,
            sessionURL: sessionURL,
            finalize: SessionFinalizeRequest(sessionID: sessionID, metadataPolicy: .reject)
        )
    }
}
