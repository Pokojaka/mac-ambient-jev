import Foundation

extension ClauseEventLog {
    func decisionRuns(_ selected: ActiveRuns, requireCompletion: Bool, selectedBefore: UInt64? = nil) throws -> (boundary: BoundaryRun?, priority: PriorityRun?) {
        func fail(_ runID: String, _ reason: String) -> EventLogTranscriptReaderError {
            .inconsistentClauseRun(runID: runID, reason: reason)
        }
        guard let boundaryID = selected.clauseBoundary, let priorityID = selected.contentPriority else {
            guard selected.clauseBoundary == nil, selected.contentPriority == nil else {
                throw fail(selected.contentPriority ?? selected.clauseBoundary ?? "", "境界判定と優先度の run が対になっていません")
            }
            return (nil, nil)
        }
        let boundaryStart = runs[boundaryID], priorityStart = runs[priorityID]
        guard priorityStart == nil || boundaryStart != nil else {
            throw fail(priorityID, "境界判定 run なしに優先度 run があります")
        }
        guard let segmentationID = selected.segmentation, let asrID = selected.asr else {
            throw fail(boundaryID, "判定に対応する文字起こし run がありません")
        }
        let recognized = recognizedSources(segmentationRunID: segmentationID, asrRunID: asrID)
            .filter { source in selectedBefore.map { source.asrEventSeq < $0 } ?? true }
        let boundary = try boundaryStart == nil ? nil : boundaryRun(boundaryID)
        let priority: PriorityRun?
        if priorityStart == nil { priority = nil }
        else {
            guard let boundary else { throw fail(priorityID, "境界判定 run なしに優先度 run があります") }
            priority = try priorityRun(priorityID, boundary: boundary)
        }
        let mustComplete = requireCompletion || selectedBefore != nil
        if let boundary {
            let inputs = boundary.inputs.map(\.input.source)
            guard inputs == (mustComplete ? recognized : Array(recognized.prefix(inputs.count))) else {
                throw fail(boundaryID, "境界判定の対象が認識済みの文字起こしと一致しません")
            }
        }
        if mustComplete {
            if boundaryStart != nil || !recognized.isEmpty {
                guard boundary?.complete == true else { throw fail(boundaryID, "認識済み原文の境界判定 run が完了していません") }
            }
            let needsPriority = try boundary.map { run in try run.clauses.contains {
                guard let text = run.clauseTexts[$0.unit.reference] else { throw fail(boundaryID, "閉じた節の本文がありません") }
                return !ClauseTextComposer.isBlank(text)
            } } ?? false
            if priorityStart != nil || needsPriority {
                guard priority?.complete == true else { throw fail(priorityID, "節の優先度 run が完了していません") }
            }
        }
        if let marker = selectedBefore {
            for (id, stage) in [(boundaryID, ProcessingStage.clauseBoundary), (priorityID, .contentPriority)] {
                guard let run = runs[id], run.stage == stage, run.completed,
                      let completionSeq = run.completionSeq, completionSeq < marker else {
                    throw fail(id, "置換前に選択された判定 run が完了していません")
                }
            }
        }
        return (boundary, priority)
    }
}
