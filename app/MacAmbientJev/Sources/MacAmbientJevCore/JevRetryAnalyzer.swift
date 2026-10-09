import Foundation
/// The Jev results a retry must request again, checked against the event log.
public struct JevRetryTargets: Sendable, Equatable {
    public let boundarySegments: [SegmentTextReference]
    public let clauses: [ClauseReference]

    public init(boundarySegments: [SegmentTextReference], clauses: [ClauseReference]) {
        self.boundarySegments = boundarySegments
        self.clauses = clauses
    }
}

/// Checks the pending lists of the published metadata against the event log. An unpublished
/// retry or finalization run is never adopted: retries start again from the published snapshot.
public struct JevRetryAnalyzer: Sendable {
    public init() {}

    /// A newer final/retry Jev run was saved without atomically publishing its snapshot.
    /// Live runs and runs replaced by the current published snapshot are not recovery work.
    public func hasUnpublishedJevRun(lines: [Data], activeRuns: ActiveRuns) throws -> Bool {
        let decoded = try EventLogLine.decode(lines)
        let active = Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization, activeRuns.scene,
            activeRuns.scope, activeRuns.clauseBoundary, activeRuns.contentPriority
        ].compactMap { $0 })
        let watermark = decoded.lazy.filter {
            ($0.header.eventType == "processing.run.started" || $0.header.eventType == "processing.run.completed")
                && $0.header.processingRunID.map(active.contains) == true
        }.map(\.header.eventSeq).max() ?? 0
        var found = false
        for line in decoded where line.header.eventSeq > watermark && line.header.eventType == "processing.run.started" {
            guard let object = try JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let raw = object["payload"] as? [String: Any],
                  let stage = raw["stage"] as? String,
                  stage == ProcessingStage.clauseBoundary.rawValue || stage == ProcessingStage.contentPriority.rawValue,
                  let provenance = raw["provenance"] as? [String: Any],
                  let configuration = provenance["configuration"] as? [String: Any],
                  let mode = configuration["mode"] as? String, mode == "final" || mode == "retry" else { continue }
            _ = try line.body(PayloadBody<ProcessingRunStartedPayload>.self)
            let runID = try line.requiredRunID()
            if !active.contains(runID) { found = true }
        }
        return found
    }

    public func retryTargets(lines: [Data], metadata: ProcessingMetadata) throws -> JevRetryTargets {
        guard let activeRuns = metadata.activeRuns,
              let segmentationRunID = activeRuns.segmentation, let asrRunID = activeRuns.asr else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "公開された文字起こしがありません")
        }
        let log = try ClauseEventLog(lines: EventLogLine.decode(lines), selectedRuns: Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization, activeRuns.scene, activeRuns.scope,
            activeRuns.clauseBoundary, activeRuns.contentPriority
        ].compactMap { $0 }))
        let expectedBoundary: [SegmentTextReference]
        let expectedClauses: [ClauseReference]
        if let published = try log.publishedRuns(activeRuns) {
            expectedBoundary = published.boundary.pendingSources
            expectedClauses = published.boundary.clauses.map(\.unit.reference).filter {
                published.priority.assignments[$0]?.needsRetry == true
            }
        } else {
            expectedBoundary = log.recognizedSources(segmentationRunID: segmentationRunID, asrRunID: asrRunID)
            expectedClauses = []
        }
        guard metadata.pendingClauseBoundarySegments == expectedBoundary,
              metadata.pendingContentPriorityClauses == expectedClauses else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: activeRuns.clauseBoundary ?? asrRunID, reason: "処理状態の保留一覧がイベントログと一致しません"
            )
        }
        return JevRetryTargets(boundarySegments: expectedBoundary, clauses: expectedClauses)
    }
}
