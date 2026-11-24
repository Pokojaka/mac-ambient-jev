import Foundation
import MacAmbientJevCore

/// The saved ASR results a decision session reads, and the rows it shows its own decisions on.
protocol DecisionTranscriptSource: Sendable {
    func snapshot() async -> LiveASRSnapshot
    @discardableResult
    func applyClauseEvents(_ events: [TranscriptEvent]) async throws -> LiveASRSnapshot
}

extension LiveASRSession: DecisionTranscriptSource {}

/// A finished generation's saved ASR results, read-only, with rows for one replacement decision pair.
/// It writes nothing: opening a live ASR session would show only the generation's initial decision pair.
actor StoredTranscriptSource: DecisionTranscriptSource {
    private let activeRuns: ActiveRuns
    private let materializer: IncrementalTranscriptMaterializer
    private let statuses: [LiveASRSegmentStatus]
    private let completedCount: Int
    private var events: [TranscriptEvent]

    init(state: ProcessingLogState, boundaryRunID: String, priorityRunID: String) throws {
        activeRuns = ActiveRuns(
            segmentation: state.segmentationRunID, asr: state.asrRunID,
            clauseBoundary: boundaryRunID, contentPriority: priorityRunID
        )
        materializer = IncrementalTranscriptMaterializer(
            sampleRate: state.generation.sampleRate,
            segmentationRunID: state.segmentationRunID, asrRunID: state.asrRunID,
            clauseBoundaryRunID: boundaryRunID
        )
        var recognized: [String: LiveASRSegmentStatus.Outcome] = [:]
        for event in state.events {
            try materializer.appendSourceEvent(event)
            guard case .asrCompleted(let result) = event.kind else { continue }
            guard let segmentID = event.segmentID, let source = try event.asrSource() else {
                throw TranscriptMaterializationError.missingClauseSource
            }
            recognized[segmentID] = .recognized(source, result.text)
        }
        statuses = state.segments.map {
            LiveASRSegmentStatus(segmentID: $0.segmentID, startFrame: $0.startFrame,
                                 outcome: recognized[$0.segmentID] ?? .pending)
        }
        completedCount = recognized.count
        events = state.events
    }

    func snapshot() -> LiveASRSnapshot {
        LiveASRSnapshot(
            events: events, activeRuns: activeRuns,
            progress: LiveASRProgress(
                materializedSegments: materializer.materializedSegments,
                completedCount: completedCount, failedCount: 0, pendingCount: statuses.count - completedCount
            ),
            segments: statuses
        )
    }

    @discardableResult
    func applyClauseEvents(_ clauseEvents: [TranscriptEvent]) throws -> LiveASRSnapshot {
        for event in clauseEvents {
            switch event.kind {
            case .clauseBoundaryAssessed, .clauseBoundaryPending, .clauseClosed:
                guard event.processingRunID == activeRuns.clauseBoundary else { throw LiveASRSessionError.foreignClauseEvent }
            case .contentPriorityAssigned:
                guard event.processingRunID == activeRuns.contentPriority else { throw LiveASRSessionError.foreignClauseEvent }
            default:
                throw LiveASRSessionError.foreignClauseEvent
            }
        }
        try materializer.applyClauseEvents(clauseEvents)
        events.append(contentsOf: clauseEvents)
        return snapshot()
    }
}
