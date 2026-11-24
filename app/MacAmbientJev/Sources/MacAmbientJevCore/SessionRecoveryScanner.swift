import Foundation

/// What recovery does with a session. Finalization always reruns every stage
/// from the session's source audio.
public enum RecoverableProcessingAction: Sendable, Equatable {
    case finalize
    /// A final or retry decision run was saved without publishing its snapshot. Launch recovery
    /// requests the published pending results again and publishes a new snapshot.
    case recoverDecisionRun(boundarySegments: [SegmentTextReference], clauses: [ClauseReference])
    /// The published snapshot has pending decision results. Only the user's retry requests them again.
    case retryContentPriority(boundarySegments: [SegmentTextReference], clauses: [ClauseReference])
}

public struct RecoverableSession: Sendable, Equatable {
    public let manifest: SessionManifest
    public let sessionURL: URL
    public let action: RecoverableProcessingAction

    public init(
        manifest: SessionManifest,
        sessionURL: URL,
        action: RecoverableProcessingAction
    ) {
        self.manifest = manifest
        self.sessionURL = sessionURL
        self.action = action
    }
}

/// A session folder whose recovery state could not be determined.
public struct SessionRecoveryFailure: Sendable, Equatable {
    public let sessionURL: URL
    public let message: String

    public init(sessionURL: URL, message: String) {
        self.sessionURL = sessionURL
        self.message = message
    }
}

/// A session whose stored audio needs maintenance, independent of transcript recovery.
public struct SessionMaintenanceCandidate: Sendable, Equatable {
    public let sessionID: UUID
    public let sessionURL: URL
    public let maintenance: SessionStorageMaintenance

    public init(sessionID: UUID, sessionURL: URL, maintenance: SessionStorageMaintenance) {
        self.sessionID = sessionID
        self.sessionURL = sessionURL
        self.maintenance = maintenance
    }
}

public struct SessionRecoveryScan: Sendable, Equatable {
    public let candidates: [RecoverableSession]
    public let maintenance: [SessionMaintenanceCandidate]
    public let failures: [SessionRecoveryFailure]

    public init(
        candidates: [RecoverableSession],
        maintenance: [SessionMaintenanceCandidate],
        failures: [SessionRecoveryFailure]
    ) {
        self.candidates = candidates
        self.maintenance = maintenance
        self.failures = failures
    }
}

/// What one session needs: transcript recovery and storage maintenance are reported separately.
public struct SessionInspection: Sendable, Equatable {
    public let recovery: RecoverableSession?
    public let maintenance: SessionStorageMaintenance?
}

public enum SessionRecoveryScannerError: Error, LocalizedError, Equatable {
    case missingAudio
    case unreadableManifest(String)

    public var errorDescription: String? {
        switch self {
        case .missingAudio:
            "確定処理が途中のセッションに音声がありません"
        case .unreadableManifest(let reason):
            "セッション情報を読めません: \(reason)"
        }
    }
}

