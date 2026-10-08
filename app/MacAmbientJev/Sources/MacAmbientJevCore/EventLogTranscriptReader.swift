import Foundation

public enum EventLogTranscriptReaderError: Error, Equatable, LocalizedError {
    /// The line is not a JSON event with `event_seq`, `event_type` and `schema_version`.
    case unreadableLine(index: Int)
    /// An event the reader needs is missing a required field or has a field of the wrong type.
    case malformedEvent(eventSeq: UInt64, eventType: String)
    /// An `asr.completed` event whose `outcome` contradicts its `text`.
    case asrOutcomeMismatch(eventSeq: UInt64)
    /// Jev clause events that do not match the ASR text, the boundary results, or each other.
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
            "イベントログの Jev 判定（run \(runID)）が整合しません: \(reason)"
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
    fileprivate let data: Data

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

    /// Existing logs must have the required schema2 clause payloads before a writer appends.
    /// Reference/coverage validation remains scoped to the consumer's selected snapshot.
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

private struct SegmentCreatedBody: Decodable {
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

private struct ASRCompletedBody: Decodable {
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

private struct SpeakerSpanBody: Decodable {
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

private struct SceneChangedBody: Decodable {
    let frame: Int64
    let scene: SceneState

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: EventLogKeys.self)
        frame = try container.decode(Int64.self, forKey: .sourceStartFrame)
        scene = try container.decode(SceneState.self, forKey: .payload)
    }
}

private struct ScopeSpanBody: Decodable {
    let span: ScopeSpan

    private enum PayloadKeys: String, CodingKey {
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case scope
        case confidence
    }

    init(from decoder: Decoder) throws {
        let payload = try decoder.container(keyedBy: EventLogKeys.self)
            .nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        span = ScopeSpan(
            startFrame: try payload.decode(Int64.self, forKey: .startFrame),
            endFrame: try payload.decode(Int64.self, forKey: .endFrame),
            scope: try payload.decode(AcousticScope.self, forKey: .scope),
            confidence: try payload.decode(Double.self, forKey: .confidence)
        )
    }
}

private struct PayloadBody<Payload: Decodable>: Decodable {
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

/// Decodes and checks every Jev clause event of a log against the ASR text it refers to.
/// Reader, retry analysis, live reuse and the saved-session catalog all go through it.
struct ClauseEventLog {
    struct Run {
        let stage: ProcessingStage
        let mode: String?
        let startedSeq: UInt64
        var completionSeq: UInt64?
        var completion: RunCompletedBody?

        var completed: Bool { completion?.succeeded == true }
    }

    enum Successor: Equatable {
        case none
        case empty
        case missing
        case recognized(SegmentTextReference, String)
    }

    struct BoundaryRun {
        let runID: String
        let complete: Bool
        let inputs: [(seq: UInt64, input: ClauseAssemblyInput)]
        let clauses: [(seq: UInt64, unit: ClauseUnit)]
        let clauseTexts: [ClauseReference: String]
        let pendingSources: [SegmentTextReference]
        /// Sources unresolved because they touch a pending result, including the pending ones.
        let unresolvedSources: Set<SegmentTextReference>
    }

    struct PriorityRun {
        let runID: String
        let complete: Bool
        let events: [(seq: UInt64, payload: ContentPriorityAssignedPayload)]
        let assignments: [ClauseReference: ClausePriorityAssignment]
    }

    private(set) var runs: [String: Run] = [:]
    private(set) var asrTexts: [SegmentTextReference: String] = [:]
    /// Segment IDs of each segmentation run in time order.
    private var segmentOrder: [String: [(segmentID: String, startFrame: Int64, createdSeq: UInt64)]] = [:]
    private var segmentIDs: [String: Set<String>] = [:]
    /// The latest `asr.completed` of each segment per (segmentation run, ASR run).
    private var asrBySegment: [String: [String: SegmentTextReference]] = [:]
    private var segmentPositions: [String: Int] = [:]
    private var boundaryEvents: [String: [(seq: UInt64, line: EventLogLine)]] = [:]
    private var clauseEvents: [String: [(seq: UInt64, unit: ClauseUnit)]] = [:]
    private var priorityEvents: [String: [(seq: UInt64, payload: ContentPriorityAssignedPayload)]] = [:]
    private var assessedBySeq: [UInt64: (runID: String, assessment: ClauseBoundaryAssessment)] = [:]
    private var localEvidence: [ProcessingStage: Set<String>] = [:]
    private var failedASRSources: [SegmentTextReference] = []

