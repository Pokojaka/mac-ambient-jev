import Foundation

public enum ClauseEventType {
    public static let boundaryAssessed = "clause_boundaries.assessed"
    public static let boundaryPending = "clause_boundaries.pending"
    public static let clauseClosed = "clauses.closed"
    public static let priorityAssigned = "content_priority.assigned"
}

/// What each decision run records about the clause tagger and policy.
public enum DecisionRunProvenance {
    private static let engine = "coreml-clause-tagger"
    private static let unitPolicy = "btsj-utterance-sentence"
    private static let encodingRevision = "1"
    private static let maximumTokens = "192"
    private static let computeUnits = "cpu-only"

    /// `mode` is `live`, `final` or `retry`.
    public static func boundary(mode: String, identity: DecisionModelIdentity) -> RunProvenance {
        var configuration = commonConfiguration(identity: identity, mode: mode)
        configuration["candidate_characters"] = "、。？！?!"
        configuration["boundary_threshold"] = String(ClauseBoundaryPolicy.boundaryThreshold)
        configuration["continuation_threshold"] = String(ClauseBoundaryPolicy.continuationThreshold)
        configuration["next_head_character_limit"] = String(ClauseBoundaryPolicy.nextHeadCharacterLimit)
        configuration["window_content_tokens"] = "190"
        configuration["window_policy"] = "whole-piece-max-min-context"
        configuration["span_policy"] = "argmax-o-f-d-f-only"
        configuration["span_window_policy"] = "whole-piece-max-min-context"
        configuration["text_policy"] = "neutral-punctuation-piecewise"
        return RunProvenance(engine: engine, model: identity.model, version: identity.modelRevision, configuration: configuration)
    }

    public static func priority(mode: String, identity: DecisionModelIdentity) -> RunProvenance {
        var configuration = commonConfiguration(identity: identity, mode: mode)
        configuration["minimum_demotion_confidence"] = String(ContentPriorityPolicy.minimumDemotionConfidence)
        configuration["maximum_targets"] = String(PriorityBatchPolicy.maximumTargets)
        configuration["text_policy"] = "filler-removed-neutral-punctuation-piecewise"
        return RunProvenance(engine: engine, model: identity.model, version: identity.modelRevision, configuration: configuration)
    }

    /// A live run whose tagger could not be loaded.
    public static func unavailable(mode: String) -> RunProvenance {
        RunProvenance(engine: "unavailable", model: nil, version: "1", configuration: [
            "mode": mode,
            "unit_policy": unitPolicy,
        ])
    }

    private static func commonConfiguration(identity: DecisionModelIdentity, mode: String) -> [String: String] {
        [
            "model_id": identity.model,
            "model_revision": identity.modelRevision,
            "unit_policy": unitPolicy,
            "mode": mode,
            "encoding_revision": encodingRevision,
            "max_tokens": maximumTokens,
            "compute_units": computeUnits,
        ]
    }
}

public enum DecisionPendingMessage {
    public static let notRequested = "判定を実行していないため保留しました"
    public static let asrGap = "次の区間を音声認識できなかったため境界を判定できません"
}

/// One boundary request for one source, or the pending state when it cannot be sent.
public enum ClauseBoundaryStep {
    public static func assess(
        source: SegmentTextReference,
        text: String,
        next: NextSegmentHead?,
        decisions: DecisionCoordinator
    ) async throws -> ClauseBoundaryState {
        let request = try ClauseBoundaryRequest(source: source, text: text, next: next)
        switch await decisions.assessBoundaries(request) {
        case .answered(let response, let record):
            return .assessed(try ClauseBoundaryAssessment(
                source: source, candidates: request.candidates, probabilities: response.probabilities,
                nextHead: next, continuationProbability: response.continuationProbability,
                fillerRanges: response.fillerRanges, request: record, sourceDecision: .assessed
            ))
        case .failed(let message):
            return .pending(reason: .requestFailed, message: message)
        case .cancelled:
            throw CancellationError()
        }
    }
}

public enum DecisionEnrichmentError: LocalizedError, Sendable, Equatable {
    case missingPublishedTranscript
    case missingPublishedDecisionRuns
    case unknownRetryTarget(String)
    case missingNextASRSource(segmentID: String)
    case boundaryRunNotNew
    case boundaryRunMismatch
    case invalidPriorityRun
    case invalidSourceTimeline

