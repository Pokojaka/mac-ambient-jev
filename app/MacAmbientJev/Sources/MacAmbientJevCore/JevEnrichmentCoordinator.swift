import Foundation

public enum ClauseEventType {
    public static let boundaryAssessed = "clause_boundaries.assessed"
    public static let boundaryPending = "clause_boundaries.pending"
    public static let clauseClosed = "clauses.closed"
    public static let priorityAssigned = "content_priority.assigned"
}

/// What each Jev run records about the service and policy; the model is recorded per response.
public enum JevRunProvenance {
    public static let boundaryPromptRevision = "1"
    public static let fillerProjectionRevision = "1"

    /// `mode` is `live`, `final` or `retry`.
    public static func boundary(mode: String) -> RunProvenance {
        RunProvenance(engine: "jev", model: nil, version: boundaryPromptRevision, configuration: [
            "mode": mode,
            "endpoint": JevClient.endpoint.absoluteString,
            "candidate_characters": "、。？！?!",
            "boundary_threshold": String(ClauseBoundaryPolicy.boundaryThreshold),
            "continuation_threshold": String(ClauseBoundaryPolicy.continuationThreshold),
            "next_head_character_limit": String(ClauseBoundaryPolicy.nextHeadCharacterLimit),
            "unit_policy": "absolute-and-strong",
            "text_policy": "raw-asr",
            "filler_projection_revision": fillerProjectionRevision,
        ])
    }

    public static func priority(mode: String) -> RunProvenance {
        RunProvenance(engine: "jev", model: nil, version: JevClient.priorityPromptRevision, configuration: [
            "mode": mode,
            "endpoint": JevClient.endpoint.absoluteString,
            "minimum_demotion_confidence": String(ContentPriorityPolicy.minimumDemotionConfidence),
            "maximum_targets": String(JevPriorityBatchPolicy.maximumTargets),
            "prompt_revision": JevClient.priorityPromptRevision,
            "text_policy": "filler-removed-exact",
            "filler_projection_revision": fillerProjectionRevision,
        ])
    }
}

public enum JevPendingMessage {
    public static let unavailable = "Jev を利用できないため判定を保留しました"
    public static let asrGap = "次の区間を音声認識できなかったため境界を判定できません"
    public static let stopped = "Jev への送信を停止したため判定を保留しました"
}

/// One boundary request for one source, or the pending state when it cannot be sent.
public enum ClauseBoundaryStep {
    /// Returns the state to record and, when the failure stops the batch, its reason.
    /// A source with no candidate at the end of the text needs no request.
    public static func assess(
        source: SegmentTextReference,
        text: String,
        next: NextSegmentHead?,
        decisions: JevDecisionCoordinator
    ) async throws -> (state: ClauseBoundaryState, stop: JevBatchStopReason?) {
        let request = try ClauseBoundaryRequest(source: source, text: text, next: next)
        if request.candidates.isEmpty && next == nil {
            return (.assessed(try ClauseBoundaryAssessment(
                source: source, candidates: [], probabilities: [:], nextHead: nil,
                continuationProbability: nil, request: nil, sourceDecision: .terminalWithoutQuestions
            )), nil)
        }
        switch await decisions.assessBoundaries(request) {
        case .answered(let response, let record):
            return (.assessed(try ClauseBoundaryAssessment(
                source: source, candidates: request.candidates, probabilities: response.probabilities,
                nextHead: next, continuationProbability: response.continuationProbability,
                request: record, sourceDecision: .assessed
            )), nil)
        case .failed(let stop, let message):
            return (.pending(reason: stop?.pendingReason ?? .requestFailed, message: message), stop)
        case .cancelled:
            throw CancellationError()
        }
    }
}

/// Builds the assignments of one Choice batch of at most 40 clauses.
public enum ClausePriorityBatch {
    /// Request-local keys `u0001`… in clause order; no source identifier is sent.
    public static func targets(texts: [String]) -> [PriorityTextTarget] {
        texts.enumerated().map { PriorityTextTarget(key: String(format: "u%04d", $0.offset + 1), text: $0.element) }
    }