    private final class ValidationCache {
        var boundaries: [String: BoundaryRun] = [:]
        var priorities: [String: PriorityRun] = [:]
        var checkingBoundaries: Set<String> = []
        var checkingPriorities: Set<String> = []
    }
    private let validation = ValidationCache()

    /// Only decode the selected runs and the transitive provenance/source references they use.
    /// Broken payloads in unrelated runs must not invalidate a durable published snapshot.
    private static func selectedLines(_ lines: [EventLogLine], roots: Set<String>) throws -> [EventLogLine] {
        var selected = roots
        var visited: Set<String> = []
        let byRun = Dictionary(grouping: lines) { $0.header.processingRunID }
        while let runID = selected.subtracting(visited).first {
            visited.insert(runID)
            for line in byRun[runID] ?? [] {
                switch line.header.eventType {
                case ClauseEventType.boundaryAssessed:
                    let assessment = try line.body(PayloadBody<ClauseBoundaryAssessment>.self).payload
                    selected.insert(assessment.source.asrRunID)
                    selected.insert(assessment.source.segmentationRunID)
                    if case .carriedOver(let origin, _) = assessment.sourceDecision { selected.insert(origin) }
                case ClauseEventType.boundaryPending:
                    let pending = try line.body(PayloadBody<ClauseBoundaryPendingPayload>.self).payload
                    selected.insert(pending.source.asrRunID)
                    selected.insert(pending.source.segmentationRunID)
                case ClauseEventType.clauseClosed:
                    let unit = try line.body(PayloadBody<ClauseUnit>.self).payload
                    for part in unit.parts {
                        selected.insert(part.source.asrRunID)
                        selected.insert(part.source.segmentationRunID)
                    }
                case ClauseEventType.priorityAssigned:
                    let payload = try line.body(PayloadBody<ContentPriorityAssignedPayload>.self).payload
                    for assignment in payload.assignments {
                        selected.insert(assignment.reference.boundaryRunID)
                        if case .carriedOver(let origin, _, let clause, _) = assignment.decision {
                            selected.insert(origin)
                            selected.insert(clause.boundaryRunID)
                        }
                    }
                default: break
                }
            }
        }
        return lines.filter {
            if $0.header.eventType == "segment.created" {
                return $0.header.segmentationRunID.map(selected.contains) == true
            }
            return $0.header.processingRunID.map(selected.contains) == true
        }
    }