    public var errorDescription: String? {
        switch self {
        case .missingPublishedTranscript:
            "確定済みの文字起こしがありません"
        case .missingPublishedDecisionRuns:
            "公開済みの境界判定と優先度判定がありません"
        case .unknownRetryTarget(let target):
            "再試行の対象 \(target) は公開済みの保留ではありません"
        case .missingNextASRSource(let segmentID):
            "区間 \(segmentID) の次の区間に音声認識結果がないため、境界を再判定できません。録音を再処理してください"
        case .boundaryRunNotNew:
            "境界の再判定には新しい境界判定 run が必要です"
        case .boundaryRunMismatch:
            "優先度だけの再試行は公開済みの境界判定 run を使います"
        case .invalidPriorityRun:
            "優先度判定には境界判定と異なる新しい run が必要です"
        case .invalidSourceTimeline:
            "音声認識の原文区間、範囲、または順序が不正です"
        }
    }
}

public struct DecisionEnrichmentBatchResult: Sendable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let pendingBoundarySegments: [SegmentTextReference]
    public let pendingPriorityClauses: [ClauseReference]
    public let boundaryRunID: String
    public let priorityRunID: String

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        pendingBoundarySegments: [SegmentTextReference],
        pendingPriorityClauses: [ClauseReference],
        boundaryRunID: String,
        priorityRunID: String
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.pendingBoundarySegments = pendingBoundarySegments
        self.pendingPriorityClauses = pendingPriorityClauses
        self.boundaryRunID = boundaryRunID
        self.priorityRunID = priorityRunID
    }

    public var pendingTargets: Set<DecisionPendingTarget> {
        Set(pendingBoundarySegments.map(DecisionPendingTarget.boundary))
            .union(pendingPriorityClauses.map(DecisionPendingTarget.priority))
    }
}

/// Which results a decision snapshot requests.
public enum DecisionEnrichmentScope: Sendable {
    /// Every segment of a new transcript: one boundary request per segment, then every clause.
    case all
    /// Only these pending results. Every other published result is carried over. With no
    /// boundary segment the published boundary run is kept and only priorities are requested.
    case retry(boundarySegments: Set<SegmentTextReference>, clauses: Set<ClauseReference>)
}

