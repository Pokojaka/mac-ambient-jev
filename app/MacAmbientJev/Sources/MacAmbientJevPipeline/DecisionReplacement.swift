import Foundation
import MacAmbientJevCore

/// The selected decision pair's saved results that a replacement pair carries over unchanged.
struct ReplacementCarry: Sendable {
    let boundaryRunID: String?
    let priorityRunID: String?
    /// The selected boundary run's saved events, shown when the replacement keeps that run.
    let boundaryEvents: [TranscriptEvent]
    let clauses: [ClauseUnit]
    private var boundaryStates: [SegmentTextReference: (seq: UInt64, state: ClauseBoundaryState)] = [:]
    private var clausesByParts: [[ClauseSourcePart]: ClauseReference] = [:]
    private var assignments: [ClauseReference: (seq: UInt64, assignment: ClausePriorityAssignment)] = [:]

    init(events: [TranscriptEvent], runs: ActiveRuns) {
        boundaryRunID = runs.clauseBoundary
        priorityRunID = runs.contentPriority
        var boundaryEvents: [TranscriptEvent] = []
        var clauses: [ClauseUnit] = []
        for event in events.sorted(by: { $0.eventSeq < $1.eventSeq }) {
            switch event.kind {
            case .clauseBoundaryAssessed(let assessment) where event.processingRunID == runs.clauseBoundary:
                boundaryStates[assessment.source] = (event.eventSeq, .assessed(assessment))
                boundaryEvents.append(event)
            case .clauseBoundaryPending(let payload) where event.processingRunID == runs.clauseBoundary:
                boundaryStates[payload.source] = (event.eventSeq, .pending(reason: payload.reason, message: payload.message))
                boundaryEvents.append(event)
            case .clauseClosed(let unit) where event.processingRunID == runs.clauseBoundary:
                clauses.append(unit)
                clausesByParts[unit.parts] = unit.reference
                boundaryEvents.append(event)
            case .contentPriorityAssigned(let payload) where event.processingRunID == runs.contentPriority:
                for assignment in payload.assignments { assignments[assignment.reference] = (event.eventSeq, assignment) }
            default:
                break
            }
        }
        self.boundaryEvents = boundaryEvents
        self.clauses = clauses
    }

    /// The saved boundary state of a source as the replacement run records it: an assessment as carried
    /// over from its event, a pending result as pending.
    func carriedState(of source: SegmentTextReference) throws -> ClauseBoundaryState {
        guard let runID = boundaryRunID, let saved = boundaryStates[source] else {
            throw LiveContentPriorityError.missingCarriedDecision
        }
        switch saved.state {
        case .assessed(let assessment):
            return .assessed(try assessment.carriedOver(fromRunID: runID, eventSeq: saved.seq))
        case .pending:
            return saved.state
        }
    }

    /// The saved assignment of the clause made of exactly these parts, if any.
    func assignment(forParts parts: [ClauseSourcePart]) -> (seq: UInt64, assignment: ClausePriorityAssignment)? {
        clausesByParts[parts].flatMap { assignments[$0] }
    }

    /// Filler removal of the saved assessments, so carried clauses compose the text they were classified on.
    func composer() -> ClauseTextComposer {
        var composer = ClauseTextComposer()
        for (source, saved) in boundaryStates {
            if case .assessed(let assessment) = saved.state { composer.setFillerRanges(assessment.fillerRanges, for: source) }
        }
        return composer
    }
}

/// A replacement decision pair: which results it requests again and what it carries over.
struct ReplacementPlan: Sendable {
    let boundaryRunID: String
    let priorityRunID: String
    let boundaryTargets: Set<SegmentTextReference>
    let clauseTargets: Set<ClauseReference>
    let carry: ReplacementCarry
    /// Only priorities are requested again: the selected boundary run stays selected.
    let keepsBoundaryRun: Bool
}
