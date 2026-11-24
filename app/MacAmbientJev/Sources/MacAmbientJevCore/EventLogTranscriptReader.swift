import Foundation

public enum EventLogTranscriptReaderError: Error, Equatable, LocalizedError {
    /// The line is not a JSON event with `event_seq`, `event_type` and `schema_version`.
    case unreadableLine(index: Int)
    /// An event the reader needs is missing a required field or has a field of the wrong type.
    case malformedEvent(eventSeq: UInt64, eventType: String)
    /// An `asr.completed` event whose `outcome` contradicts its `text`.
    case asrOutcomeMismatch(eventSeq: UInt64)
    /// Clause events that do not match the ASR text, the boundary results, or each other.
    case inconsistentClauseRun(runID: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableLine(let index):
            "イベントログの \(index + 1) 行目を読めません"
        case .malformedEvent(let eventSeq, let eventType):
            "イベントログの \(eventType)（event_seq \(eventSeq)）が壊れています"
        case .asrOutcomeMismatch(let eventSeq):
            "イベントログの asr.completed（event_seq \(eventSeq)）の outcome が本文と一致しません"
        case .inconsistentClauseRun(let runID, let reason):
            "イベントログの判定（run \(runID)）が整合しません: \(reason)"
        }
    }
}

/// One `events.jsonl` line. The envelope header is decoded first; a typed body is decoded
/// only for events the caller needs, so other runs and unknown event types stay unparsed.
struct EventLogLine {
    struct Header: Decodable {
        let eventSeq: UInt64
        let eventType: String
        let schemaVersion: Int
        let processingRunID: String?
        let segmentationRunID: String?
        let sessionID: UUID?
        let segmentID: String?

        private enum CodingKeys: String, CodingKey {
            case eventSeq = "event_seq"
            case eventType = "event_type"
            case schemaVersion = "schema_version"
            case processingRunID = "processing_run_id"
            case segmentationRunID = "segmentation_run_id"
            case sessionID = "session_id"
            case segmentID = "segment_id"
        }
    }

    let header: Header
    let data: Data

    init(index: Int, data: Data) throws {
        try EventLogSchema.validate(line: data, index: index)
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch is DecodingError {
            throw EventLogTranscriptReaderError.unreadableLine(index: index)
        }
        self.data = data
    }

    func body<Body: Decodable>(_ type: Body.Type) throws -> Body {
        do {
            return try JSONDecoder().decode(Body.self, from: data)
        } catch is DecodingError {
            throw malformed
        } catch is ClauseRecordError {
            throw malformed
        } catch is ClauseValidationError {
            throw malformed
        } catch is TextUTF16RangeError {
            throw malformed
        }
    }

    var malformed: EventLogTranscriptReaderError {
        .malformedEvent(eventSeq: header.eventSeq, eventType: header.eventType)
    }

    /// The run ID a known event type is keyed by; its absence makes the event unattributable.
    func requiredRunID() throws -> String {
        guard let value = header.processingRunID, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw malformed }
        return value
    }

    func requiredSegmentationRunID() throws -> String {
        guard let value = header.segmentationRunID, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw malformed }
        return value
    }

    /// Existing logs must have the required clause payloads before a writer appends.
    /// Reference/coverage validation uses the consumer's selected snapshot.
    func validateClausePayload() throws {
        switch header.eventType {
        case ClauseEventType.boundaryAssessed:
            _ = try requiredRunID()
            _ = try body(PayloadBody<ClauseBoundaryAssessment>.self)
        case ClauseEventType.boundaryPending:
            _ = try requiredRunID()
            _ = try body(PayloadBody<ClauseBoundaryPendingPayload>.self)
        case ClauseEventType.clauseClosed:
            _ = try requiredRunID()
            _ = try body(PayloadBody<ClauseUnit>.self)
        case ClauseEventType.priorityAssigned:
            _ = try requiredRunID()
            _ = try body(PayloadBody<ContentPriorityAssignedPayload>.self)
        default:
            break
        }
    }

    static func decode(_ lines: [Data]) throws -> [EventLogLine] {
        var previous: UInt64 = 0
        return try lines.enumerated().map {
            let line = try EventLogLine(index: $0.offset, data: $0.element)
            guard line.header.eventSeq > previous else {
                throw SessionRecoveryError.invalidEventSequence(index: $0.offset)
            }
            previous = line.header.eventSeq
            return line
        }
    }
}

