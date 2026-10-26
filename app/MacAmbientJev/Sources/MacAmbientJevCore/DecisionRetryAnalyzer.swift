import Foundation
/// The decision results a retry must request again, checked against the event log.
public struct DecisionRetryTargets: Sendable, Equatable {
    public let boundarySegments: [SegmentTextReference]
    public let clauses: [ClauseReference]

    public init(boundarySegments: [SegmentTextReference], clauses: [ClauseReference]) {
        self.boundarySegments = boundarySegments
        self.clauses = clauses
    }
}

/// Checks the pending lists of the published metadata against the event log. An unpublished
/// retry or finalization run is never adopted: retries start again from the published snapshot.
public struct DecisionRetryAnalyzer: Sendable {
    public init() {}

    /// A newer final/retry decision run was saved without atomically publishing its snapshot.
    /// Live runs and runs replaced by the current published snapshot are not recovery work.
    public func hasUnpublishedDecisionRun(lines: [Data], activeRuns: ActiveRuns) throws -> Bool {
        let decoded = try EventLogLine.decode(lines)
        let active = Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization,
            activeRuns.clauseBoundary, activeRuns.contentPriority
        ].compactMap { $0 })
        let watermark = decoded.lazy.filter {
            ($0.header.eventType == "processing.run.started" || $0.header.eventType == "processing.run.completed")
                && $0.header.processingRunID.map(active.contains) == true
        }.map(\.header.eventSeq).max() ?? 0
        struct CandidateRun {
            let eventSeq: UInt64
            let stage: ProcessingStage
        }
        var candidates: [String: CandidateRun] = [:]
        for line in decoded where line.header.eventSeq > watermark && line.header.eventType == "processing.run.started" {
            guard let object = try JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let raw = object["payload"] as? [String: Any],
                  let rawStage = raw["stage"] as? String,
                  rawStage == ProcessingStage.clauseBoundary.rawValue || rawStage == ProcessingStage.contentPriority.rawValue,
                  let provenance = raw["provenance"] as? [String: Any],
                  let configuration = provenance["configuration"] as? [String: Any],
                  let mode = configuration["mode"] as? String, mode == "final" || mode == "retry" else { continue }
            let started = try line.body(PayloadBody<ProcessingRunStartedPayload>.self).payload
            let runID = try line.requiredRunID()
            guard !active.contains(runID) else { continue }
            if candidates[runID] == nil {
                candidates[runID] = CandidateRun(eventSeq: line.header.eventSeq, stage: started.stage)
            }
        }

        var completedRuns: Set<String> = []
        var failedRuns: Set<String> = []
        for line in decoded where line.header.eventType == "processing.run.completed" {
            guard let runID = line.header.processingRunID, let candidate = candidates[runID],
                  line.header.eventSeq > candidate.eventSeq else { continue }
            let completed = try line.body(PayloadBody<ProcessingRunCompletedPayload>.self).payload
            _ = try line.requiredRunID()
            guard completed.stage == candidate.stage,
                  completed.completedCount >= 0, completed.failedCount >= 0 else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(
                    runID: runID, reason: "run の完了記録が開始記録と一致しません"
                )
            }
            guard completedRuns.insert(runID).inserted else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "run の完了記録が重複しています")
            }
            if !completed.succeeded { failedRuns.insert(runID) }
        }
        return candidates.keys.contains { !failedRuns.contains($0) }
    }

    public func retryTargets(lines: [Data], metadata: ProcessingMetadata) throws -> DecisionRetryTargets {
        guard let activeRuns = metadata.activeRuns,
              let segmentationRunID = activeRuns.segmentation, let asrRunID = activeRuns.asr else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "公開された文字起こしがありません")
        }
        let log = try ClauseEventLog(lines: EventLogLine.decode(lines), selectedRuns: Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization,
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
        return DecisionRetryTargets(boundarySegments: expectedBoundary, clauses: expectedClauses)
    }
}