/// Builds one decision snapshot of a published transcript: a boundary run, then a priority run.
/// The caller publishes the returned runs and pending lists in one metadata write.
public actor DecisionEnrichmentCoordinator {
    private let sessionID: UUID
    private let boundaryRunID: String
    private let priorityRunID: String
    private let writer: SessionWriter
    private let decisions: DecisionCoordinator
    private let usageCounter: DecisionUsageCounter
    private let materializer: TranscriptMaterializer

    private var events: [TranscriptEvent] = []
    private var onEvent: ((TranscriptEvent) async -> Void)?

    public init(
        sessionID: UUID,
        boundaryRunID: String,
        priorityRunID: String,
        writer: SessionWriter,
        decisions: DecisionCoordinator,
        usageCounter: DecisionUsageCounter,
        materializer: TranscriptMaterializer
    ) {
        self.sessionID = sessionID
        self.boundaryRunID = boundaryRunID
        self.priorityRunID = priorityRunID
        self.writer = writer
        self.decisions = decisions
        self.usageCounter = usageCounter
        self.materializer = materializer
    }

    /// After the caller published `result`, replaces the pending targets of the snapshot it
    /// replaced with the new ones. Request and token counts are not changed.
    public func recordPublished(_ result: DecisionEnrichmentBatchResult, replacing previous: Set<DecisionPendingTarget>) async {
        await usageCounter.clearDeferred(sessionID: sessionID, targets: previous)
        await usageCounter.recordDeferred(sessionID: sessionID, targets: result.pendingTargets)
    }

    public func process(
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns,
        scope: DecisionEnrichmentScope,
        reusableDecisions: [ExactClauseTextKey: ReusableClauseDecision],
        onEvent: ((TranscriptEvent) async -> Void)?
    ) async throws -> DecisionEnrichmentBatchResult {
        try Task.checkCancellation()
        self.onEvent = onEvent
        events = existingEvents
        guard !priorityRunID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              priorityRunID != boundaryRunID,
              priorityRunID != activeRuns.contentPriority else {
            throw DecisionEnrichmentError.invalidPriorityRun
        }
        guard !boundaryRunID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClauseRecordError.invalidClauseReference
        }
        var rebuildsUnpublishedSnapshot = false
        if case .retry = scope {
            let recovered = try SessionRecovery.recoverJSONL(
                SessionWriter.readDurableLog(eventsURL: writer.eventsURL)
            )
            guard !recovered.droppedIncompleteTail else {
                throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
            }
            rebuildsUnpublishedSnapshot = try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(
                lines: recovered.lines, activeRuns: activeRuns
            )
        }
        if !reusableDecisions.isEmpty {
            let recovered = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: writer.eventsURL))
            guard !recovered.droppedIncompleteTail else {
                throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
            }
            let log = try ClauseEventLog(lines: EventLogLine.decode(recovered.lines),
                selectedRuns: Set(reusableDecisions.values.flatMap {
                    [$0.sourcePriorityRunID, $0.sourceClause.boundaryRunID]
                }), sessionID: sessionID)
            try log.validateReusableDecisions(reusableDecisions)
        }
        _ = try materializer.materialize(events: existingEvents, activeRuns: activeRuns)
        let timeline = try SourceTimeline(events: existingEvents, activeRuns: activeRuns)
        let published = try PublishedDecisionSnapshot(events: existingEvents, activeRuns: activeRuns)
        let mode: String
        let boundaryTargets: Set<SegmentTextReference>?
        let clauseTargets: Set<ClauseReference>
        switch scope {
        case .all:
            mode = "final"
            boundaryTargets = nil
            clauseTargets = []
        case .retry(let segments, let clauses):
            mode = "retry"
            boundaryTargets = segments
            clauseTargets = clauses
            try validateRetry(segments: segments, clauses: clauses, published: published, timeline: timeline)
        }
        let rebuildsBoundaries = rebuildsUnpublishedSnapshot || (boundaryTargets.map { !$0.isEmpty } ?? true)
        if rebuildsBoundaries {
            guard boundaryRunID != activeRuns.clauseBoundary else { throw DecisionEnrichmentError.boundaryRunNotNew }
        } else {
            guard boundaryRunID == activeRuns.clauseBoundary else { throw DecisionEnrichmentError.boundaryRunMismatch }
        }

        let clauses: [ClauseUnit]
        let pendingBoundary: [SegmentTextReference]
        if rebuildsBoundaries {
            (clauses, pendingBoundary) = try await buildBoundaryRun(
                timeline: timeline, published: published, carriedSegments: boundaryTargets, mode: mode
            )
        } else {
            clauses = published.clauses
            pendingBoundary = published.pendingSources
        }

        let assignments = try await buildPriorityRun(
            clauses: clauses, timeline: timeline, published: published,
            rebuildsBoundaries: rebuildsBoundaries, scope: scope, clauseTargets: clauseTargets,
            reusableDecisions: reusableDecisions, mode: mode
        )
        let pendingClauses = clauses.map(\.reference).filter { assignments[$0]?.needsRetry == true }
        let selected = activeRuns.withDecisionRuns(clauseBoundary: boundaryRunID, contentPriority: priorityRunID)
        return DecisionEnrichmentBatchResult(
            events: events,
            materializedSegments: try materializer.materialize(events: events, activeRuns: selected),
            pendingBoundarySegments: pendingBoundary,
            pendingPriorityClauses: pendingClauses,
            boundaryRunID: boundaryRunID,
            priorityRunID: priorityRunID
        )
    }

    // MARK: - Boundary run

    private func buildBoundaryRun(
        timeline: SourceTimeline,
        published: PublishedDecisionSnapshot,
        carriedSegments boundaryTargets: Set<SegmentTextReference>?,
        mode: String
    ) async throws -> (clauses: [ClauseUnit], pending: [SegmentTextReference]) {
        try await append(
            "processing.run.started", runID: boundaryRunID,
            payload: ProcessingRunStartedPayload(
                stage: .clauseBoundary,
                provenance: decisions.boundaryProvenance(mode: mode)
            ),
            kind: nil
        )
        var assembly = ClauseBoundaryAssembly(boundaryRunID: boundaryRunID)
        var clauses: [ClauseUnit] = []
        var pending: [SegmentTextReference] = []
        for (index, entry) in timeline.sources.enumerated() {
            try Task.checkCancellation()
            if timeline.hasEmptySeparator(beforeSourceAt: index) {
                _ = try assembly.endTextStream()
            }
            if timeline.hasMissingPredecessor(ofSourceAt: index) {
                _ = try assembly.beginAfterASRGap()
            }
            let state: ClauseBoundaryState
            if let targets = boundaryTargets, !targets.contains(entry.source) {
                state = try published.carriedState(of: entry.source)
            } else {
                state = try await requestBoundary(index: index, timeline: timeline)
            }
            switch state {
            case .assessed(let assessment):
                try await append(ClauseEventType.boundaryAssessed, runID: boundaryRunID, payload: assessment,
                                 kind: .clauseBoundaryAssessed(assessment))
            case .pending(let reason, let message):
                let payload = ClauseBoundaryPendingPayload(source: entry.source, reason: reason, message: message)
                try await append(ClauseEventType.boundaryPending, runID: boundaryRunID, payload: payload,
                                 kind: .clauseBoundaryPending(payload))
                pending.append(entry.source)
            }
            let delta = try assembly.consume(ClauseAssemblyInput(source: entry.source, text: entry.text, state: state))
            clauses += try await appendClosed(delta.closed)
            if case .empty = timeline.successor(ofSourceAt: index) {
                _ = try assembly.endTextStream()
            }
        }
        clauses += try await appendClosed(try assembly.finish().closed)
        try await append(
            "processing.run.completed", runID: boundaryRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .clauseBoundary, succeeded: true,
                completedCount: timeline.sources.count - pending.count, failedCount: pending.count
            ),
            kind: nil
        )
        return (clauses, pending)
    }

    private func requestBoundary(index: Int, timeline: SourceTimeline) async throws -> ClauseBoundaryState {
        let entry = timeline.sources[index]
        let next: NextSegmentHead?
        switch timeline.successor(ofSourceAt: index) {
        case .missing:
            return .pending(reason: .asrGap, message: DecisionPendingMessage.asrGap)
        case .none, .empty:
            next = nil
        case .recognized(let source, let text):
            next = try NextSegmentHead(source: source, text: String(text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)))
        }
        return try await ClauseBoundaryStep.assess(
            source: entry.source, text: entry.text, next: next, decisions: decisions
        )
    }

    private func appendClosed(_ units: [ClauseUnit]) async throws -> [ClauseUnit] {
        for unit in units {
            try await append(ClauseEventType.clauseClosed, runID: boundaryRunID, payload: unit, kind: .clauseClosed(unit))
        }
        return units
    }

    // MARK: - Priority run

    private func buildPriorityRun(
        clauses: [ClauseUnit],
        timeline: SourceTimeline,
        published: PublishedDecisionSnapshot,
        rebuildsBoundaries: Bool,
        scope: DecisionEnrichmentScope,
        clauseTargets: Set<ClauseReference>,
        reusableDecisions: [ExactClauseTextKey: ReusableClauseDecision],
        mode: String
    ) async throws -> [ClauseReference: ClausePriorityAssignment] {
        try await append(
            "processing.run.started", runID: priorityRunID,
            payload: ProcessingRunStartedPayload(
                stage: .contentPriority,
                provenance: decisions.priorityProvenance(mode: mode)
            ),
            kind: nil
        )
        var composer = ClauseTextComposer()
        for event in self.events {
            guard event.processingRunID == boundaryRunID,
                  case .clauseBoundaryAssessed(let assessment) = event.kind else { continue }
            composer.setFillerRanges(assessment.fillerRanges, for: assessment.source)
        }
        var reusablePublished: [ExactClauseTextKey: (seq: UInt64, assignment: ClausePriorityAssignment)] = [:]
        var publishedTextKeys: [ClauseReference: ExactClauseTextKey] = [:]
        if case .retry = scope, rebuildsBoundaries {
            var publishedComposer = ClauseTextComposer()
            for (source, saved) in published.boundaryStates {
                if case .assessed(let assessment) = saved.state {
                    publishedComposer.setFillerRanges(assessment.fillerRanges, for: source)
                }
            }
            for unit in published.clauses {
                let text = try publishedComposer.text(of: unit.parts, sourceText: timeline.text(of:))
                let key = ExactClauseTextKey(text: text)
                publishedTextKeys[unit.reference] = key
                guard let origin = published.assignments[unit.reference], !origin.assignment.needsRetry else { continue }
                if reusablePublished[key].map({ $0.seq < origin.seq }) ?? true {
                    reusablePublished[key] = origin
                }
            }
        }
        var carried: [ClausePriorityAssignment] = []
        var targets: [(reference: ClauseReference, text: String)] = []
        for unit in clauses {
            let text = try composer.text(of: unit.parts, sourceText: timeline.text(of:))
            guard !ClauseTextComposer.isBlank(text) else { continue }
            let key = ExactClauseTextKey(text: text)
            let origin: (seq: UInt64, assignment: ClausePriorityAssignment)?
            switch scope {
            case .all:
                if let reuse = reusableDecisions[key] {
                    carried.append(try ClausePriorityAssignment(
                        reference: unit.reference, priority: reuse.visiblePriority, needsRetry: false,
                        decision: .carriedOver(
                            sourcePriorityRunID: reuse.sourcePriorityRunID, sourceEventSeq: reuse.sourceEventSeq,
                            sourceClause: reuse.sourceClause, sourceNeedsRetry: false
                        )
                    ))
                    continue
                }
                origin = nil
            case .retry:
                if rebuildsBoundaries {
                    let partsOrigin = published.assignment(forClauseWithParts: unit.parts)
                    if let partsOrigin, publishedTextKeys[partsOrigin.assignment.reference] == key {
                        origin = partsOrigin
                    } else {
                        origin = reusablePublished[key]
                    }
                } else {
                    origin = published.assignments[unit.reference]
                }
            }
            if let origin, !(origin.assignment.needsRetry && clauseTargets.contains(origin.assignment.reference)) {
                carried.append(try ClausePriorityAssignment(
                    reference: unit.reference, priority: origin.assignment.priority,
                    needsRetry: origin.assignment.needsRetry,
                    decision: .carriedOver(
                        sourcePriorityRunID: try published.priorityRunID(), sourceEventSeq: origin.seq,
                        sourceClause: origin.assignment.reference, sourceNeedsRetry: origin.assignment.needsRetry
                    )
                ))
            } else {
                targets.append((unit.reference, text))
            }
        }

        var payloads: [ContentPriorityAssignedPayload] = []
        if !carried.isEmpty {
            payloads.append(try ContentPriorityAssignedPayload(assignments: carried, request: nil))
            try await record(payloads[payloads.count - 1])
        }
        var batches = try ClausePriorityBatches(targets: targets)
        while batches.hasRemaining {
            let payload = try await batches.next { .available(self.decisions) }
            payloads.append(payload)
            try await record(payload)
        }
        var assignments: [ClauseReference: ClausePriorityAssignment] = [:]
        for payload in payloads {
            for assignment in payload.assignments { assignments[assignment.reference] = assignment }
        }
        let pendingCount = assignments.values.filter(\.needsRetry).count
        try await append(
            "processing.run.completed", runID: priorityRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .contentPriority, succeeded: true,
                completedCount: assignments.count - pendingCount, failedCount: pendingCount
            ),
            kind: nil
        )
        return assignments
    }

    private func record(_ payload: ContentPriorityAssignedPayload) async throws {
        try await append(ClauseEventType.priorityAssigned, runID: priorityRunID, payload: payload,
                         kind: .contentPriorityAssigned(payload))
    }

    // MARK: - Retry validation

    /// Every target is checked before any request, so an invalid retry leaves no run behind.
    private func validateRetry(
        segments: Set<SegmentTextReference>,
        clauses: Set<ClauseReference>,
        published: PublishedDecisionSnapshot,
        timeline: SourceTimeline
    ) throws {
        if !published.hasRuns {
            guard published.activeBoundaryRunID == nil, published.activePriorityRunID == nil,
                  clauses.isEmpty, !segments.isEmpty else {
                throw DecisionEnrichmentError.missingPublishedDecisionRuns
            }
            for source in segments {
                guard let index = timeline.sources.firstIndex(where: { $0.source == source }) else {
                    throw DecisionEnrichmentError.unknownRetryTarget(source.segmentID)
                }
                if case .missing = timeline.successor(ofSourceAt: index) {
                    throw DecisionEnrichmentError.missingNextASRSource(segmentID: source.segmentID)
                }
            }
            return
        }
        for source in segments {
            guard published.pendingSources.contains(source),
                  let index = timeline.sources.firstIndex(where: { $0.source == source }) else {
                throw DecisionEnrichmentError.unknownRetryTarget(source.segmentID)
            }
            if case .missing = timeline.successor(ofSourceAt: index) {
                throw DecisionEnrichmentError.missingNextASRSource(segmentID: source.segmentID)
            }
        }
        for clause in clauses {
            guard published.assignments[clause]?.assignment.needsRetry == true else {
                throw DecisionEnrichmentError.unknownRetryTarget(clause.clauseID)
            }
        }
    }

    private func append<Payload: Codable & Sendable>(
        _ eventType: String,
        runID: String,
        payload: Payload,
        kind: TranscriptEventKind?
    ) async throws {
        try Task.checkCancellation()
        let envelope = try await writer.append(EventDraft(
            eventType: eventType, sessionID: sessionID, processingRunID: runID, payload: payload
        ))
        guard let kind else { return }
        let event = TranscriptEvent.clause(seq: envelope.eventSeq, runID: runID, kind: kind)
        events.append(event)
        await onEvent?(event)
    }
}

