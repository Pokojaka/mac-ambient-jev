import Foundation

public enum SavedSessionSelectionPolicy {
    public static func canSelect(isRecording: Bool) -> Bool {
        !isRecording
    }
}

public enum SavedSessionDisplayText {
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "不明" }
        let rounded = max(0, seconds.rounded())
        guard rounded < Double(Int.max) else { return "不明" }
        let total = Int(rounded)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// The state of the results derived from the source audio.
public enum SavedSessionProcessingStatus: Sendable, Equatable {
    case notProcessed
    case running
    /// Finalization stopped for heat and resumes from the oldest unfinished segment.
    case paused
    case complete
    case classificationPending
    case failed(String?)
    /// `processing_metadata.json` cannot be read. The source audio may still be intact.
    case corrupted(String)
}

/// The source audio of a session whose manifest is readable.
public enum SavedSessionAudio: Sendable, Equatable {
    case available(SessionAudioSource)
    /// A recording that captured no audio.
    case missing
    /// The source audio exists but cannot be resolved; the reason is shown to the user.
    case unreadable(String)
}

public enum SavedSessionDuration: Sendable, Equatable {
    case seconds(Double)
    /// No audio timeline to measure: no recorded audio, unusable audio, or an import whose
    /// timeline has not been built.
    case unknown
    /// The stored timeline coordinates are invalid.
    case unreadable(String)
}

public struct SavedSessionReprocessGate: Sendable {
    private var activeSessionIDs: Set<UUID> = []

    public init() {}

    public var sessionIDs: Set<UUID> { activeSessionIDs }

    @discardableResult
    public mutating func claim(_ sessionID: UUID) -> Bool {
        activeSessionIDs.insert(sessionID).inserted
    }

    public mutating func release(_ sessionID: UUID) {
        activeSessionIDs.remove(sessionID)
    }
}

/// A saved session whose manifest is readable.
public struct SavedSession: Sendable, Equatable, Identifiable {
    public let sessionID: UUID
    public let sessionURL: URL
    public let createdAt: Date
    public let source: SessionSource
    public let duration: SavedSessionDuration
    public let audio: SavedSessionAudio
    public let hasActiveTranscript: Bool
    public let processingStatus: SavedSessionProcessingStatus

    public var id: UUID { sessionID }

    public var audioSource: SessionAudioSource? {
        guard case .available(let source) = audio else { return nil }
        return source
    }

    public init(
        sessionID: UUID,
        sessionURL: URL,
        createdAt: Date,
        source: SessionSource,
        duration: SavedSessionDuration,
        audio: SavedSessionAudio,
        hasActiveTranscript: Bool,
        processingStatus: SavedSessionProcessingStatus
    ) {
        self.sessionID = sessionID
        self.sessionURL = sessionURL
        self.createdAt = createdAt
        self.source = source
        self.duration = duration
        self.audio = audio
        self.hasActiveTranscript = hasActiveTranscript
        self.processingStatus = processingStatus
    }
}

/// One folder in the saved-session list. Invalid names, unreadable manifests,
/// and ambiguous manifest identities remain individually addressable by URL.
public enum SavedSessionSummary: Sendable, Equatable, Identifiable {
    case readable(SavedSession)
    case unreadable(sessionURL: URL, sessionID: UUID?, reason: String)

    public var sessionID: UUID? {
        switch self {
        case .readable(let session): session.sessionID
        case .unreadable(_, let sessionID, _): sessionID
        }
    }

    public var sessionURL: URL {
        switch self {
        case .readable(let session): session.sessionURL
        case .unreadable(let sessionURL, _, _): sessionURL
        }
    }

    public var id: URL { sessionURL }

    public var audioSource: SessionAudioSource? {
        guard case .readable(let session) = self else { return nil }
        return session.audioSource
    }

    /// Reprocessing needs only a readable manifest and available source audio,
    /// even when the derived results are corrupted.
    public var canReprocess: Bool { audioSource != nil }
}

