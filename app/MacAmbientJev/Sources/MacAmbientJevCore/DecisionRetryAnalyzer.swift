import Foundation
/// The decision results a retry must request again, checked against the event log.
public struct DecisionRetryTargets: Sendable, Equatable {
    public let boundarySegments: [SegmentTextReference]
    public let clauses: [ClauseReference]
    public var pendingTargets: Set<DecisionPendingTarget> {
        Set(boundarySegments.map(DecisionPendingTarget.boundary) + clauses.map(DecisionPendingTarget.priority))
    }

    public init(boundarySegments: [SegmentTextReference], clauses: [ClauseReference]) {
        self.boundarySegments = boundarySegments
        self.clauses = clauses
    }
}

/// Checks whether a generation has unselected decision work in its event-log suffix.
public struct DecisionRetryAnalyzer: Sendable {
    public init() {}

    /// A decision run was saved after the latest selection without publishing it.
    public func hasUnpublishedDecisionRun(lines: [Data], sessionID: UUID) throws -> Bool {
        let decoded = try EventLogLine.decode(lines)
        guard let generation = try GenerationEventLog(lines: decoded, sessionID: sessionID) else { return false }
        let initial = generation.generation.runs
        let excluded = Set([
            generation.runs.segmentation, generation.runs.asr,
            generation.runs.clauseBoundary, generation.runs.contentPriority,
            initial.segmentation, initial.asr, initial.clauseBoundary, initial.contentPriority
        ].compactMap { $0 })
        struct CandidateRun {
            let eventSeq: UInt64
            let stage: ProcessingStage
        }
        var candidates: [String: CandidateRun] = [:]
        for line in generation.lines where line.header.eventSeq > generation.selectionSeq
            && line.header.eventType == "processing.run.started" {
            guard let object = try JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let stage = payload["stage"] as? String,
                  stage == ProcessingStage.clauseBoundary.rawValue || stage == ProcessingStage.contentPriority.rawValue else {
                continue
            }
            let runID = try line.requiredRunID()
            guard !excluded.contains(runID) else { continue }
            guard line.header.sessionID == sessionID else { throw line.malformed }
            let started = try line.body(PayloadBody<ProcessingRunStartedPayload>.self).payload
            if candidates[runID] == nil {
                candidates[runID] = CandidateRun(eventSeq: line.header.eventSeq, stage: started.stage)
            }
        }

        var completedRuns: Set<String> = []
        var failedRuns: Set<String> = []
        for line in generation.lines where line.header.eventType == "processing.run.completed" {
            guard let runID = line.header.processingRunID, let candidate = candidates[runID],
                  line.header.eventSeq > candidate.eventSeq else { continue }
            guard line.header.sessionID == sessionID else { throw line.malformed }
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
}