public struct SessionRecoveryScanner: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    /// Read-only unless a failed session is explicitly included for resumption.
    public func inspect(sessionID: UUID, includeFailed: Bool = false) throws -> SessionInspection {
        let layout = SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
        let manifest = try layout.loadManifest()
        return SessionInspection(
            recovery: try candidate(layout: layout, manifest: manifest, includeFailed: includeFailed),
            maintenance: try SessionStorageMaintenance.required(layout: layout, manifest: manifest)
        )
    }

    public func pendingSessions() throws -> SessionRecoveryScan {
        guard try SessionFileAccess.isDirectoryIfPresent(sessionsRoot, relativeTo: sessionsRoot) == true else {
            return SessionRecoveryScan(candidates: [], maintenance: [], failures: [])
        }

        let entries = try SessionDirectoryInventory.read(sessionsRoot: sessionsRoot, fileManager: .default)
        let duplicates = SessionDirectoryInventory.duplicateFolders(in: entries)

        var candidates: [RecoverableSession] = []
        var maintenance: [SessionMaintenanceCandidate] = []
        var failures: [SessionRecoveryFailure] = []
        for entry in entries {
            let sessionURL = entry.url
            let layout = SessionLayout(sessionURL: sessionURL)
            do {
                let manifest = try entry.manifest.get()
                if let folders = duplicates[manifest.sessionID] {
                    throw SessionDirectoryLookupError.multipleMatches(sessionID: manifest.sessionID, folders: folders)
                }
                let recovery = try candidate(layout: layout, manifest: manifest, includeFailed: false)
                let required = try SessionStorageMaintenance.required(layout: layout, manifest: manifest)
                if let recovery {
                    candidates.append(recovery)
                }
                if let required {
                    maintenance.append(SessionMaintenanceCandidate(
                        sessionID: manifest.sessionID, sessionURL: sessionURL, maintenance: required
                    ))
                }
            } catch {
                failures.append(SessionRecoveryFailure(
                    sessionURL: sessionURL,
                    message: error.localizedDescription
                ))
            }
        }
        return SessionRecoveryScan(
            candidates: candidates.sorted { $0.manifest.createdAt < $1.manifest.createdAt },
            maintenance: maintenance.sorted { $0.sessionURL.lastPathComponent < $1.sessionURL.lastPathComponent },
            failures: failures.sorted { $0.sessionURL.lastPathComponent < $1.sessionURL.lastPathComponent }
        )
    }

    private func candidate(
        layout: SessionLayout, manifest: SessionManifest, includeFailed: Bool
    ) throws -> RecoverableSession? {
        try SessionFolderName.validate(layout.sessionURL.lastPathComponent, manifest: manifest)
        let metadata = try ProcessingMetadataStore(sessionURL: layout.sessionURL).load()
        let recovered = try SessionRecovery.recoverJSONL(
            SessionFileAccess.read(layout.eventsURL, relativeTo: layout.sessionURL)
        )
        let state = try ProcessingLogState(lines: recovered.lines, sessionID: manifest.sessionID)
        guard state != nil || metadata == nil else { throw ProcessingLogStateError.missingGeneration }
        let currentMetadata = state.flatMap { metadata?.generationID == $0.generation.id ? metadata : nil }

        let action: RecoverableProcessingAction
        if state?.hasUnresolvedASRFailure == true || currentMetadata?.state == .failed {
            guard includeFailed else { return nil }
            action = .finalize
        } else {
            switch currentMetadata?.state {
            case .running, .paused:
                action = .finalize
            case .complete:
                guard !recovered.droppedIncompleteTail else {
                    throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
                }
                guard let state, let sealedFrames = state.sealedFrames else {
                    throw ProcessingLogStateError.incompleteRecognition
                }
                let transcript = try EventLogTranscriptReader().validateCompletion(
                    eventsURL: layout.eventsURL, sessionID: manifest.sessionID, frameCount: sealedFrames
                )
                let analyzer = DecisionRetryAnalyzer()
                if try analyzer.hasUnpublishedDecisionRun(lines: recovered.lines, sessionID: manifest.sessionID) {
                    action = .recoverDecisionRun(
                        boundarySegments: transcript.pendingDecisions.boundarySegments,
                        clauses: transcript.pendingDecisions.clauses
                    )
                } else if !transcript.pendingDecisions.boundarySegments.isEmpty
                            || !transcript.pendingDecisions.clauses.isEmpty {
                    action = .retryContentPriority(
                        boundarySegments: transcript.pendingDecisions.boundarySegments,
                        clauses: transcript.pendingDecisions.clauses
                    )
                } else {
                    return nil
                }
            case .failed:
                return nil
            case nil:
                if state != nil {
                    // A reset or status write interrupted the current generation's finalization.
                    action = .finalize
                } else {
                    // A recording may have stopped before its first pipeline generation.
                    guard try layout.audioSource(for: manifest) != nil else { return nil }
                    return RecoverableSession(
                        manifest: manifest,
                        sessionURL: layout.sessionURL,
                        action: .finalize
                    )
                }
            }
        }

        guard try layout.audioSource(for: manifest) != nil else {
            throw SessionRecoveryScannerError.missingAudio
        }
        return RecoverableSession(
            manifest: manifest,
            sessionURL: layout.sessionURL,
            action: action
        )
    }
}