private enum EventLogKeys: String, CodingKey {
    case processingRunID = "processing_run_id"
    case segmentationRunID = "segmentation_run_id"
    case segmentID = "segment_id"
    case sourceStartFrame = "source_start_frame"
    case sourceEndFrame = "source_end_frame"
    case payload
}

struct SegmentCreatedBody: Decodable {
    let segmentID: String
    let startFrame: Int64
    let endFrame: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        startFrame = try container.decode(Int64.self, forKey: .sourceStartFrame)
        endFrame = try container.decode(Int64.self, forKey: .sourceEndFrame)
    }
}

struct ASRCompletedBody: Decodable {
    let segmentID: String
    let text: String
    let detectedLanguage: String?
    let outcome: ASRRecognitionOutcome

    private enum PayloadKeys: String, CodingKey {
        case text
        case detectedLanguage = "detected_language"
        case outcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        segmentID = try container.decode(String.self, forKey: .segmentID)
        let payload = try container.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        text = try payload.decode(String.self, forKey: .text)
        detectedLanguage = try payload.decodeIfPresent(String.self, forKey: .detectedLanguage)
        outcome = try payload.decode(ASRRecognitionOutcome.self, forKey: .outcome)
    }
}

struct PayloadBody<Payload: Decodable>: Decodable {
    let payload: Payload
}

struct RunCompletedBody: Decodable {
    let stage: ProcessingStage
    let succeeded: Bool
    let completedCount: Int
    let failedCount: Int

    private enum CodingKeys: String, CodingKey {
        case stage, succeeded
        case completedCount = "completed_count", failedCount = "failed_count"
    }
}


public struct StoredTranscriptEvents: Sendable {
    public let state: ProcessingLogState
    public let events: [TranscriptEvent]
    public let pendingDecisions: DecisionRetryTargets
}

/// Projects the durable transcript selected by its latest pipeline generation.
public struct EventLogTranscriptReader: Sendable {
    public init() {}