/// The recognized sources of the published ASR run in time order, and what follows each.
struct SourceTimeline {
    enum Successor {
        case none
        case empty
        case missing
        case recognized(SegmentTextReference, String)
    }

    struct Entry {
        let source: SegmentTextReference
        let text: String
        let position: Int
    }

    /// Every segment of the active segmentation in time order, with its ASR result if any.
    private let segments: [(segmentID: String, result: (source: SegmentTextReference, text: String)?)]
    let sources: [Entry]
    private let texts: [SegmentTextReference: String]

    init(events: [TranscriptEvent], activeRuns: ActiveRuns) throws {
        guard let segmentationRunID = activeRuns.segmentation, activeRuns.asr != nil else {
            throw DecisionEnrichmentError.missingPublishedTranscript
        }
        var results: [String: (source: SegmentTextReference, text: String)] = [:]
        var created: [(segmentID: String, startFrame: Int64)] = []
        var createdIDs: Set<String> = []
        for event in events.sorted(by: { $0.eventSeq < $1.eventSeq }) {
            switch event.kind {
            case .segmentCreated where event.segmentationRunID == segmentationRunID:
                guard let segmentID = event.segmentID, let start = event.sourceStartFrame,
                      let end = event.sourceEndFrame, start >= 0, end > start,
                      createdIDs.insert(segmentID).inserted else {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                created.append((segmentID, start))
            case .asrCompleted(let result) where event.processingRunID == activeRuns.asr
                && event.segmentationRunID == segmentationRunID:
                guard let segmentID = event.segmentID, createdIDs.contains(segmentID),
                      let source = try event.asrSource() else {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                results[segmentID] = (source, result.text)
            default:
                break
            }
        }
        segments = created.sorted { $0.startFrame < $1.startFrame }.map { ($0.segmentID, results[$0.segmentID]) }
        var entries: [Entry] = []
        var texts: [SegmentTextReference: String] = [:]
        for (position, segment) in segments.enumerated() {
            guard let result = segment.result else { continue }
            texts[result.source] = result.text
            if ASRRecognitionOutcome(text: result.text) == .recognized {
                if let previous = entries.last, previous.source.asrEventSeq >= result.source.asrEventSeq {
                    throw DecisionEnrichmentError.invalidSourceTimeline
                }
                entries.append(Entry(source: result.source, text: result.text, position: position))
            }
        }
        sources = entries
        self.texts = texts
    }

    func successor(ofSourceAt index: Int) -> Successor {
        let next = sources[index].position + 1
        guard next < segments.count else { return .none }
        guard let result = segments[next].result else { return .missing }
        return ASRRecognitionOutcome(text: result.text) == .recognized ? .recognized(result.source, result.text) : .empty
    }

    /// An empty result since the preceding recognized source resets unresolved ranges,
    /// even when a missing ASR segment came between that source and the empty result.
    func hasEmptySeparator(beforeSourceAt index: Int) -> Bool {
        for position in stride(from: sources[index].position - 1, through: 0, by: -1) {
            guard let result = segments[position].result else { continue }
            return ASRRecognitionOutcome(text: result.text) != .recognized
        }
        return false
    }

    func hasMissingPredecessor(ofSourceAt index: Int) -> Bool {
        let position = sources[index].position
        return position > 0 && segments[position - 1].result == nil
    }

    func text(of source: SegmentTextReference) throws -> String {
        guard let text = texts[source] else { throw TranscriptMaterializationError.missingClauseSource }
        return text
    }
}

/// The published decision runs as the reader returned them.
struct PublishedDecisionSnapshot {
    private(set) var boundaryStates: [SegmentTextReference: (seq: UInt64, state: ClauseBoundaryState)] = [:]
    private(set) var pendingSources: [SegmentTextReference] = []
    private(set) var clauses: [ClauseUnit] = []
    private(set) var assignments: [ClauseReference: (seq: UInt64, assignment: ClausePriorityAssignment)] = [:]
    private var clausesByParts: [[ClauseSourcePart]: ClauseReference] = [:]
    private let activeRuns: ActiveRuns
    var hasRuns: Bool { activeRuns.clauseBoundary != nil && activeRuns.contentPriority != nil }
    var activeBoundaryRunID: String? { activeRuns.clauseBoundary }
    var activePriorityRunID: String? { activeRuns.contentPriority }

    init(events: [TranscriptEvent], activeRuns: ActiveRuns) throws {
        self.activeRuns = activeRuns
        for event in events.sorted(by: { $0.eventSeq < $1.eventSeq }) {
            switch event.kind {
            case .clauseBoundaryAssessed(let assessment) where event.processingRunID == activeRuns.clauseBoundary:
                boundaryStates[assessment.source] = (event.eventSeq, .assessed(assessment))
            case .clauseBoundaryPending(let payload) where event.processingRunID == activeRuns.clauseBoundary:
                boundaryStates[payload.source] = (event.eventSeq, .pending(reason: payload.reason, message: payload.message))
                pendingSources.append(payload.source)
            case .clauseClosed(let unit) where event.processingRunID == activeRuns.clauseBoundary:
                clauses.append(unit)
                clausesByParts[unit.parts] = unit.reference
            case .contentPriorityAssigned(let payload) where event.processingRunID == activeRuns.contentPriority:
                for assignment in payload.assignments {
                    assignments[assignment.reference] = (event.eventSeq, assignment)
                }
            default:
                break
            }
        }
    }

    func priorityRunID() throws -> String {
        guard let runID = activeRuns.contentPriority else { throw DecisionEnrichmentError.missingPublishedDecisionRuns }
        return runID
    }

    /// A published state recorded again in a rebuilt boundary run: an assessment as carried
    /// over from its event, a pending result as pending.
    func carriedState(of source: SegmentTextReference) throws -> ClauseBoundaryState {
        guard let runID = activeRuns.clauseBoundary else {
            return .pending(reason: .notRequested, message: DecisionPendingMessage.notRequested)
        }
        guard let published = boundaryStates[source] else {
            throw DecisionEnrichmentError.missingPublishedDecisionRuns
        }
        switch published.state {
        case .assessed(let assessment):
            return .assessed(try assessment.carriedOver(fromRunID: runID, eventSeq: published.seq))
        case .pending:
            return published.state
        }
    }

    /// The published assignment of the clause made of exactly these parts, if any.
    func assignment(forClauseWithParts parts: [ClauseSourcePart]) -> (seq: UInt64, assignment: ClausePriorityAssignment)? {
        clausesByParts[parts].flatMap { assignments[$0] }
    }
}
