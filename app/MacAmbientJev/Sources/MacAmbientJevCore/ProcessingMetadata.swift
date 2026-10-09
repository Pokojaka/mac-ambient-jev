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
        case attemptID = "attempt_id"
        case state
        case failureReason = "failure_reason"
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
    /// The published run set. The local runs are set when a finalization attempt completes;
    /// the Jev runs when their snapshot is published.
    public var activeRuns: ActiveRuns?
    /// Segments whose boundary request has no result in the published snapshot, in time order.
    public var pendingClauseBoundarySegments: [SegmentTextReference]
    /// Closed clauses of the published boundary run whose priority is pending, in text order.
    public var pendingContentPriorityClauses: [ClauseReference]

    public init(
        finalizationAttempt: FinalizationAttempt?,
        activeRuns: ActiveRuns?,
        pendingClauseBoundarySegments: [SegmentTextReference],
        pendingContentPriorityClauses: [ClauseReference]
    ) {
        self.finalizationAttempt = finalizationAttempt
        self.activeRuns = activeRuns
        self.pendingClauseBoundarySegments = pendingClauseBoundarySegments
        self.pendingContentPriorityClauses = pendingContentPriorityClauses
    }

    /// Structural invariants are checked both on read and before the atomic write. Full
    /// source coverage and the text order of clauses are checked against the event log.
    private func validate() throws {
        guard Set(pendingClauseBoundarySegments).count == pendingClauseBoundarySegments.count,
              Set(pendingContentPriorityClauses).count == pendingContentPriorityClauses.count,
              (activeRuns?.clauseBoundary == nil) == (activeRuns?.contentPriority == nil) else {
            throw ProcessingMetadataStoreError.unreadable("Jev の公開参照または保留一覧が不正です")
        }
        if activeRuns?.clauseBoundary != nil {
            guard activeRuns?.segmentation != nil, activeRuns?.asr != nil else {
                throw ProcessingMetadataStoreError.unreadable("Jev の公開 run に原文の処理 run がありません")
            }
        }
        if activeRuns == nil {
            guard pendingClauseBoundarySegments.isEmpty, pendingContentPriorityClauses.isEmpty else {
                throw ProcessingMetadataStoreError.unreadable("公開 run のない処理状態に保留参照があります")
            }
        }
        for source in pendingClauseBoundarySegments {
            guard source.segmentationRunID == activeRuns?.segmentation, source.asrRunID == activeRuns?.asr else {
                throw ProcessingMetadataStoreError.unreadable("境界保留の原文参照が公開 run と一致しません")
            }
        }
        for (previous, next) in zip(pendingClauseBoundarySegments, pendingClauseBoundarySegments.dropFirst()) {
            guard previous.asrEventSeq < next.asrEventSeq else {
                throw ProcessingMetadataStoreError.unreadable("境界保留の区間順が不正です")
            }
        }
        guard pendingContentPriorityClauses.allSatisfy({ $0.boundaryRunID == activeRuns?.clauseBoundary }) else {
            throw ProcessingMetadataStoreError.unreadable("優先度保留の節参照が公開 run と一致しません")
        }
    }

    /// Every pending target the published snapshot names.
    public var pendingJevTargets: Set<JevPendingTarget> {
        Set(pendingClauseBoundarySegments.map(JevPendingTarget.boundary))
            .union(pendingContentPriorityClauses.map(JevPendingTarget.priority))
    }

    private enum CodingKeys: String, CodingKey {
        case finalizationAttempt = "finalization_attempt"
        case activeRuns = "active_runs"
        case pendingClauseBoundarySegments = "pending_clause_boundary_segments"
        case pendingContentPriorityClauses = "pending_content_priority_clauses"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let boundary = try c.decode([SegmentTextReference].self, forKey: .pendingClauseBoundarySegments)
        let priority = try c.decode([ClauseReference].self, forKey: .pendingContentPriorityClauses)
        self.init(
            finalizationAttempt: try c.decode(FinalizationAttempt?.self, forKey: .finalizationAttempt),
            activeRuns: try c.decode(ActiveRuns?.self, forKey: .activeRuns),
            pendingClauseBoundarySegments: boundary,
            pendingContentPriorityClauses: priority
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(finalizationAttempt, forKey: .finalizationAttempt)
        try c.encode(activeRuns, forKey: .activeRuns)
        try c.encode(pendingClauseBoundarySegments, forKey: .pendingClauseBoundarySegments)
        try c.encode(pendingContentPriorityClauses, forKey: .pendingContentPriorityClauses)
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
    case publishedRunsChanged
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .metadataMissing:
            "処理状態ファイルがありません"
        case .finalizationAttemptMismatch:
            "処理状態ファイルの確定処理 ID が一致しません"
        case .publishedRunsChanged:
            "公開済みの処理結果が変更されたため、Jev の判定結果を公開できません"
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
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: url.deletingLastPathComponent()) else { return nil }
        do {
            return try JSONDecoder().decode(ProcessingMetadata.self, from: data)
        } catch let error as DecodingError {
            throw ProcessingMetadataStoreError.unreadable(String(describing: error))
        } catch {
            throw ProcessingMetadataStoreError.unreadable(error.localizedDescription)
        }
    }

    public func save(_ metadata: ProcessingMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try SessionFileAccess.writeAtomically(data, to: url, relativeTo: url.deletingLastPathComponent())
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
            pendingClauseBoundarySegments: [],
            pendingContentPriorityClauses: []
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

    /// Publishes the local runs as the whole run set in one write. The new segments have no
    /// boundary result yet, so every segment with text is recorded as boundary pending.
    public func completeFinalization(
        attemptID: String,
        activeRuns: ActiveRuns,
        pendingClauseBoundarySegments: [SegmentTextReference]
    ) throws {
        guard activeRuns.clauseBoundary == nil, activeRuns.contentPriority == nil else {
            throw ProcessingMetadataStoreError.publishedRunsChanged
        }
        try updateAttempt(attemptID: attemptID) { metadata in
            metadata.finalizationAttempt = FinalizationAttempt(
                attemptID: attemptID,
                state: .complete,
                failureReason: nil
            )
            metadata.activeRuns = activeRuns
            metadata.pendingClauseBoundarySegments = pendingClauseBoundarySegments
            metadata.pendingContentPriorityClauses = []
        }
    }

    /// Publishes a Jev snapshot in one write: both run pointers and both pending lists. Fails
    /// when the published runs are no longer the ones the snapshot was built from.
    public func publishJevSnapshot(
        basedOn published: ActiveRuns,
        clauseBoundaryRunID: String,
        contentPriorityRunID: String,
        pendingClauseBoundarySegments: [SegmentTextReference],
        pendingContentPriorityClauses: [ClauseReference]
    ) throws {
        try update { metadata in
            guard let current = metadata.activeRuns, current.selectsSameRuns(as: published),
                  metadata.finalizationAttempt?.state == .complete else {
                throw ProcessingMetadataStoreError.publishedRunsChanged
            }
            metadata.activeRuns = current.withJevRuns(
                clauseBoundary: clauseBoundaryRunID, contentPriority: contentPriorityRunID
            )
            metadata.pendingClauseBoundarySegments = pendingClauseBoundarySegments
            metadata.pendingContentPriorityClauses = pendingContentPriorityClauses
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