public struct SavedSessionCatalog {
    private let fileManager: FileManager

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    public func list(sessionsRoot: URL) throws -> [SavedSessionSummary] {
        guard fileManager.fileExists(atPath: sessionsRoot.path) else {
            return []
        }

        let entries = try SessionDirectoryInventory.read(sessionsRoot: sessionsRoot, fileManager: fileManager)
        let duplicates = SessionDirectoryInventory.duplicateFolders(in: entries)
        var summaries = entries.map { entry -> SavedSessionSummary in
            let manifest: SessionManifest
            do {
                manifest = try entry.manifest.get()
            } catch {
                return .unreadable(sessionURL: entry.url, sessionID: nil, reason: error.localizedDescription)
            }
            do {
                if let folders = duplicates[manifest.sessionID] {
                    throw SessionDirectoryLookupError.multipleMatches(sessionID: manifest.sessionID, folders: folders)
                }
                try SessionFolderName.validate(entry.url.lastPathComponent, manifest: manifest)
            } catch {
                return .unreadable(sessionURL: entry.url, sessionID: manifest.sessionID, reason: error.localizedDescription)
            }
            return summary(layout: SessionLayout(sessionURL: entry.url), manifest: manifest)
        }

        summaries.sort { lhs, rhs in
            switch (lhs, rhs) {
            case let (.readable(left), .readable(right)) where left.createdAt != right.createdAt:
                return left.createdAt > right.createdAt
            case (.readable, .unreadable):
                return true
            case (.unreadable, .readable):
                return false
            default:
                return lhs.sessionURL.lastPathComponent < rhs.sessionURL.lastPathComponent
            }
        }
        return summaries
    }

    private func summary(layout: SessionLayout, manifest: SessionManifest) -> SavedSessionSummary {

        let audio = self.audio(layout: layout, manifest: manifest)
        let metadata: ProcessingMetadata?
        var processingStatus: SavedSessionProcessingStatus
        do {
            metadata = try ProcessingMetadataStore(sessionURL: layout.sessionURL).load()
            processingStatus = status(for: metadata)
        } catch {
            metadata = nil
            processingStatus = .corrupted(error.localizedDescription)
        }

        let hasActiveTranscript: Bool
        if let activeRuns = metadata?.activeRuns {
            do {
                let data = try Data(contentsOf: layout.eventsURL)
                let recovered = try SessionRecovery.recoverJSONL(data)
                guard !recovered.droppedIncompleteTail else {
                    throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
                }
                _ = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
                if let metadata, activeRuns.segmentation != nil || activeRuns.asr != nil {
                    _ = try JevRetryAnalyzer().retryTargets(lines: recovered.lines, metadata: metadata)
                }
                hasActiveTranscript = activeRuns.asr != nil
            } catch {
                processingStatus = .corrupted(error.localizedDescription)
                return .readable(SavedSession(
                    sessionID: manifest.sessionID,
                    sessionURL: layout.sessionURL,
                    createdAt: manifest.createdAt,
                    source: manifest.source,
                    duration: duration(audio: audio),
                    audio: audio,
                    hasActiveTranscript: false,
                    processingStatus: processingStatus
                ))
            }
        } else {
            hasActiveTranscript = false
        }

        return .readable(SavedSession(
            sessionID: manifest.sessionID,
            sessionURL: layout.sessionURL,
            createdAt: manifest.createdAt,
            source: manifest.source,
            duration: duration(audio: audio),
            audio: audio,
            hasActiveTranscript: hasActiveTranscript,
            processingStatus: processingStatus
        ))
    }

    private func audio(layout: SessionLayout, manifest: SessionManifest) -> SavedSessionAudio {
        do {
            guard let source = try layout.audioSource(for: manifest) else { return .missing }
            return .available(source)
        } catch let error as SessionAudioSourceError {
            return .unreadable(error.localizedDescription)
        } catch {
            return .unreadable("保存済み音声を読めません: \(error.localizedDescription)")
        }
    }

    private func duration(audio: SavedSessionAudio) -> SavedSessionDuration {
        guard case .available(let source) = audio else { return .unknown }
        do {
            guard let timeline = try source.timeline else { return .unknown }
            return .seconds(timeline.durationSeconds)
        } catch {
            return .unreadable("音声の長さを読めません: \(error.localizedDescription)")
        }
    }

    private func status(
        for metadata: ProcessingMetadata?
    ) -> SavedSessionProcessingStatus {
        switch metadata?.finalizationAttempt?.state {
        case .running:
            .running
        case .paused:
            .paused
        case .complete:
            metadata?.pendingJevTargets.isEmpty == false
                ? .classificationPending
                : .complete
        case .failed:
            .failed(metadata?.finalizationAttempt?.failureReason)
        case nil:
            metadata?.activeRuns?.asr == nil && metadata?.activeRuns?.scope == nil
                ? .notProcessed
                : .complete
        }
    }
}