    init(lines: [EventLogLine], selectedRuns: Set<String>? = nil, sessionID: UUID? = nil) throws {
        let relevant = try selectedRuns.map { try Self.selectedLines(lines, roots: $0) } ?? lines
        let sessions = Set(relevant.compactMap(\.header.sessionID))
        guard (relevant.isEmpty || sessions.count == 1),
              relevant.allSatisfy({ $0.header.sessionID != nil }),
              sessionID.map({ relevant.isEmpty || sessions == [$0] }) ?? true else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "別セッションのイベントが混在しています")
        }
        for line in relevant.sorted(by: { $0.header.eventSeq < $1.header.eventSeq }) {
            let header = line.header
            switch header.eventType {
            case "processing.run.started":
                let started = try line.body(PayloadBody<ProcessingRunStartedPayload>.self).payload
                let runID = try line.requiredRunID()
                guard runs[runID] == nil else {
                    throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "run の開始記録が重複しています")
                }
                runs[runID] = Run(
                    stage: started.stage, mode: started.provenance.configuration["mode"],
                    startedSeq: header.eventSeq, completionSeq: nil, completion: nil
                )
            case "processing.run.completed":
                let runID = try line.requiredRunID()
                let completed = try line.body(PayloadBody<RunCompletedBody>.self).payload
                guard var run = runs[runID], run.stage == completed.stage, run.completion == nil,
                      completed.completedCount >= 0, completed.failedCount >= 0 else {
                    throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: runID, reason: "run の完了記録が開始記録と一致しません")
                }
                run.completionSeq = header.eventSeq
                run.completion = completed
                runs[runID] = run
            case "segment.created":
                let segmentationRunID = try line.requiredSegmentationRunID()
                let body = try line.body(SegmentCreatedBody.self)
                guard body.startFrame >= 0, body.endFrame > body.startFrame,
                      segmentIDs[segmentationRunID, default: []].insert(body.segmentID).inserted else {
                    throw line.malformed
                }
                segmentOrder[segmentationRunID, default: []].append((body.segmentID, body.startFrame, header.eventSeq))
                localEvidence[.segmentation, default: []].insert(segmentationRunID)
            case "asr.completed":
                let runID = try line.requiredRunID()
                let segmentationRunID = try line.requiredSegmentationRunID()
                let body = try line.body(ASRCompletedBody.self)
                guard body.outcome == ASRRecognitionOutcome(text: body.text) else {
                    throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: header.eventSeq)
                }
                let source = try SegmentTextReference(
                    segmentationRunID: segmentationRunID, segmentID: body.segmentID,
                    asrRunID: runID, asrEventSeq: header.eventSeq
                )
                asrTexts[source] = body.text
                asrBySegment[Self.runKey(segmentationRunID, runID), default: [:]][body.segmentID] = source
                localEvidence[.asr, default: []].insert(runID)
            case "asr.failed":
                let runID = try line.requiredRunID()
                guard let segmentID = header.segmentID else { throw line.malformed }
                _ = try line.body(PayloadBody<ASRFailedEventPayload>.self)
                failedASRSources.append(try SegmentTextReference(
                    segmentationRunID: line.requiredSegmentationRunID(), segmentID: segmentID,
                    asrRunID: runID, asrEventSeq: header.eventSeq
                ))
                localEvidence[.asr, default: []].insert(runID)
            case "speaker.span":
                _ = try line.body(SpeakerSpanBody.self)
                localEvidence[.diarization, default: []].insert(try line.requiredRunID())
            case "scene.changed":
                _ = try line.body(SceneChangedBody.self)
                localEvidence[.scene, default: []].insert(try line.requiredRunID())
            case "scope.span":
                _ = try line.body(ScopeSpanBody.self)
                localEvidence[.scope, default: []].insert(try line.requiredRunID())
            case "clause_boundaries.assessed":
                let runID = try line.requiredRunID()
                let assessment = try line.body(PayloadBody<ClauseBoundaryAssessment>.self).payload
                assessedBySeq[header.eventSeq] = (runID, assessment)
                boundaryEvents[runID, default: []].append((header.eventSeq, line))
            case "clause_boundaries.pending":
                boundaryEvents[try line.requiredRunID(), default: []].append((header.eventSeq, line))
            case "clauses.closed":
                let unit = try line.body(PayloadBody<ClauseUnit>.self).payload
                clauseEvents[try line.requiredRunID(), default: []].append((header.eventSeq, unit))
            case "content_priority.assigned":
                let payload = try line.body(PayloadBody<ContentPriorityAssignedPayload>.self).payload
                priorityEvents[try line.requiredRunID(), default: []].append((header.eventSeq, payload))
            default:
                continue
            }
        }
        for key in segmentOrder.keys {
            segmentOrder[key]?.sort { $0.startFrame < $1.startFrame }
            for (index, segment) in (segmentOrder[key] ?? []).enumerated() {
                segmentPositions[Self.runKey(key, segment.segmentID)] = index
            }
        }
        for source in asrTexts.keys { try validateSourceCreated(source) }
        for source in failedASRSources { try validateSourceCreated(source) }
    }

    private func validateSourceCreated(_ source: SegmentTextReference) throws {
        guard let index = segmentPositions[Self.runKey(source.segmentationRunID, source.segmentID)],
              let segment = segmentOrder[source.segmentationRunID]?[index],
              segment.createdSeq < source.asrEventSeq else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: source.asrRunID, reason: "音声認識の原文参照に対応する区間がありません"
            )
        }
    }

    private static func runKey(_ segmentationRunID: String, _ asrRunID: String) -> String {
        segmentationRunID + "\u{1F}" + asrRunID
    }

    /// Every source with recognized text of an ASR run, in time order.
    func recognizedSources(segmentationRunID: String, asrRunID: String) -> [SegmentTextReference] {
        let bySegment = asrBySegment[Self.runKey(segmentationRunID, asrRunID)] ?? [:]
        return (segmentOrder[segmentationRunID] ?? []).compactMap { segment in
            guard let source = bySegment[segment.segmentID],
                  let text = asrTexts[source],
                  ASRRecognitionOutcome(text: text) == .recognized else { return nil }
            return source
        }
    }

    /// The segment that follows `source` in time order, as its own ASR run recognized it.
    func successor(of source: SegmentTextReference, before eventSeq: UInt64? = nil) -> Successor {
        let order = segmentOrder[source.segmentationRunID] ?? []
        guard let index = segmentPositions[Self.runKey(source.segmentationRunID, source.segmentID)] else { return .missing }
        let next = index + 1
        guard next < order.count, eventSeq.map({ order[next].createdSeq < $0 }) ?? true else { return .none }
        let key = Self.runKey(source.segmentationRunID, source.asrRunID)
        guard let nextSource = asrBySegment[key]?[order[next].segmentID],
              eventSeq.map({ nextSource.asrEventSeq < $0 }) ?? true,
              let text = asrTexts[nextSource] else {
            return .missing
        }
        return ASRRecognitionOutcome(text: text) == .recognized ? .recognized(nextSource, text) : .empty
    }

    private func hasEmptySeparator(before source: SegmentTextReference, eventSeq: UInt64?) -> Bool {
        let order = segmentOrder[source.segmentationRunID] ?? []
        guard let index = segmentPositions[Self.runKey(source.segmentationRunID, source.segmentID)] else { return false }
        let results = asrBySegment[Self.runKey(source.segmentationRunID, source.asrRunID)] ?? [:]
        for position in stride(from: index - 1, through: 0, by: -1) {
            guard let previous = results[order[position].segmentID],
                  eventSeq.map({ previous.asrEventSeq < $0 }) ?? true,
                  let text = asrTexts[previous] else { continue }
            return ASRRecognitionOutcome(text: text) != .recognized
        }
        return false
    }

    private func hasMissingPredecessor(of source: SegmentTextReference) -> Bool {
        let order = segmentOrder[source.segmentationRunID] ?? []
        guard let index = segmentPositions[Self.runKey(source.segmentationRunID, source.segmentID)],
              index > 0 else { return false }
        return asrBySegment[Self.runKey(source.segmentationRunID, source.asrRunID)]?[order[index - 1].segmentID] == nil
    }

    func text(of source: SegmentTextReference) throws -> String {
        guard let text = asrTexts[source] else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(
                runID: source.asrRunID, reason: "区間 \(source.segmentID) の原文がありません"
            )
        }
        return text
    }

    /// Replays stored decisions in their original temporal context. Completed runs contain
    /// all replayed clauses; only unfinished live runs may contain a durable prefix.
    func boundaryRun(_ runID: String) throws -> BoundaryRun {
        func fail(_ reason: String) -> EventLogTranscriptReaderError {
            .inconsistentClauseRun(runID: runID, reason: reason)
        }
        guard let run = runs[runID], run.stage == .clauseBoundary else { throw fail("境界判定 run の開始記録がありません") }
        guard run.completed || (run.mode == "live" && run.completion == nil) else {
            throw fail("未完了の確定・再試行 run は判定元に使えません")
        }
        if let cached = validation.boundaries[runID] { return cached }
        guard validation.checkingBoundaries.insert(runID).inserted else { throw fail("境界判定の引き継ぎが循環しています") }
        defer { validation.checkingBoundaries.remove(runID) }
        var assembly = ClauseBoundaryAssembly(boundaryRunID: runID)
        var inputs: [(seq: UInt64, input: ClauseAssemblyInput)] = []
        var expected: [ClauseUnit] = []
        var closureSeqs: [ClauseReference: UInt64] = [:]
        var pending: [SegmentTextReference] = []
        var requestIDs: Set<String> = []
        let stored = clauseEvents[runID] ?? []
        for entry in stored {
            guard entry.seq > run.startedSeq, run.completionSeq.map({ entry.seq < $0 }) ?? true else {
                throw fail("節の保存記録が run の期間外にあります")
            }
        }
        for (seq, line) in boundaryEvents[runID] ?? [] {
            guard seq > run.startedSeq, run.completionSeq.map({ seq < $0 }) ?? true else {
                throw fail("境界判定の記録が run の期間外にあります")
            }
            let state: ClauseBoundaryState
            let source: SegmentTextReference
            if line.header.eventType == "clause_boundaries.assessed" {
                guard let assessment = assessedBySeq[seq]?.assessment else { throw line.malformed }
                if let request = assessment.request, !requestIDs.insert(request.requestID).inserted {
                    throw fail("境界リクエスト ID が重複しています")
                }
                if case .carriedOver(let sourceRunID, let sourceSeq) = assessment.sourceDecision {
                    guard sourceSeq < seq,
                          let origin = assessedBySeq[sourceSeq], origin.runID == sourceRunID,
                          runs[sourceRunID]?.stage == .clauseBoundary,
                          origin.assessment.hasSameDecisions(as: assessment) else {
                        throw fail("引き継いだ境界判定の元がありません")
                    }
                    _ = try boundaryRun(sourceRunID)
                }
                switch successor(of: assessment.source, before: run.mode == "live" ? seq : nil) {
                case .recognized(let next, let text):
                    guard let head = assessment.nextHead, head.source == next,
                          head.text.utf8.elementsEqual(String(text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)).utf8) else {
                        throw fail("区間 \(assessment.source.segmentID) の次区間先頭が原文と一致しません")
                    }
                case .none, .empty:
                    guard assessment.nextHead == nil else { throw fail("次区間のない区間に次区間先頭があります") }
                case .missing:
                    throw fail("音声認識のない次区間を境界判定に使っています")
                }
                state = .assessed(assessment)
                source = assessment.source
            } else {
                let body = try line.body(PayloadBody<ClauseBoundaryPendingPayload>.self).payload
                state = .pending(reason: body.reason, message: body.message)
                source = body.source
                pending.append(source)
            }
            guard segmentPositions[Self.runKey(source.segmentationRunID, source.segmentID)] != nil,
                  source.asrEventSeq < seq,
                  asrBySegment[Self.runKey(source.segmentationRunID, source.asrRunID)]?[source.segmentID] == source else {
                throw fail("境界判定の原文参照が音声認識区間と一致しません")
            }
            if hasEmptySeparator(before: source, eventSeq: run.mode == "live" ? seq : nil) {
                _ = try assembly.endTextStream()
            }
            if hasMissingPredecessor(of: source) { _ = try assembly.beginAfterASRGap() }
            let input = ClauseAssemblyInput(source: source, text: try text(of: source), state: state)
            do {
                for unit in try assembly.consume(input).closed {
                    expected.append(unit)
                    closureSeqs[unit.reference] = seq
                }
            } catch let error as ClauseAssemblyError {
                throw fail(error.localizedDescription)
            }
            inputs.append((seq, input))
            if case .empty = successor(of: source, before: run.mode == "live" ? seq : nil) {
                _ = try assembly.endTextStream()
            }
        }
        var finished = assembly
        let finishDelta = run.completed ? try finished.finish().closed : []
        let afterFinish = expected + finishDelta
        for unit in finishDelta {
            closureSeqs[unit.reference] = inputs.last?.seq ?? run.startedSeq
        }
        if let completion = run.completion {
            guard completion.completedCount == inputs.count - pending.count, completion.failedCount == pending.count else {
                throw fail("境界判定の完了件数が保存記録と一致しません")
            }
        }
        let storedUnits = stored.map(\.unit)
        if run.completed {
            guard storedUnits == afterFinish else { throw fail("保存された節が境界判定の結果と一致しません") }
        } else {
            guard storedUnits.count <= afterFinish.count,
                  Array(afterFinish.prefix(storedUnits.count)) == storedUnits else {
                throw fail("保存された節が境界判定の結果と一致しません")
            }
        }
        for (seq, unit) in stored {
            guard let closedAt = closureSeqs[unit.reference], closedAt < seq else {
                throw fail("節が対応する境界判定より先に保存されています")
            }
        }
        if let first = inputs.first?.input.source {
            let sources = recognizedSources(segmentationRunID: first.segmentationRunID, asrRunID: first.asrRunID)
                .filter { source in run.completionSeq.map({ source.asrEventSeq < $0 }) ?? true }
            let actual = inputs.map(\.input.source)
            guard actual == (run.completed ? sources : Array(sources.prefix(actual.count))) else {
                throw fail("境界判定の区間 coverage が欠落・逆転しています")
            }
        }
        var composer = ClauseTextComposer()
        var texts: [ClauseReference: String] = [:]
        for unit in storedUnits {
            texts[unit.reference] = try composer.text(of: unit.parts, sourceText: text(of:))
        }
        var unresolved: Set<SegmentTextReference> = []
        for entry in inputs {
            if try (run.completed ? finished : assembly).state(for: entry.input.source) == .boundaryPending {
                unresolved.insert(entry.input.source)
            }
        }
        let result = BoundaryRun(
            runID: runID, complete: run.completed, inputs: inputs, clauses: stored,
            clauseTexts: texts, pendingSources: pending, unresolvedSources: unresolved
        )
        validation.boundaries[runID] = result
        return result
    }

    /// Checks every assignment of a priority run against `boundary` and every carry against its origin.
    func priorityRun(_ runID: String, boundary: BoundaryRun) throws -> PriorityRun {
        func fail(_ reason: String) -> EventLogTranscriptReaderError {
            .inconsistentClauseRun(runID: runID, reason: reason)
        }
        guard let run = runs[runID], run.stage == .contentPriority else { throw fail("優先度 run の開始記録がありません") }
        guard run.completed || (run.mode == "live" && run.completion == nil) else {
            throw fail("未完了の確定・再試行 run は判定元に使えません")
        }
        if let cached = validation.priorities[runID] {
            guard cached.assignments.keys.allSatisfy({ $0.boundaryRunID == boundary.runID }) else {
                throw fail("優先度 run の境界参照が一致しません")
            }
            return cached
        }
        guard validation.checkingPriorities.insert(runID).inserted else { throw fail("優先度の引き継ぎが循環しています") }
        defer { validation.checkingPriorities.remove(runID) }
        var assignments: [ClauseReference: ClausePriorityAssignment] = [:]
        let events = priorityEvents[runID] ?? []
        let clauseSeqs = Dictionary(uniqueKeysWithValues: boundary.clauses.map { ($0.unit.reference, $0.seq) })
        var requestIDs: Set<String> = []
        for (seq, payload) in events {
            guard seq > run.startedSeq, run.completionSeq.map({ seq < $0 }) ?? true else {
                throw fail("優先度の記録が run の期間外にあります")
            }
            if let request = payload.request, !requestIDs.insert(request.requestID).inserted {
                throw fail("優先度リクエスト ID が重複しています")
            }
            for assignment in payload.assignments {
                guard let text = boundary.clauseTexts[assignment.reference] else {
                    throw fail("節 \(assignment.reference.clauseID) は境界判定 run \(boundary.runID) にありません")
                }
                guard let closedAt = clauseSeqs[assignment.reference], closedAt < seq else {
                    throw fail("節が閉じるより先に優先度が保存されています")
                }
                guard !ClauseTextComposer.isBlank(text) else { throw fail("本文のない節に優先度があります") }
                guard assignments.updateValue(assignment, forKey: assignment.reference) == nil else {
                    throw fail("節 \(assignment.reference.clauseID) の優先度が重複しています")
                }
                if case .carriedOver(let sourceRunID, let sourceSeq, let sourceClause, let sourceNeedsRetry) = assignment.decision {
                    guard sourceSeq < seq, runs[sourceRunID]?.stage == .contentPriority,
                          let origin = priorityEvents[sourceRunID]?.first(where: { $0.seq == sourceSeq })?.payload
                            .assignments.first(where: { $0.reference == sourceClause }),
                          origin.needsRetry == sourceNeedsRetry, origin.priority == assignment.priority,
                          let originUnit = clauseEvents[sourceClause.boundaryRunID]?
                            .first(where: { $0.unit.reference == sourceClause })?.unit else {
                        throw fail("引き継いだ優先度の元がありません")
                    }
                    var composer = ClauseTextComposer()
                    let originText = try composer.text(of: originUnit.parts, sourceText: self.text(of:))
                    guard ExactClauseTextKey(text: originText) == ExactClauseTextKey(text: text) else {
                        throw fail("引き継いだ優先度の節本文が一致しません")
                    }
                    let originBoundary = try boundaryRun(sourceClause.boundaryRunID)
                    _ = try priorityRun(sourceRunID, boundary: originBoundary)
                }
            }
        }
        if let completion = run.completion {
            let pendingCount = assignments.values.filter(\.needsRetry).count
            guard completion.completedCount == assignments.count - pendingCount, completion.failedCount == pendingCount else {
                throw fail("優先度の完了件数が保存記録と一致しません")
            }
        }
        if run.completed {
            for (reference, text) in boundary.clauseTexts where !ClauseTextComposer.isBlank(text) {
                guard assignments[reference] != nil else { throw fail("節 \(reference.clauseID) の優先度がありません") }
            }
        }
        let result = PriorityRun(runID: runID, complete: run.completed, events: events, assignments: assignments)
        validation.priorities[runID] = result
        return result
    }

    /// Validate the caller's frozen reuse selection, not a newer "latest" lookup from the log.
    func validateReusableDecisions(_ decisions: [ExactClauseTextKey: ReusableClauseDecision]) throws {
        for (key, reuse) in decisions {
            let boundary = try boundaryRun(reuse.sourceClause.boundaryRunID)
            let priority = try priorityRun(reuse.sourcePriorityRunID, boundary: boundary)
            guard runs[reuse.sourcePriorityRunID]?.mode == "live",
                  runs[reuse.sourceClause.boundaryRunID]?.mode == "live",
                  let text = boundary.clauseTexts[reuse.sourceClause],
                  ExactClauseTextKey(text: text) == key,
                  let assignment = priority.events.first(where: { $0.seq == reuse.sourceEventSeq })?
                    .payload.assignments.first(where: { $0.reference == reuse.sourceClause }),
                  case .classified(_, _, let response) = assignment.decision,
                  response == reuse.decision, assignment.priority == reuse.visiblePriority,
                  !assignment.needsRetry else {
                throw EventLogTranscriptReaderError.inconsistentClauseRun(
                    runID: reuse.sourcePriorityRunID, reason: "再利用するライブ優先度の保存元が一致しません"
                )
            }
        }
    }

    func firstReference(ofPriorityRun runID: String) -> ClauseReference? {
        priorityEvents[runID]?.first?.payload.assignments.first?.reference
    }

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
            guard localEvidence[stage]?.contains(runID) == true || runs[runID]?.completed == true else {
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

/// Reads the events of the active runs. Events of other runs and unknown event types are skipped;
/// an active-run event with a missing or mistyped field throws.
public struct EventLogTranscriptReader: Sendable {
    public init() {}

    /// Durable classified decisions of live priority runs, keyed by the exact filler-removed
    /// clause text. For one text the latest classified event wins; a later pending result
    /// does not remove it. `data` is the event log at the moment finalization freezes it.
    public func liveContentPriorityDecisions(
        from data: Data
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
        for (runID, run) in log.runs where run.stage == .contentPriority && run.mode == "live" {
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

            case "scene.changed":
                let runID = try line.requiredRunID()
                guard runID == activeRuns.scene else { continue }
                let body = try line.body(SceneChangedBody.self)
                events.append(.sceneChanged(seq: seq, runID: runID, atFrame: body.frame, scene: body.scene))

            case "scope.span":
                let runID = try line.requiredRunID()
                guard runID == activeRuns.scope else { continue }
                let span = try line.body(ScopeSpanBody.self).span
                events.append(.scopeSpan(
                    seq: seq,
                    runID: runID,
                    startFrame: span.startFrame,
                    endFrame: span.endFrame,
                    scope: span.scope,
                    confidence: span.confidence
                ))

            default:
                continue
            }
        }

        let log = try ClauseEventLog(lines: decoded, selectedRuns: Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization, activeRuns.scene, activeRuns.scope,
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

/// The Jev results a retry must request again, checked against the event log.
public struct JevRetryTargets: Sendable, Equatable {
    public let boundarySegments: [SegmentTextReference]
    public let clauses: [ClauseReference]

    public init(boundarySegments: [SegmentTextReference], clauses: [ClauseReference]) {
        self.boundarySegments = boundarySegments
        self.clauses = clauses
    }
}

/// Checks the pending lists of the published metadata against the event log. An unpublished
/// retry or finalization run is never adopted: retries start again from the published snapshot.
public struct JevRetryAnalyzer: Sendable {
    public init() {}

    /// A newer final/retry Jev run was saved without atomically publishing its snapshot.
    /// Live runs and runs replaced by the current published snapshot are not recovery work.
    public func hasUnpublishedJevRun(lines: [Data], activeRuns: ActiveRuns) throws -> Bool {
        let decoded = try EventLogLine.decode(lines)
        let active = Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization, activeRuns.scene,
            activeRuns.scope, activeRuns.clauseBoundary, activeRuns.contentPriority
        ].compactMap { $0 })
        let watermark = decoded.lazy.filter {
            ($0.header.eventType == "processing.run.started" || $0.header.eventType == "processing.run.completed")
                && $0.header.processingRunID.map(active.contains) == true
        }.map(\.header.eventSeq).max() ?? 0
        var found = false
        for line in decoded where line.header.eventSeq > watermark && line.header.eventType == "processing.run.started" {
            guard let object = try JSONSerialization.jsonObject(with: line.data) as? [String: Any],
                  let raw = object["payload"] as? [String: Any],
                  let stage = raw["stage"] as? String,
                  stage == ProcessingStage.clauseBoundary.rawValue || stage == ProcessingStage.contentPriority.rawValue,
                  let provenance = raw["provenance"] as? [String: Any],
                  let configuration = provenance["configuration"] as? [String: Any],
                  let mode = configuration["mode"] as? String, mode == "final" || mode == "retry" else { continue }
            _ = try line.body(PayloadBody<ProcessingRunStartedPayload>.self)
            let runID = try line.requiredRunID()
            if !active.contains(runID) { found = true }
        }
        return found
    }

    public func retryTargets(lines: [Data], metadata: ProcessingMetadata) throws -> JevRetryTargets {
        guard let activeRuns = metadata.activeRuns,
              let segmentationRunID = activeRuns.segmentation, let asrRunID = activeRuns.asr else {
            throw EventLogTranscriptReaderError.inconsistentClauseRun(runID: "", reason: "公開された文字起こしがありません")
        }
        let log = try ClauseEventLog(lines: EventLogLine.decode(lines), selectedRuns: Set([
            activeRuns.segmentation, activeRuns.asr, activeRuns.diarization, activeRuns.scene, activeRuns.scope,
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
        return JevRetryTargets(boundarySegments: expectedBoundary, clauses: expectedClauses)
    }
}
