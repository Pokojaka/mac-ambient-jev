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

    /// Discover the reuse roots without decoding unrelated final/retry payloads.
    func livePriorityRunID() throws -> String? {
        guard header.eventType == "processing.run.started",
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let provenance = payload["provenance"] as? [String: Any],
              let configuration = provenance["configuration"] as? [String: Any],
              configuration["mode"] as? String == "live",
              payload["stage"] as? String == ProcessingStage.contentPriority.rawValue else { return nil }
        _ = try body(PayloadBody<ProcessingRunStartedPayload>.self)
        return try requiredRunID()
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

struct SpeakerSpanBody: Decodable {
    let span: SpeakerSpan

    private enum PayloadKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let payload = try decoder.container(keyedBy: EventLogKeys.self)
            .nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        span = SpeakerSpan(
            speakerID: try payload.decode(String.self, forKey: .speakerID),
            startFrame: try payload.decode(Int64.self, forKey: .startFrame),
            endFrame: try payload.decode(Int64.self, forKey: .endFrame),
            confidence: try payload.decodeIfPresent(Double.self, forKey: .confidence)
        )
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


/// Reads the events of the active runs. Events of other runs and unknown event types are skipped;
/// an active-run event with a missing or mistyped field throws.
public struct EventLogTranscriptReader: Sendable {
    public init() {}

    /// Durable classified decisions of live priority runs, keyed by the exact filler-removed
    /// clause text. For one text the latest classified event wins; a later pending result
    /// does not remove it. `data` is the event log at the moment finalization freezes it.
    /// Only runs of the tagger revision that classifies the final transcript are reused.
    public func liveContentPriorityDecisions(
        from data: Data,
        modelRevision: String
    ) throws -> [ExactClauseTextKey: ReusableClauseDecision] {
        let recovered = try SessionRecovery.recoverJSONL(data)
        guard !recovered.droppedIncompleteTail else {
            throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
        }
        let decoded = try EventLogLine.decode(recovered.lines)
        let roots = Set(try decoded.compactMap { try $0.livePriorityRunID() })
        let log = try ClauseEventLog(lines: decoded, selectedRuns: roots)
        var boundaryRuns: [String: ClauseEventLog.BoundaryRun] = [:]
        var decisions: [(seq: UInt64, key: ExactClauseTextKey, decision: ReusableClauseDecision)] = []
        for (runID, run) in log.runs
        where run.stage == .contentPriority && run.mode == "live" && run.modelRevision == modelRevision {
            // A run without results references no boundary run yet.
            guard let boundaryRunID = Self.boundaryRunID(of: runID, in: log) else { continue }
            guard log.runs[boundaryRunID]?.mode == "live" else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "ライブ優先度 run が確定境界 run を参照しています")
            }
            let boundary = try boundaryRuns[boundaryRunID] ?? log.boundaryRun(boundaryRunID)
            boundaryRuns[boundaryRunID] = boundary
            let priority = try log.priorityRun(runID, boundary: boundary)
            for (seq, payload) in priority.events {
                for assignment in payload.assignments {
                    guard case .classified(_, _, let response) = assignment.decision,
                          let priorityValue = assignment.priority,
                          let text = boundary.clauseTexts[assignment.reference] else { continue }
                    let key = ExactClauseTextKey(text: text)
                    decisions.append((seq, key, ReusableClauseDecision(
                        sourcePriorityRunID: runID, sourceEventSeq: seq, sourceClause: assignment.reference,
                        decision: response, visiblePriority: priorityValue
                    )))
                }
            }
        }
        var result: [ExactClauseTextKey: ReusableClauseDecision] = [:]
        for entry in decisions.sorted(by: { $0.seq < $1.seq }) {
            result[entry.key] = entry.decision
        }
        return result
    }

    private static func boundaryRunID(of priorityRunID: String, in log: ClauseEventLog) -> String? {
        log.firstReference(ofPriorityRun: priorityRunID)?.boundaryRunID
    }

    public func events(
        lines: [Data],
        activeRuns: ActiveRuns
    ) throws -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
        let decoded = try EventLogLine.decode(lines)

        for line in decoded {
            let header = line.header
            let seq = header.eventSeq

            switch header.eventType {
            case "segment.created":
                let segmentationRunID = try line.requiredSegmentationRunID()
                guard segmentationRunID == activeRuns.segmentation else { continue }
                let body = try line.body(SegmentCreatedBody.self)
                events.append(.segmentCreated(
                    seq: seq,
                    segmentationRunID: segmentationRunID,
                    segmentID: body.segmentID,
                    startFrame: body.startFrame,
                    endFrame: body.endFrame
                ))

            case "asr.completed":
                let runID = try line.requiredRunID()
                let segmentationRunID = try line.requiredSegmentationRunID()
                guard runID == activeRuns.asr,
                      segmentationRunID == activeRuns.segmentation else { continue }
                let body = try line.body(ASRCompletedBody.self)
                guard body.outcome == ASRRecognitionOutcome(text: body.text) else {
                    throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: seq)
                }
                events.append(.asrCompleted(
                    seq: seq,
                    runID: runID,
                    segmentationRunID: segmentationRunID,
                    segmentID: body.segmentID,
                    text: body.text,
                    detectedLanguage: body.detectedLanguage
                ))

            case "speaker.span":
                let runID = try line.requiredRunID()
                guard runID == activeRuns.diarization else { continue }
                let span = try line.body(SpeakerSpanBody.self).span
                events.append(.speakerSpan(
                    seq: seq,
                    runID: runID,
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: span.endFrame,
                    confidence: span.confidence
                ))

            default:
                continue
            }
        }

        let log = try ClauseEventLog(lines: decoded, selectedRuns: Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization,
            activeRuns.clauseBoundary, activeRuns.contentPriority
        ].compactMap { $0 }))
        if let published = try log.publishedRuns(activeRuns) {
            events += Self.clauseEvents(boundary: published.boundary, priority: published.priority)
        }
        return events.sorted { $0.eventSeq < $1.eventSeq }
    }

    static func clauseEvents(boundary: ClauseEventLog.BoundaryRun, priority: ClauseEventLog.PriorityRun) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []
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
        for (seq, payload) in priority.events {
            events.append(.clause(seq: seq, runID: priority.runID, kind: .contentPriorityAssigned(payload)))
        }
        return events
    }
}

