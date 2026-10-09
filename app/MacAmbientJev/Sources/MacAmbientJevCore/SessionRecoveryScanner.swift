import Foundation

/// What recovery does with a session. Finalization always reruns every stage
/// from the session's source audio.
public enum RecoverableProcessingAction: Sendable, Equatable {
    case finalize
    /// Requests again the pending Jev results of the published snapshot.
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

    /// Read-only.
    public func inspect(sessionID: UUID) throws -> SessionInspection {
        let layout = SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
        let manifest = try layout.loadManifest()
        return SessionInspection(
            recovery: try candidate(layout: layout, manifest: manifest),
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
                let recovery = try candidate(layout: layout, manifest: manifest)
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

    private func candidate(layout: SessionLayout, manifest: SessionManifest) throws -> RecoverableSession? {
        try SessionFolderName.validate(layout.sessionURL.lastPathComponent, manifest: manifest)
        let metadata = try ProcessingMetadataStore(sessionURL: layout.sessionURL).load()

        let action: RecoverableProcessingAction
        switch metadata?.finalizationAttempt?.state {
        case .running, .paused:
            action = .finalize
        case nil:
            // A recording that crashed before it stopped, or an import never processed.
            guard metadata?.activeRuns == nil,
                  try layout.audioSource(for: manifest) != nil else {
                return nil
            }
            return RecoverableSession(
                manifest: manifest,
                sessionURL: layout.sessionURL,
                action: .finalize
            )
        case .failed:
            return nil
        case .complete:
            guard let metadata, let activeRuns = metadata.activeRuns else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "完了した処理状態に公開 run がありません")
            }
            let recovered = try SessionRecovery.recoverJSONL(SessionFileAccess.read(layout.eventsURL, relativeTo: layout.sessionURL))
            guard !recovered.droppedIncompleteTail else {
                throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
            }
            let lines = recovered.lines
            let targets = try JevRetryAnalyzer().retryTargets(lines: lines, metadata: metadata)
            let unpublished = try JevRetryAnalyzer().hasUnpublishedJevRun(lines: lines, activeRuns: activeRuns)
            guard !targets.boundarySegments.isEmpty || !targets.clauses.isEmpty || unpublished else { return nil }
            action = .retryContentPriority(boundarySegments: targets.boundarySegments, clauses: targets.clauses)
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