    public func read(eventsURL: URL, sessionID: UUID) throws -> StoredTranscriptEvents? {
        let lines = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: eventsURL)).lines
        return try project(lines: lines, sessionID: sessionID, frameCount: nil)
    }

    public func read(lines: [Data], sessionID: UUID) throws -> StoredTranscriptEvents? {
        try project(lines: lines, sessionID: sessionID, frameCount: nil)
    }

    public func validateCompletion(eventsURL: URL, sessionID: UUID, frameCount: Int64) throws -> StoredTranscriptEvents {
        let lines = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: eventsURL)).lines
        guard let stored = try project(lines: lines, sessionID: sessionID, frameCount: frameCount) else {
            throw ProcessingLogStateError.missingGeneration
        }
        return stored
    }

    /// The transcript the log will read as once `replacement`'s selection event is appended, validated
    /// as complete. Nothing is written: a pair that would not read back is never selected.
    public func validateReplacement(
        eventsURL: URL, sessionID: UUID, frameCount: Int64, replacement: DecisionRunReplacement
    ) throws -> StoredTranscriptEvents {
        let recovered = try SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: eventsURL))
        let draft = replacement.selectionEvent(sessionID: sessionID)
        let selection = try SessionWriter.encode(EventEnvelope(
            eventSeq: (recovered.lastEventSequence ?? 0) + 1, eventID: UUID(), eventType: draft.eventType,
            sessionID: sessionID, processingRunID: nil, segmentationRunID: nil, segmentID: nil,
            sourceStartFrame: nil, sourceEndFrame: nil, createdAt: draft.createdAt, payload: draft.payload
        ))
        guard let stored = try project(lines: recovered.lines + [selection], sessionID: sessionID, frameCount: frameCount) else {
            throw ProcessingLogStateError.missingGeneration
        }
        return stored
    }

    private func project(lines: [Data], sessionID: UUID, frameCount: Int64?) throws -> StoredTranscriptEvents? {
        let decoded = try EventLogLine.decode(lines)
        guard let generation = try GenerationEventLog(lines: decoded, sessionID: sessionID) else { return nil }
        let state = try ProcessingLogState(log: generation, sessionID: sessionID)
        if let frameCount { try state.validateRecognitionCompletion(frameCount: frameCount) }

        let selected = generation.runs
        var roots = Set([state.segmentationRunID, state.asrRunID]
            + [selected.clauseBoundary, selected.contentPriority].compactMap { $0 })
        var replacements: [(seq: UInt64, runs: ActiveRuns)] = []
        for line in generation.lines where line.header.eventType == "pipeline.decisions.replaced" {
            let ids = try line.body(PayloadBody<DecisionRunReplacement>.self).payload.replacement
            roots.formUnion([ids.boundary, ids.priority])
            replacements.append((line.header.eventSeq, selected.withDecisionRuns(
                clauseBoundary: ids.boundary, contentPriority: ids.priority
            )))
        }
        let log = try ClauseEventLog(lines: generation.lines, selectedRuns: roots, sessionID: sessionID)
        for replacement in replacements {
            _ = try log.decisionRuns(
                replacement.runs, requireCompletion: true, selectedBefore: replacement.seq
            )
        }
        let decisions = try log.decisionRuns(
            selected, requireCompletion: frameCount != nil, selectedBefore: nil
        )
        let recognizedSources = log.recognizedSources(
            segmentationRunID: state.segmentationRunID, asrRunID: state.asrRunID
        )
        let pendingBoundary = selected.clauseBoundary == nil
            ? recognizedSources : (decisions.boundary?.pendingSources ?? [])
        let pendingPriority = (decisions.boundary?.clauses ?? []).compactMap { _, clause in
            decisions.priority?.assignments[clause.reference]?.needsRetry == true ? clause.reference : nil
        }
        let events = (state.events + Self.clauseEvents(
            boundary: decisions.boundary, priority: decisions.priority
        )).sorted { $0.eventSeq < $1.eventSeq }
        return StoredTranscriptEvents(
            state: state, events: events,
            pendingDecisions: DecisionRetryTargets(boundarySegments: pendingBoundary, clauses: pendingPriority)
        )
    }

    static func clauseEvents(boundary: ClauseEventLog.BoundaryRun?, priority: ClauseEventLog.PriorityRun?) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        if let boundary {
            for (seq, input) in boundary.inputs {
                switch input.state {
                case .assessed(let assessment):
                    events.append(.clause(seq: seq, runID: boundary.runID, kind: .clauseBoundaryAssessed(assessment)))
                case .pending(let reason, let message):
                    events.append(.clause(seq: seq, runID: boundary.runID, kind: .clauseBoundaryPending(
                        ClauseBoundaryPendingPayload(source: input.source, reason: reason, message: message)
                    )))
                }
            }
            for (seq, unit) in boundary.clauses {
                events.append(.clause(seq: seq, runID: boundary.runID, kind: .clauseClosed(unit)))
            }
        }
        if let priority {
            for (seq, payload) in priority.events {
                events.append(.clause(seq: seq, runID: priority.runID, kind: .contentPriorityAssigned(payload)))
            }
        }
        return events
    }
}

/// Reconstructs the generation's initially selected incremental decision session from its durable event log.
public struct DecisionSessionRecovery: Sendable {
    public let events: [TranscriptEvent], handledSources: [SegmentTextReference]
    public let assembly: ClauseBoundaryAssembly, composer: ClauseTextComposer
    public let unsavedClauses: [ClauseUnit], unassignedClauses: [ClauseUnit]
    public let startedRuns: Set<ProcessingStage>, completedRuns: Set<ProcessingStage>
    public let boundaryCounts: (assessed: Int, pending: Int), priorityCounts: (classified: Int, pending: Int)
    public let pendingTargets: Set<DecisionPendingTarget>
    public let boundaryRunID, priorityRunID: String

