import Foundation

extension ClauseEventLog {
    /// A selected empty local stage still needs its successful completion record.
    func validateLocalRuns(_ activeRuns: ActiveRuns) throws {
        let selected: [(ProcessingStage, String?)] = [
            (.segmentation, activeRuns.segmentation), (.asr, activeRuns.asr),
            (.diarization, activeRuns.diarization), (.scene, activeRuns.scene), (.scope, activeRuns.scope)
        ]
        for (stage, selectedRunID) in selected {
            guard let runID = selectedRunID else { continue }
            if let run = runs[runID], run.stage != stage {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "公開されたローカル run の段階が一致しません")
            }
            guard hasLocalEvidence(for: stage, runID: runID) || runs[runID]?.completed == true else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "公開されたローカル run の結果がありません")
            }
        }
    }

    /// The published snapshot: both Jev runs complete over exactly the active ASR sources.
    func publishedRuns(_ activeRuns: ActiveRuns) throws -> (boundary: BoundaryRun, priority: PriorityRun)? {
        try validateLocalRuns(activeRuns)
        guard let boundaryRunID = activeRuns.clauseBoundary else {
            guard activeRuns.contentPriority == nil else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(
                    runID: activeRuns.contentPriority ?? "", reason: "境界判定 run なしに優先度 run が公開されています"
                )
            }
            return nil
        }
        let boundary = try boundaryRun(boundaryRunID)
        guard boundary.complete else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "公開された境界判定 run が完了していません")
        }
        guard let segmentationRunID = activeRuns.segmentation, let asrRunID = activeRuns.asr,
              boundary.inputs.map(\.input.source) == recognizedSources(segmentationRunID: segmentationRunID, asrRunID: asrRunID) else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "境界判定の対象が公開された文字起こしと一致しません")
        }
        guard let priorityRunID = activeRuns.contentPriority else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "優先度 run が公開されていません")
        }
        let priority = try priorityRun(priorityRunID, boundary: boundary)
        guard priority.complete else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: priorityRunID, reason: "公開された優先度 run が完了していません")
        }
        return (boundary, priority)
    }
}
