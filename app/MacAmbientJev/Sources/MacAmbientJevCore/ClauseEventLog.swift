import Foundation
/// Decodes and checks every clause event of a log against the ASR text it refers to.
/// Reader, retry analysis, live reuse and the saved-session catalog all go through it.
struct ClauseEventLog {
    struct Run {
        let stage: ProcessingStage
        let mode: String?
        let modelRevision: String?
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
                    modelRevision: started.provenance.configuration["model_revision"],
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

    func hasLocalEvidence(for stage: ProcessingStage, runID: String) -> Bool {
        localEvidence[stage]?.contains(runID) == true
    }

}
