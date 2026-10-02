import Foundation

public struct FinalizationAttempt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case paused
        case failed
        case complete
    }

    public let attemptID: String
    public let state: State
    public let failureReason: String?

    private enum CodingKeys: String, CodingKey {
        case attemptID = "attemptId"
        case state
        case failureReason
    }

    public init(attemptID: String, state: State, failureReason: String?) {
        self.attemptID = attemptID
        self.state = state
        self.failureReason = failureReason
    }
}

/// Per-session processing state. Which engines and settings produced each run is
/// recorded on the run itself as a `processing.run.started` event.
public struct ProcessingMetadata: Codable, Sendable, Equatable {
    public var finalizationAttempt: FinalizationAttempt?
    /// The published run set. Set only when a finalization attempt completes.
    public var activeRuns: ActiveRuns?
    public var pendingContentPrioritySegmentIDs: [String]

    public init(
        finalizationAttempt: FinalizationAttempt?,
        activeRuns: ActiveRuns?,
        pendingContentPrioritySegmentIDs: [String]
    ) {
        self.finalizationAttempt = finalizationAttempt
        self.activeRuns = activeRuns
        self.pendingContentPrioritySegmentIDs = pendingContentPrioritySegmentIDs
    }
}

/// What a new finalization attempt does with a `processing_metadata.json` that cannot be decoded.
public enum UnreadableMetadataPolicy: Sendable, Equatable {
    /// Fail: the file is reported and left untouched.
    case reject
    /// Start over with fresh metadata. Only an explicit user reprocess chooses this.
    case replace
}

public enum ProcessingMetadataStoreError: Error, LocalizedError, Equatable {
    case metadataMissing
    case finalizationAttemptMismatch
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .metadataMissing:
            "処理状態ファイルがありません"
        case .finalizationAttemptMismatch:
            "処理状態ファイルの確定処理 ID が一致しません"
        case .unreadable(let reason):
            "処理状態ファイルを読めません: \(reason)"
        }
    }
}

public struct ProcessingMetadataStore: Sendable {
    public let url: URL

    public init(sessionURL: URL) {
        self.url = SessionLayout(sessionURL: sessionURL).processingMetadataURL
    }

    public func load() throws -> ProcessingMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(ProcessingMetadata.self, from: data)
        } catch let error as DecodingError {
            throw ProcessingMetadataStoreError.unreadable(String(describing: error))
        }
    }

    public func save(_ metadata: ProcessingMetadata) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    /// Marks a new attempt as running and returns the metadata it replaced
    /// (nil when there was none or `policy` replaced an unreadable file).
    /// The published runs and pending classifications stay as they were.
    @discardableResult
    public func beginFinalization(
        attemptID: String,
        policy: UnreadableMetadataPolicy
    ) throws -> ProcessingMetadata? {
        let previous: ProcessingMetadata?
        do {
            previous = try load()
        } catch ProcessingMetadataStoreError.unreadable where policy == .replace {
            previous = nil
        }
        var metadata = previous ?? ProcessingMetadata(
            finalizationAttempt: nil,
            activeRuns: nil,
            pendingContentPrioritySegmentIDs: []
        )
        metadata.finalizationAttempt = FinalizationAttempt(
            attemptID: attemptID,
            state: .running,
            failureReason: nil
        )
        try save(metadata)
        return previous
    }

    public func pauseFinalization(attemptID: String) throws {
        try updateAttempt(attemptID: attemptID) { metadata in
            metadata.finalizationAttempt = FinalizationAttempt(
                attemptID: attemptID,
                state: .paused,
                failureReason: nil
            )
        }
    }

    public func failFinalization(attemptID: String, reason: String) throws {
        try updateAttempt(attemptID: attemptID) { metadata in
            metadata.finalizationAttempt = FinalizationAttempt(
                attemptID: attemptID,
                state: .failed,
                failureReason: reason
            )
        }
    }

    /// Publishes `activeRuns` as the whole run set. Classifications of the
    /// previous runs no longer apply, so none are pending.
    public func completeFinalization(attemptID: String, activeRuns: ActiveRuns) throws {
        try updateAttempt(attemptID: attemptID) { metadata in
            metadata.finalizationAttempt = FinalizationAttempt(
                attemptID: attemptID,
                state: .complete,
                failureReason: nil
            )
            metadata.activeRuns = activeRuns
            metadata.pendingContentPrioritySegmentIDs = []
        }
    }

    /// Applies `change` to existing metadata.
    public func update(_ change: (inout ProcessingMetadata) throws -> Void) throws {
        guard var metadata = try load() else {
            throw ProcessingMetadataStoreError.metadataMissing
        }
        try change(&metadata)
        try save(metadata)
    }

    private func updateAttempt(
        attemptID: String,
        _ change: (inout ProcessingMetadata) -> Void
    ) throws {
        try update { metadata in
            guard metadata.finalizationAttempt?.attemptID == attemptID else {
                throw ProcessingMetadataStoreError.finalizationAttemptMismatch
            }
            change(&metadata)
        }
    }
}
