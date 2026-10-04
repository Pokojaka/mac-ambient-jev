import Foundation

/// What recovery does with a session. Finalization always reruns every stage
/// from the session's source audio.
public enum RecoverableProcessingAction: Sendable, Equatable {
    case finalize
    case retryContentPriority(segmentIDs: [String])
}

public struct RecoverableSession: Sendable, Equatable {
    public let manifest: SessionManifest
    public let sessionURL: URL
    public let source: SessionAudioSource
    public let action: RecoverableProcessingAction

    public init(
        manifest: SessionManifest,
        sessionURL: URL,
        source: SessionAudioSource,
        action: RecoverableProcessingAction
    ) {
        self.manifest = manifest
        self.sessionURL = sessionURL
        self.source = source
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

public struct SessionRecoveryScan: Sendable, Equatable {
    public let candidates: [RecoverableSession]
    public let failures: [SessionRecoveryFailure]

    public init(candidates: [RecoverableSession], failures: [SessionRecoveryFailure]) {
        self.candidates = candidates
        self.failures = failures
    }
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

    public func inspect(sessionID: UUID) throws -> RecoverableSession? {
        let layout = SessionLayout(sessionURL: try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: sessionsRoot, sessionID: sessionID))
        return try candidate(layout: layout)
    }

    public func pendingSessions() throws -> SessionRecoveryScan {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return SessionRecoveryScan(candidates: [], failures: [])
        }

        let entries = try SessionDirectoryInventory.read(sessionsRoot: sessionsRoot, fileManager: .default)
        let duplicates = SessionDirectoryInventory.duplicateFolders(in: entries)

        var candidates: [RecoverableSession] = []
        var failures: [SessionRecoveryFailure] = []
        for entry in entries {
            let sessionURL = entry.url
            let layout = SessionLayout(sessionURL: sessionURL)
            do {
                let manifest = try entry.manifest.get()
                if let folders = duplicates[manifest.sessionID] {
                    throw SessionDirectoryLookupError.multipleMatches(sessionID: manifest.sessionID, folders: folders)
                }
                if let candidate = try candidate(layout: layout, manifest: manifest) {
                    candidates.append(candidate)
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
            failures: failures.sorted { $0.sessionURL.lastPathComponent < $1.sessionURL.lastPathComponent }
        )
    }

    private func candidate(layout: SessionLayout) throws -> RecoverableSession? {
        try candidate(layout: layout, manifest: decodeManifest(at: layout.manifestURL))
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
                  let source = try layout.audioSource(for: manifest) else {
                return nil
            }
            return RecoverableSession(
                manifest: manifest,
                sessionURL: layout.sessionURL,
                source: source,
                action: .finalize
            )
        case .failed:
            return nil
        case .complete:
            guard let metadata, let activeRuns = metadata.activeRuns,
                  !metadata.pendingContentPrioritySegmentIDs.isEmpty else {
                return nil
            }
            action = .retryContentPriority(segmentIDs: try contentPrioritySegmentIDs(
                layout: layout,
                activeRuns: activeRuns,
                pendingSegmentIDs: metadata.pendingContentPrioritySegmentIDs
            ))
        }

        guard let source = try layout.audioSource(for: manifest) else {
            throw SessionRecoveryScannerError.missingAudio
        }
        return RecoverableSession(
            manifest: manifest,
            sessionURL: layout.sessionURL,
            source: source,
            action: action
        )
    }

    /// A content-priority run newer than the selected one means a retry was
    /// interrupted before it was published; its partial result is not adopted,
    /// so every segment of the published segmentation is classified again.
    private func contentPrioritySegmentIDs(
        layout: SessionLayout,
        activeRuns: ActiveRuns,
        pendingSegmentIDs: [String]
    ) throws -> [String] {
        let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL)).lines
        let jevState = try JevRetryAnalyzer().contentPriorityState(lines: lines)
        guard jevState.hasAssignments, jevState.latestRunID != activeRuns.contentPriority else {
            return pendingSegmentIDs
        }
        return try EventLogTranscriptReader()
            .events(lines: lines, activeRuns: activeRuns)
            .compactMap { event in
                guard case .segmentCreated = event.kind,
                      event.segmentationRunID == activeRuns.segmentation else { return nil }
                return event.segmentID
            }
    }

    private func decodeManifest(at url: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SessionManifest.self, from: data)
        } catch let error as DecodingError {
            throw SessionRecoveryScannerError.unreadableManifest(String(describing: error))
        }
    }
}
