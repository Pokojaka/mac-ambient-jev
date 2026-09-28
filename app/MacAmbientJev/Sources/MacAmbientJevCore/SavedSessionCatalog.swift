import Foundation

public enum SavedSessionAudioSource: Sendable, Equatable {
    case processingTimeline(AudioCheckpoint)
    case importedOriginal(URL)
}

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

public enum SavedSessionProcessingStatus: Sendable, Equatable {
    case notProcessed
    case running
    case complete
    case classificationPending
    case failed(String?)
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

public struct SavedSessionSummary: Sendable, Equatable, Identifiable {
    public let sessionID: UUID
    public let createdAt: Date?
    public let sourceKind: SessionSourceKind?
    public let originalFilename: String?
    public let durationSeconds: Double?
    public let audioSource: SavedSessionAudioSource?
    public let hasActiveTranscript: Bool
    public let processingStatus: SavedSessionProcessingStatus
    public let errorMessage: String?

    public var id: UUID { sessionID }
    public var audioAvailable: Bool { audioSource != nil }
    public var canReprocess: Bool {
        audioAvailable && errorMessage == nil
    }

    public init(
        sessionID: UUID,
        createdAt: Date?,
        sourceKind: SessionSourceKind?,
        originalFilename: String? = nil,
        durationSeconds: Double? = nil,
        audioSource: SavedSessionAudioSource?,
        hasActiveTranscript: Bool,
        processingStatus: SavedSessionProcessingStatus,
        errorMessage: String? = nil
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.sourceKind = sourceKind
        self.originalFilename = originalFilename
        self.durationSeconds = durationSeconds
        self.audioSource = audioSource
        self.hasActiveTranscript = hasActiveTranscript
        self.processingStatus = processingStatus
        self.errorMessage = errorMessage
    }
}

public struct SavedSessionCatalog {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
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
        var summaries = urls.compactMap { url -> SavedSessionSummary? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let folderID = UUID(uuidString: url.lastPathComponent) else {
                return nil
            }
            return summary(sessionURL: url, folderID: folderID)
        }

        summaries.sort { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
        }
        return summaries
    }

    private func summary(
        sessionURL: URL,
        folderID: UUID
    ) -> SavedSessionSummary {
        do {
            let manifestURL = sessionURL.appending(path: "session.json")
            let manifest = try decodeManifest(at: manifestURL)
            guard manifest.sessionID == folderID else {
                throw SavedSessionCatalogError.sessionIDMismatch
            }

            let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
            let source = try audioSource(for: manifest, sessionURL: sessionURL)
            let checkpoint: AudioCheckpoint?
            if case .processingTimeline(let value) = source {
                checkpoint = value
            } else {
                checkpoint = try? loadCheckpoint(sessionURL: sessionURL)
            }
            let duration = checkpoint.flatMap { checkpoint -> Double? in
                guard checkpoint.sampleRate > 0 else { return nil }
                return Double(checkpoint.committedFrames) / checkpoint.sampleRate
            }

            return SavedSessionSummary(
                sessionID: manifest.sessionID,
                createdAt: manifest.createdAt,
                sourceKind: manifest.sourceKind,
                originalFilename: manifest.originalFilename,
                durationSeconds: duration,
                audioSource: source,
                hasActiveTranscript: metadata?.activeRuns?.asr != nil,
                processingStatus: status(for: metadata),
                errorMessage: nil
            )
        } catch {
            return SavedSessionSummary(
                sessionID: folderID,
                createdAt: nil,
                sourceKind: nil,
                audioSource: nil,
                hasActiveTranscript: false,
                processingStatus: .notProcessed,
                errorMessage: error is DecodingError
                    ? "セッション情報が壊れています"
                    : error.localizedDescription
            )
        }
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
        case .complete:
            metadata?.pendingContentPrioritySegmentIDs?.isEmpty == false
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

    private func audioSource(
        for manifest: SessionManifest,
        sessionURL: URL
    ) throws -> SavedSessionAudioSource? {
        do {
            if let checkpoint = try loadCheckpoint(sessionURL: sessionURL),
               !checkpoint.chunkFiles.isEmpty,
               checkpoint.committedFrames > 0 {
                return .processingTimeline(checkpoint)
            }
        } catch {
            if manifest.sourceKind == .importedFile,
               let original = try findOriginalAudio(sessionURL: sessionURL) {
                return .importedOriginal(original)
            }
            throw error
        }

        guard manifest.sourceKind == .importedFile,
              let original = try findOriginalAudio(sessionURL: sessionURL) else {
            return nil
        }
        return .importedOriginal(original)
    }

    private func loadCheckpoint(sessionURL: URL) throws -> AudioCheckpoint? {
        let processingURL = sessionURL
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
        guard let checkpoint = try AudioCheckpoint.loadRecovered(from: processingURL) else {
            return nil
        }
        guard (1_000...768_000).contains(checkpoint.sampleRate),
              (try? ProcessingTimelineReader(directory: processingURL, checkpoint: checkpoint)
                .validateChunkFiles()) != nil else {
            throw SavedSessionCatalogError.invalidAudioCheckpoint
        }
        return checkpoint
    }

    private func findOriginalAudio(sessionURL: URL) throws -> URL? {
        let audioURL = sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: audioURL.path) else { return nil }
        return try fileManager.contentsOfDirectory(
            at: audioURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .first { url in
            (url.lastPathComponent == "original" || url.lastPathComponent.hasPrefix("original."))
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}

private enum SavedSessionCatalogError: Error, LocalizedError {
    case sessionIDMismatch
    case invalidAudioCheckpoint

    var errorDescription: String? {
        switch self {
        case .sessionIDMismatch:
            "保存セッションの ID がフォルダー名と一致しません"
        case .invalidAudioCheckpoint:
            "保存済み音声のチェックポイントが破損しています"
        }
    }
}
