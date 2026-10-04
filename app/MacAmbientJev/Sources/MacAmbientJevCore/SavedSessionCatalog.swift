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
    /// No audio timeline to measure: no recorded audio, or an import whose timeline has not been built.
    case unknown
    /// The timeline checkpoint exists but cannot be read.
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
        createdAt: Date,
        source: SessionSource,
        duration: SavedSessionDuration,
        audio: SavedSessionAudio,
        hasActiveTranscript: Bool,
        processingStatus: SavedSessionProcessingStatus
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.source = source
        self.duration = duration
        self.audio = audio
        self.hasActiveTranscript = hasActiveTranscript
        self.processingStatus = processingStatus
    }
}

/// One row of the saved-session list. Only a session whose manifest cannot be read,
/// or whose manifest names another session, is unreadable as a whole.
public enum SavedSessionSummary: Sendable, Equatable, Identifiable {
    case readable(SavedSession)
    case unreadable(sessionID: UUID, reason: String)

    public var sessionID: UUID {
        switch self {
        case .readable(let session): session.sessionID
        case .unreadable(let sessionID, _): sessionID
        }
    }

    public var id: UUID { sessionID }

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

        let urls = try fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var summaries: [SavedSessionSummary] = []
        for url in urls {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let folderID = UUID(uuidString: url.lastPathComponent) else {
                continue
            }
            summaries.append(summary(layout: SessionLayout(sessionURL: url), folderID: folderID))
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
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
        }
        return summaries
    }

    private func summary(layout: SessionLayout, folderID: UUID) -> SavedSessionSummary {
        let manifest: SessionManifest
        do {
            manifest = try decodeManifest(at: layout.manifestURL)
        } catch is DecodingError {
            return .unreadable(sessionID: folderID, reason: "セッション情報が壊れています")
        } catch {
            return .unreadable(sessionID: folderID, reason: error.localizedDescription)
        }
        guard manifest.sessionID == folderID else {
            return .unreadable(
                sessionID: folderID,
                reason: "保存セッションの ID がフォルダー名と一致しません"
            )
        }

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
        if let activeRuns = metadata?.activeRuns, activeRuns.asr != nil {
            do {
                let data = try Data(contentsOf: layout.eventsURL)
                let recovered = try SessionRecovery.recoverJSONL(data)
                guard !recovered.droppedIncompleteTail else {
                    throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
                }
                _ = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: activeRuns)
                hasActiveTranscript = true
            } catch {
                processingStatus = .corrupted(error.localizedDescription)
                return .readable(SavedSession(
                    sessionID: manifest.sessionID,
                    createdAt: manifest.createdAt,
                    source: manifest.source,
                    duration: duration(layout: layout, manifest: manifest, audio: audio),
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
            createdAt: manifest.createdAt,
            source: manifest.source,
            duration: duration(layout: layout, manifest: manifest, audio: audio),
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

    private func duration(
        layout: SessionLayout,
        manifest: SessionManifest,
        audio: SavedSessionAudio
    ) -> SavedSessionDuration {
        let checkpoint: AudioCheckpoint?
        switch manifest.source {
        case .recording:
            guard case .available(.recordedTimeline(let recorded)) = audio else { return .unknown }
            checkpoint = recorded
        case .imported:
            do {
                checkpoint = try AudioCheckpoint.loadRecovered(from: layout.processingDirectory)
            } catch {
                return .unreadable("音声の長さを読めません: \(error.localizedDescription)")
            }
        }
        guard let checkpoint else { return .unknown }
        return .seconds(Double(checkpoint.committedFrames) / checkpoint.sampleRate)
    }

    private func decodeManifest(at url: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: Data(contentsOf: url))
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
            metadata?.pendingContentPrioritySegmentIDs.isEmpty == false
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