    public static func classify(
        references: [ClauseReference],
        texts: [String],
        decisions: JevDecisionCoordinator
    ) async throws -> (payload: ContentPriorityAssignedPayload, stop: JevBatchStopReason?) {
        guard !references.isEmpty, references.count == texts.count,
              references.count <= JevPriorityBatchPolicy.maximumTargets,
              Set(references).count == references.count,
              texts.allSatisfy({ !ClauseTextComposer.isBlank($0) }) else {
            throw ClauseRecordError.invalidPriorityEvent
        }
        let targets = targets(texts: texts)
        switch await decisions.classifyPriorities(targets) {
        case .answered(let response, let record):
            var assignments: [ClausePriorityAssignment] = []
            for (reference, target) in zip(references, targets) {
                guard let decision = response.decisions[target.key] else { throw JevClientError.missingAnswer }
                assignments.append(try ClausePriorityAssignment(
                    reference: reference,
                    priority: ContentPriorityPolicy.visiblePriority(for: decision),
                    needsRetry: false,
                    decision: .classified(requestID: record.requestID, answerKey: target.key, response: decision)
                ))
            }
            return (try ContentPriorityAssignedPayload(assignments: assignments, request: record), nil)
        case .failed(let stop, let message):
            return (try pending(references: references, reason: stop?.pendingReason ?? .requestFailed, message: message), stop)
        case .cancelled:
            throw CancellationError()
        }
    }

    public static func pending(
        references: [ClauseReference], reason: ClausePendingReason, message: String
    ) throws -> ContentPriorityAssignedPayload {
        try ContentPriorityAssignedPayload(assignments: references.map {
            try ClausePriorityAssignment(
                reference: $0, priority: nil, needsRetry: true,
                decision: .retryPending(reason: reason, message: message)
            )
        }, request: nil)
    }
}

public enum JevEnrichmentError: LocalizedError, Sendable, Equatable {
    case missingPublishedTranscript
    case missingPublishedJevRuns
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
        case .missingPublishedJevRuns:
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

public struct JevEnrichmentBatchResult: Sendable {
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]
    public let pendingBoundarySegments: [SegmentTextReference]
    public let pendingPriorityClauses: [ClauseReference]
    public let boundaryRunID: String
    public let priorityRunID: String
    public let stopReason: JevBatchStopReason?

    public init(
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment],
        pendingBoundarySegments: [SegmentTextReference],
        pendingPriorityClauses: [ClauseReference],
        boundaryRunID: String,
        priorityRunID: String,
        stopReason: JevBatchStopReason?
    ) {
        self.events = events
        self.materializedSegments = materializedSegments
        self.pendingBoundarySegments = pendingBoundarySegments
        self.pendingPriorityClauses = pendingPriorityClauses
        self.boundaryRunID = boundaryRunID
        self.priorityRunID = priorityRunID
        self.stopReason = stopReason
    }

    public var pendingTargets: Set<JevPendingTarget> {
        Set(pendingBoundarySegments.map(JevPendingTarget.boundary))
            .union(pendingPriorityClauses.map(JevPendingTarget.priority))
    }
}

/// Which results a Jev snapshot requests.
public enum JevEnrichmentScope: Sendable {
    /// Every segment of a new transcript: one boundary request per segment, then every clause.
    case all
    /// Only these pending results. Every other published result is carried over. With no
    /// boundary segment the published boundary run is kept and only priorities are requested.
    case retry(boundarySegments: Set<SegmentTextReference>, clauses: Set<ClauseReference>)
}