    public init(eventsURL: URL, sessionID: UUID) throws {
        let lines = try EventLogLine.decode(SessionRecovery.recoverJSONL(SessionWriter.readDurableLog(eventsURL: eventsURL)).lines)
        guard let generation = try GenerationEventLog(lines: lines, sessionID: sessionID) else {
            throw ProcessingLogStateError.missingGeneration
        }
        let initialRuns = generation.generation.runs
        guard let segmentationRunID = initialRuns.segmentation, let asrRunID = initialRuns.asr else {
            throw ProcessingLogStateError.missingGeneration
        }
        guard let boundaryRunID = initialRuns.clauseBoundary,
              let priorityRunID = initialRuns.contentPriority else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "この世代では判定 run が選択されていません")
        }
        guard generation.runs == initialRuns else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: generation.runs.contentPriority ?? "", reason: "選択された判定 run が世代の初期 run と異なるため、判定セッションを再開できません"
            )
        }
        let log = try ClauseEventLog(
            lines: generation.lines,
            selectedRuns: [segmentationRunID, asrRunID, boundaryRunID, priorityRunID],
            sessionID: sessionID
        )
        let decisions = try log.decisionRuns(initialRuns, requireCompletion: false)
        let boundary = decisions.boundary
        let priority = decisions.priority
        if let end = log.runs[priorityRunID]?.completionSeq {
            guard let boundaryEnd = log.runs[boundaryRunID]?.completionSeq,
                  log.runs[boundaryRunID]?.completed == true, boundaryEnd < end else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: priorityRunID, reason: "優先度 run の完了より前に境界 run が完了していません")
            }
        }
        for (seq, input) in boundary?.inputs ?? [] {
            let source = input.source
            guard source.segmentationRunID == segmentationRunID, source.asrRunID == asrRunID else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "境界判定の原文参照が指定 run と一致しません")
            }
            switch log.successor(of: source, before: seq) {
            case .missing:
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "判定時点で次区間の音声認識結果がありません")
            case .none:
                guard case .none = log.successor(of: source) else {
                    throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: boundaryRunID, reason: "次区間が判定後に登録されています")
                }
            case .empty, .recognized: break
            }
        }
        events = EventLogTranscriptReader.clauseEvents(boundary: boundary, priority: priority)
            .sorted { $0.eventSeq < $1.eventSeq }
        let inputs = boundary?.inputs ?? []
        handledSources = inputs.map(\.input.source)
        assembly = boundary?.assembly ?? ClauseBoundaryAssembly(boundaryRunID: boundaryRunID)
        composer = boundary?.composer ?? ClauseTextComposer()
        unsavedClauses = boundary?.unsavedClauses ?? []
        let assignments = priority?.assignments ?? [:]
        unassignedClauses = (boundary?.clauses ?? []).compactMap { _, unit in
            guard assignments[unit.reference] == nil, let text = boundary?.clauseTexts[unit.reference],
                  !ClauseTextComposer.isBlank(text) else { return nil }
            return unit
        }
        let pendingBoundary = boundary?.pendingSources.count ?? 0
        let retryCount = assignments.values.filter(\.needsRetry).count
        var targets = Set((boundary?.pendingSources ?? []).map(DecisionPendingTarget.boundary))
        for assignment in assignments.values where assignment.needsRetry { targets.insert(.priority(assignment.reference)) }
        boundaryCounts = (inputs.count - pendingBoundary, pendingBoundary)
        priorityCounts = (assignments.count - retryCount, retryCount)
        pendingTargets = targets

        let selected = [(ProcessingStage.clauseBoundary, boundaryRunID), (.contentPriority, priorityRunID)]
        startedRuns = Set(selected.filter { log.runs[$0.1] != nil }.map(\.0))
        completedRuns = Set(selected.filter { log.runs[$0.1]?.completed == true }.map(\.0))
        self.boundaryRunID = boundaryRunID
        self.priorityRunID = priorityRunID
    }
}