/// Builds one Jev snapshot of a published transcript: a boundary run, then a priority run.
/// The caller publishes the returned runs and pending lists in one metadata write.
public actor JevEnrichmentCoordinator {
    private let sessionID: UUID
    private let boundaryRunID: String
    private let priorityRunID: String
    private let writer: SessionWriter
    private let decisions: JevDecisionCoordinator?
    private let usageCounter: JevUsageCounter
    private let materializer: TranscriptMaterializer

    private var stopReason: JevBatchStopReason?
    private var events: [TranscriptEvent] = []
    private var onEvent: ((TranscriptEvent) async -> Void)?

    public init(
        sessionID: UUID,
        boundaryRunID: String,
        priorityRunID: String,
        writer: SessionWriter,
        decisions: JevDecisionCoordinator?,
        usageCounter: JevUsageCounter,
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
    public func recordPublished(_ result: JevEnrichmentBatchResult, replacing previous: Set<JevPendingTarget>) async {
        await usageCounter.clearDeferred(sessionID: sessionID, targets: previous)
        await usageCounter.recordDeferred(sessionID: sessionID, targets: result.pendingTargets)
    }

    public func process(
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns,
        scope: JevEnrichmentScope,
        reusableDecisions: [ExactClauseTextKey: ReusableClauseDecision],
        onEvent: ((TranscriptEvent) async -> Void)?
    ) async throws -> JevEnrichmentBatchResult {
        try Task.checkCancellation()
        self.onEvent = onEvent
        events = existingEvents
        guard !priorityRunID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              priorityRunID != boundaryRunID,
              priorityRunID != activeRuns.contentPriority else {
            throw JevEnrichmentError.invalidPriorityRun
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
            rebuildsUnpublishedSnapshot = try JevRetryAnalyzer().hasUnpublishedJevRun(
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
        let published = try PublishedJevSnapshot(events: existingEvents, activeRuns: activeRuns)
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
            guard boundaryRunID != activeRuns.clauseBoundary else { throw JevEnrichmentError.boundaryRunNotNew }
        } else {
            guard boundaryRunID == activeRuns.clauseBoundary else { throw JevEnrichmentError.boundaryRunMismatch }
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
        let selected = activeRuns.withJevRuns(clauseBoundary: boundaryRunID, contentPriority: priorityRunID)
        return JevEnrichmentBatchResult(
            events: events,
            materializedSegments: try materializer.materialize(events: events, activeRuns: selected),
            pendingBoundarySegments: pendingBoundary,
            pendingPriorityClauses: pendingClauses,
            boundaryRunID: boundaryRunID,
            priorityRunID: priorityRunID,
            stopReason: stopReason
        )
    }

    // MARK: - Boundary run

    private func buildBoundaryRun(
        timeline: SourceTimeline,
        published: PublishedJevSnapshot,
        carriedSegments boundaryTargets: Set<SegmentTextReference>?,
        mode: String
    ) async throws -> (clauses: [ClauseUnit], pending: [SegmentTextReference]) {
        try await append(
            "processing.run.started", runID: boundaryRunID,
            payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: JevRunProvenance.boundary(mode: mode)),
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
            return .pending(reason: .asrGap, message: JevPendingMessage.asrGap)
        case .none, .empty:
            next = nil
        case .recognized(let source, let text):
            next = try NextSegmentHead(source: source, text: String(text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)))
        }
        if let stopReason {
            return .pending(reason: stopReason.pendingReason, message: JevPendingMessage.stopped)
        }
        guard let decisions else {
            return .pending(reason: .unconfigured, message: JevPendingMessage.unavailable)
        }
        let result = try await ClauseBoundaryStep.assess(
            source: entry.source, text: entry.text, next: next, decisions: decisions
        )
        if let stop = result.stop { stopReason = stop }
        return result.state
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
        published: PublishedJevSnapshot,
        rebuildsBoundaries: Bool,
        scope: JevEnrichmentScope,
        clauseTargets: Set<ClauseReference>,
        reusableDecisions: [ExactClauseTextKey: ReusableClauseDecision],
        mode: String
    ) async throws -> [ClauseReference: ClausePriorityAssignment] {
        try await append(
            "processing.run.started", runID: priorityRunID,
            payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: JevRunProvenance.priority(mode: mode)),
            kind: nil
        )
        var composer = ClauseTextComposer()
        var reusablePublished: [ExactClauseTextKey: (seq: UInt64, assignment: ClausePriorityAssignment)] = [:]
        if case .retry = scope, rebuildsBoundaries {
            var publishedComposer = ClauseTextComposer()
            for unit in published.clauses {
                guard let origin = published.assignments[unit.reference], !origin.assignment.needsRetry else { continue }
                let text = try publishedComposer.text(of: unit.parts, sourceText: timeline.text(of:))
                let key = ExactClauseTextKey(text: text)
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
            let origin: (seq: UInt64, assignment: ClausePriorityAssignment)?
            switch scope {
            case .all:
                if let reuse = reusableDecisions[ExactClauseTextKey(text: text)] {
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
                origin = rebuildsBoundaries
                    ? (published.assignment(forClauseWithParts: unit.parts) ?? reusablePublished[ExactClauseTextKey(text: text)])
                    : published.assignments[unit.reference]
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
        var remaining = targets[...]
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let batch = Array(remaining.prefix(JevPriorityBatchPolicy.maximumTargets))
            guard stopReason == nil, let decisions else {
                payloads.append(try ClausePriorityBatch.pending(
                    references: remaining.map(\.reference),
                    reason: stopReason?.pendingReason ?? .unconfigured,
                    message: stopReason == nil ? JevPendingMessage.unavailable : JevPendingMessage.stopped
                ))
                try await record(payloads[payloads.count - 1])
                break
            }
            remaining = remaining.dropFirst(batch.count)
            let result = try await ClausePriorityBatch.classify(
                references: batch.map(\.reference), texts: batch.map(\.text), decisions: decisions
            )
            if let stop = result.stop { stopReason = stop }
            payloads.append(result.payload)
            try await record(result.payload)
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
        published: PublishedJevSnapshot,
        timeline: SourceTimeline
    ) throws {
        if !published.hasRuns {
            guard published.activeBoundaryRunID == nil, published.activePriorityRunID == nil,
                  clauses.isEmpty, !segments.isEmpty else {
                throw JevEnrichmentError.missingPublishedJevRuns
            }
            for source in segments {
                guard let index = timeline.sources.firstIndex(where: { $0.source == source }) else {
                    throw JevEnrichmentError.unknownRetryTarget(source.segmentID)
                }
                if case .missing = timeline.successor(ofSourceAt: index) {
                    throw JevEnrichmentError.missingNextASRSource(segmentID: source.segmentID)
                }
            }
            return
        }
        for source in segments {
            guard published.pendingSources.contains(source),
                  let index = timeline.sources.firstIndex(where: { $0.source == source }) else {
                throw JevEnrichmentError.unknownRetryTarget(source.segmentID)
            }
            if case .missing = timeline.successor(ofSourceAt: index) {
                throw JevEnrichmentError.missingNextASRSource(segmentID: source.segmentID)
            }
        }
        for clause in clauses {
            guard published.assignments[clause]?.assignment.needsRetry == true else {
                throw JevEnrichmentError.unknownRetryTarget(clause.clauseID)
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
            throw JevEnrichmentError.missingPublishedTranscript
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
                    throw JevEnrichmentError.invalidSourceTimeline
                }
                created.append((segmentID, start))
            case .asrCompleted(let result) where event.processingRunID == activeRuns.asr
                && event.segmentationRunID == segmentationRunID:
                guard let segmentID = event.segmentID, createdIDs.contains(segmentID),
                      let source = try event.asrSource() else {
                    throw JevEnrichmentError.invalidSourceTimeline
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
                    throw JevEnrichmentError.invalidSourceTimeline
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

/// The published Jev runs as the reader returned them.
struct PublishedJevSnapshot {
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
        guard let runID = activeRuns.contentPriority else { throw JevEnrichmentError.missingPublishedJevRuns }
        return runID
    }

    /// A published state recorded again in a rebuilt boundary run: an assessment as carried
    /// over from its event, a pending result as pending.
    func carriedState(of source: SegmentTextReference) throws -> ClauseBoundaryState {
        guard let runID = activeRuns.clauseBoundary else {
            return .pending(reason: .unconfigured, message: JevPendingMessage.unavailable)
        }
        guard let published = boundaryStates[source] else {
            throw JevEnrichmentError.missingPublishedJevRuns
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
