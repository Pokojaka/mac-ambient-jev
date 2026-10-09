import Foundation

public enum TranscriptEventKind: Sendable, Equatable {
    case segmentCreated
    case asrCompleted(ASRResult)
    case speakerSpan(SpeakerSpan)
    case sceneChanged(SceneState)
    case scopeSpan(ScopeSpan)
    case clauseBoundaryAssessed(ClauseBoundaryAssessment)
    case clauseBoundaryPending(ClauseBoundaryPendingPayload)
    case clauseClosed(ClauseUnit)
    case contentPriorityAssigned(ContentPriorityAssignedPayload)
}

public struct TranscriptEvent: Sendable, Equatable {
    public let eventSeq: UInt64
    public let processingRunID: String?
    public let segmentationRunID: String?
    public let segmentID: String?
    public let sourceStartFrame: Int64?
    public let sourceEndFrame: Int64?
    public let kind: TranscriptEventKind

    public init(
        eventSeq: UInt64,
        processingRunID: String? = nil,
        segmentationRunID: String? = nil,
        segmentID: String? = nil,
        sourceStartFrame: Int64? = nil,
        sourceEndFrame: Int64? = nil,
        kind: TranscriptEventKind
    ) {
        self.eventSeq = eventSeq
        self.processingRunID = processingRunID
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.sourceStartFrame = sourceStartFrame
        self.sourceEndFrame = sourceEndFrame
        self.kind = kind
    }

    public static func segmentCreated(
        seq: UInt64, segmentationRunID: String, segmentID: String,
        startFrame: Int64, endFrame: Int64
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .segmentCreated
        )
    }

    public static func asrCompleted(
        seq: UInt64, runID: String, segmentationRunID: String,
        segmentID: String, text: String, detectedLanguage: String?
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            kind: .asrCompleted(ASRResult(text: text, detectedLanguage: detectedLanguage))
        )
    }

    public static func speakerSpan(
        seq: UInt64, runID: String, speakerID: String,
        startFrame: Int64, endFrame: Int64, confidence: Double?
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .speakerSpan(
                SpeakerSpan(
                    speakerID: speakerID,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    confidence: confidence
                )
            )
        )
    }

    public static func sceneChanged(
        seq: UInt64, runID: String, atFrame: Int64, scene: SceneState
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: atFrame,
            kind: .sceneChanged(scene)
        )
    }

    public static func scopeSpan(
        seq: UInt64, runID: String, startFrame: Int64, endFrame: Int64,
        scope: AcousticScope, confidence: Double
    ) -> TranscriptEvent {
        TranscriptEvent(
            eventSeq: seq,
            processingRunID: runID,
            sourceStartFrame: startFrame,
            sourceEndFrame: endFrame,
            kind: .scopeSpan(
                ScopeSpan(
                    startFrame: startFrame,
                    endFrame: endFrame,
                    scope: scope,
                    confidence: confidence
                )
            )
        )
    }

    /// One Jev clause event of `runID`; clause events carry their sources in the payload.
    public static func clause(seq: UInt64, runID: String, kind: TranscriptEventKind) -> TranscriptEvent {
        TranscriptEvent(eventSeq: seq, processingRunID: runID, kind: kind)
    }

    /// The text reference of an `asr.completed` event; nil for other events.
    public func asrSource() throws -> SegmentTextReference? {
        guard case .asrCompleted = kind, let runID = processingRunID,
              let segmentationRunID, let segmentID else { return nil }
        return try SegmentTextReference(
            segmentationRunID: segmentationRunID, segmentID: segmentID, asrRunID: runID, asrEventSeq: eventSeq
        )
    }
}

struct SceneTransitionTimeline {
    private let transitions: [(frame: Int64, sequence: UInt64, scene: SceneState)]

    init(events: [TranscriptEvent], activeSceneRunID: String?) {
        transitions = events.compactMap { event in
            guard event.processingRunID == activeSceneRunID,
                  let frame = event.sourceStartFrame,
                  case .sceneChanged(let scene) = event.kind else {
                return nil
            }
            return (frame: frame, sequence: event.eventSeq, scene: scene)
        }
        .sorted {
            if $0.frame != $1.frame { return $0.frame < $1.frame }
            return $0.sequence < $1.sequence
        }
    }

    func scene(at frame: Int64) -> SceneState {
        let index = firstIndex(after: frame)
        return index == 0 ? .unknown : transitions[index - 1].scene
    }

    func frames(after startFrame: Int64, before endFrame: Int64) -> [Int64] {
        var frames: [Int64] = []
        var index = firstIndex(after: startFrame)
        while index < transitions.count && transitions[index].frame < endFrame {
            frames.append(transitions[index].frame)
            index += 1
        }
        return frames
    }

    private func firstIndex(after frame: Int64) -> Int {
        var lower = 0
        var upper = transitions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if transitions[middle].frame <= frame {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }
}

public struct MaterializedSpeakerSpan: Encodable, Sendable, Equatable {
    public let id: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let confidence: Double?
    public let displayLabel: String?

    public init(
        id: String, startMilliseconds: Int64, endMilliseconds: Int64,
        confidence: Double?, displayLabel: String?
    ) {
        self.id = id
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.confidence = confidence
        self.displayLabel = displayLabel
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case confidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMilliseconds, forKey: .startMilliseconds)
        try container.encode(endMilliseconds, forKey: .endMilliseconds)
        try container.encodeIfPresent(confidence, forKey: .confidence)
    }
}

public struct MaterializedScopeSpan: Encodable, Sendable, Equatable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let scope: AcousticScope
    public let confidence: Double

    public init(
        startMilliseconds: Int64, endMilliseconds: Int64,
        scope: AcousticScope, confidence: Double
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.scope = scope
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case scope
        case confidence
    }
}


/// How far Jev has resolved one transcript row.
public enum TranscriptClauseState: String, Codable, Sendable, Equatable {
    /// The row ends in a clause that may continue into the next segment.
    case awaitingNextSegment = "awaiting_next_segment"
    /// Part of the row has no boundary result.
    case boundaryPending = "boundary_pending"
    /// Every boundary is known, but a clause has no priority yet.
    case priorityPending = "priority_pending"
    case classified
}

/// The part of one clause inside one row.
public struct ClauseRowSlice: Encodable, Sendable, Equatable {
    public let reference: ClauseReference
    /// Raw ASR text range of this row.
    public let sourceRange: TextUTF16Range
    /// Ranges in the row's `display_text`.
    public let displayRanges: [TextUTF16Range]
    public let priority: ContentPriority?
    public let needsRetry: Bool

    public init(
        reference: ClauseReference,
        sourceRange: TextUTF16Range,
        displayRanges: [TextUTF16Range],
        priority: ContentPriority?,
        needsRetry: Bool
    ) {
        self.reference = reference
        self.sourceRange = sourceRange
        self.displayRanges = displayRanges
        self.priority = priority
        self.needsRetry = needsRetry
    }

    enum CodingKeys: String, CodingKey {
        case reference
        case sourceRange = "source_range"
        case displayRanges = "display_ranges"
        case priority
        case needsRetry = "needs_retry"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(sourceRange, forKey: .sourceRange)
        try c.encode(displayRanges, forKey: .displayRanges)
        try c.encode(priority, forKey: .priority)
        try c.encode(needsRetry, forKey: .needsRetry)
    }
}

/// A closed clause of the active boundary run with its priority in the active priority run.
public struct MaterializedClause: Sendable, Equatable {
    public let unit: ClauseUnit
    /// True when the filler-removed clause text is only whitespace; such a clause is not classified.
    public let isBlank: Bool
    public let priority: ContentPriority?
    public let needsRetry: Bool
    public let decision: ClausePriorityDecision?

    public init(unit: ClauseUnit, isBlank: Bool, priority: ContentPriority?, needsRetry: Bool, decision: ClausePriorityDecision?) {
        self.unit = unit
        self.isBlank = isBlank
        self.priority = priority
        self.needsRetry = needsRetry
        self.decision = decision
    }

    /// True when the clause still waits for a priority.
    var isPriorityUnresolved: Bool { !isBlank && (priority == nil || needsRetry) }
}

/// One transcript segment of the active runs. Encoded as a `segments.json` entry;
/// `isDiarized` is not part of that file.
public struct MaterializedTranscriptSegment: Encodable, Sendable, Equatable, Identifiable {
    public var id: String { segmentID }
    public var hasRecognizedText: Bool { ASRRecognitionOutcome(text: text) == .recognized }
    /// The filler-removed text shown on screen and in transcript.txt.
    public var displayText: String { textProjection.text }
    public let segmentID: String
    public let source: SegmentTextReference
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    /// The ASR text as recognized.
    public let text: String
    public let textProjection: CleanedTranscriptText
    public let scene: SceneState
    public let speakers: [MaterializedSpeakerSpan]
    public let scopeSpans: [MaterializedScopeSpan]
    /// Nil only when the segment has no recognized text.
    public let clauseState: TranscriptClauseState?
    public let clauseSlices: [ClauseRowSlice]
    /// True when the result comes from a diarization run, even if no span overlaps this segment.
    public let isDiarized: Bool

    public init(
        segmentID: String, source: SegmentTextReference, startMilliseconds: Int64, endMilliseconds: Int64,
        text: String, textProjection: CleanedTranscriptText, scene: SceneState,
        speakers: [MaterializedSpeakerSpan], scopeSpans: [MaterializedScopeSpan],
        clauseState: TranscriptClauseState?, clauseSlices: [ClauseRowSlice], isDiarized: Bool
    ) {
        self.segmentID = segmentID
        self.source = source
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
        self.textProjection = textProjection
        self.scene = scene
        self.speakers = speakers
        self.scopeSpans = scopeSpans
        self.clauseState = clauseState
        self.clauseSlices = clauseSlices
        self.isDiarized = isDiarized
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case source
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case text
        case displayText = "display_text"
        case scene
        case speakers
        case scopeSpans = "scope_spans"
        case clauseState = "clause_state"
        case clauseSlices = "clause_slices"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segmentID, forKey: .segmentID)
        try c.encode(source, forKey: .source)
        try c.encode(startMilliseconds, forKey: .startMilliseconds)
        try c.encode(endMilliseconds, forKey: .endMilliseconds)
        try c.encode(text, forKey: .text)
        try c.encode(displayText, forKey: .displayText)
        try c.encode(scene, forKey: .scene)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(scopeSpans, forKey: .scopeSpans)
        try c.encode(clauseState, forKey: .clauseState)
        try c.encode(clauseSlices, forKey: .clauseSlices)
    }

    /// The priority slices covering the whole raw text: clause slices, and unresolved gaps.
    func prioritySlices() throws -> [TranscriptPrioritySlice] {
        guard source.segmentID == segmentID, text.utf16.count == textProjection.sourceUTF16Length else {
            throw TranscriptMaterializationError.missingClauseSource
        }
        var result: [TranscriptPrioritySlice] = []
        var cursor = 0
        for slice in clauseSlices {
            guard slice.sourceRange.start >= cursor, slice.sourceRange.start < slice.sourceRange.end,
                  try textProjection.displayRanges(for: slice.sourceRange) == slice.displayRanges else {
                throw TranscriptMaterializationError.invalidClauseSlice(segmentID: segmentID)
            }
            if cursor < slice.sourceRange.start {
                result.append(TranscriptPrioritySlice(
                    sourceRange: try TextUTF16Range(start: cursor, end: slice.sourceRange.start),
                    priority: nil, needsRetry: false
                ))
            }
            result.append(TranscriptPrioritySlice(
                sourceRange: slice.sourceRange, priority: slice.priority, needsRetry: slice.needsRetry
            ))
            cursor = slice.sourceRange.end
        }
        let end = textProjection.sourceUTF16Length
        if !clauseSlices.isEmpty, cursor < end {
            result.append(TranscriptPrioritySlice(
                sourceRange: try TextUTF16Range(start: cursor, end: end), priority: nil, needsRetry: false
            ))
        }
        return result
    }
}

public enum TranscriptMaterializationError: LocalizedError, Sendable, Equatable {
    case missingClauseSource
    case clauseNotAssembled(clauseID: String)
    case duplicateClause(clauseID: String)
    case duplicatePriority(clauseID: String)
    case unknownPriorityClause(clauseID: String)
    case priorityForBlankClause(clauseID: String)
    case overlappingClauses(segmentID: String)
    case missingClauseState(segmentID: String)
    case invalidClauseSlice(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .missingClauseSource: "節の原文が文字起こしにありません"
        case .clauseNotAssembled(let id): "保存された節 \(id) が境界判定から組み立てられません"
        case .duplicateClause(let id): "節 \(id) が重複しています"
        case .duplicatePriority(let id): "節 \(id) の優先度が重複しています"
        case .unknownPriorityClause(let id): "優先度の対象の節 \(id) がありません"
        case .priorityForBlankClause(let id): "本文のない節 \(id) に優先度があります"
        case .overlappingClauses(let id): "区間 \(id) の節が重なっています"
        case .missingClauseState(let id): "区間 \(id) には表示する本文がありません"
        case .invalidClauseSlice(let id): "区間 \(id) の節範囲と表示本文が一致しません"
        }
    }
}

public struct TranscriptMaterializer: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    public func materialize(
        events: [TranscriptEvent],
        activeRuns: ActiveRuns
    ) throws -> [MaterializedTranscriptSegment] {
        let ordered = events.sorted { $0.eventSeq < $1.eventSeq }
        var createdIDs: Set<String> = []
        var createdSeqs: [String: UInt64] = [:]
        for event in ordered where event.segmentationRunID == activeRuns.segmentation {
            guard case .segmentCreated = event.kind else { continue }
            guard let segmentID = event.segmentID, let start = event.sourceStartFrame,
                  let end = event.sourceEndFrame, start >= 0, start < end,
                  createdIDs.insert(segmentID).inserted else {
                throw TranscriptMaterializationError.missingClauseSource
            }
            createdSeqs[segmentID] = event.eventSeq
        }
        var asrResults: [String?: [String: (result: ASRResult, source: SegmentTextReference)]] = [:]
        var speakerSpans: [SpeakerSpan] = []
        var activeScopeSpans: [ScopeSpan] = []
        let scenes = SceneTransitionTimeline(events: ordered, activeSceneRunID: activeRuns.scene)
        var boundaryInputs: [(seq: UInt64, source: SegmentTextReference, state: ClauseBoundaryState)] = []
        var storedClauses: [ClauseUnit] = []
        var assignments: [ClauseReference: ClausePriorityAssignment] = [:]
        for event in ordered {
            switch event.kind {
            case .asrCompleted(let result) where event.processingRunID == activeRuns.asr
                && event.segmentationRunID == activeRuns.segmentation:
                guard let segmentID = event.segmentID, let source = try event.asrSource(),
                      let createdSeq = createdSeqs[segmentID], createdSeq < event.eventSeq else {
                    throw TranscriptMaterializationError.missingClauseSource
                }
                asrResults[event.segmentationRunID, default: [:]][segmentID] = (result, source)
            case .speakerSpan(let span) where event.processingRunID == activeRuns.diarization:
                speakerSpans.append(span)
            case .scopeSpan(let span) where event.processingRunID == activeRuns.scope:
                activeScopeSpans.append(span)
            case .clauseBoundaryAssessed(let assessment) where event.processingRunID == activeRuns.clauseBoundary:
                boundaryInputs.append((event.eventSeq, assessment.source, .assessed(assessment)))
            case .clauseBoundaryPending(let pending) where event.processingRunID == activeRuns.clauseBoundary:
                boundaryInputs.append((event.eventSeq, pending.source, .pending(reason: pending.reason, message: pending.message)))
            case .clauseClosed(let unit) where event.processingRunID == activeRuns.clauseBoundary:
                storedClauses.append(unit)
            case .contentPriorityAssigned(let payload) where event.processingRunID == activeRuns.contentPriority:
                for assignment in payload.assignments {
                    guard assignments.updateValue(assignment, forKey: assignment.reference) == nil else {
                        throw TranscriptMaterializationError.duplicatePriority(clauseID: assignment.reference.clauseID)
                    }
                }
            default:
                break
            }
        }

        var sourceTexts: [SegmentTextReference: String] = [:]
        for results in asrResults.values {
            for entry in results.values { sourceTexts[entry.source] = entry.result.text }
        }
        func text(of source: SegmentTextReference) throws -> String {
            guard let text = sourceTexts[source] else { throw TranscriptMaterializationError.missingClauseSource }
            return text
        }

        // Replays the stored boundary results to learn which rows are unresolved and to check
        // that every stored clause is one the results produce.
        var assembly = activeRuns.clauseBoundary.map(ClauseBoundaryAssembly.init(boundaryRunID:))
        var assessedSources: Set<SegmentTextReference> = []
        var pendingSources: Set<SegmentTextReference> = []
        var assembled: [ClauseReference: ClauseUnit] = [:]
        if var replay = assembly {
            let timeline = try SourceTimeline(events: events, activeRuns: activeRuns)
            let sourceIndices = Dictionary(uniqueKeysWithValues: timeline.sources.enumerated().map { ($0.element.source, $0.offset) })
            for input in boundaryInputs {
                guard let index = sourceIndices[input.source], input.source.asrEventSeq < input.seq else {
                    throw TranscriptMaterializationError.missingClauseSource
                }
                if case .assessed(let assessment) = input.state {
                    switch timeline.successor(ofSourceAt: index) {
                    case .recognized(let next, let raw):
                        guard let head = assessment.nextHead, head.source == next,
                              head.text.utf8.elementsEqual(String(raw.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)).utf8) else {
                            throw ClauseAssemblyError.unexpectedSuccessor
                        }
                    case .none, .empty:
                        guard assessment.nextHead == nil else { throw ClauseAssemblyError.unexpectedSuccessor }
                    case .missing:
                        throw ClauseAssemblyError.unexpectedSuccessor
                    }
                }
                if timeline.hasEmptySeparator(beforeSourceAt: index) {
                    _ = try replay.endTextStream()
                }
                if timeline.hasMissingPredecessor(ofSourceAt: index) {
                    _ = try replay.beginAfterASRGap()
                }
                let delta = try replay.consume(ClauseAssemblyInput(
                    source: input.source, text: try text(of: input.source), state: input.state
                ))
                for unit in delta.closed { assembled[unit.reference] = unit }
                switch input.state {
                case .assessed: assessedSources.insert(input.source)
                case .pending: pendingSources.insert(input.source)
                }
                if case .empty = timeline.successor(ofSourceAt: index) {
                    _ = try replay.endTextStream()
                }
            }
            assembly = replay
            var finished = replay
            for unit in try finished.finish().closed { assembled[unit.reference] = unit }
        }

        var composer = ClauseTextComposer()
        var clauses: [ClauseReference: MaterializedClause] = [:]
        var slicesBySource: [SegmentTextReference: [ClauseRowSlice]] = [:]
        for unit in storedClauses {
            guard assembled[unit.reference] == unit else {
                throw TranscriptMaterializationError.clauseNotAssembled(clauseID: unit.reference.clauseID)
            }
            guard clauses[unit.reference] == nil else {
                throw TranscriptMaterializationError.duplicateClause(clauseID: unit.reference.clauseID)
            }
            let isBlank = ClauseTextComposer.isBlank(try composer.text(of: unit.parts, sourceText: text(of:)))
            let assignment = assignments.removeValue(forKey: unit.reference)
            if assignment != nil, isBlank {
                throw TranscriptMaterializationError.priorityForBlankClause(clauseID: unit.reference.clauseID)
            }
            let clause = MaterializedClause(
                unit: unit, isBlank: isBlank, priority: assignment?.priority,
                needsRetry: assignment?.needsRetry ?? false, decision: assignment?.decision
            )
            clauses[unit.reference] = clause
            for part in unit.parts {
                let projection = try composer.projection(of: part.source, text: text(of: part.source))
                slicesBySource[part.source, default: []].append(ClauseRowSlice(
                    reference: unit.reference,
                    sourceRange: part.range,
                    displayRanges: try projection.displayRanges(for: part.range),
                    priority: clause.priority,
                    needsRetry: clause.needsRetry
                ))
            }
        }
        if let unknown = assignments.keys.first {
            throw TranscriptMaterializationError.unknownPriorityClause(clauseID: unknown.clauseID)
        }

        let speakerLabels = SpeakerDisplayMapper.makeLabels(spans: speakerSpans)
        let segmentEvents = ordered.filter { event in
            guard case .segmentCreated = event.kind else { return false }
            return activeRuns.segmentation == nil
                || event.segmentationRunID == activeRuns.segmentation
        }

        var segments: [MaterializedTranscriptSegment] = []
        for segmentEvent in segmentEvents {
            guard let segmentID = segmentEvent.segmentID,
                  let startFrame = segmentEvent.sourceStartFrame,
                  let endFrame = segmentEvent.sourceEndFrame,
                  let asr = asrResults[segmentEvent.segmentationRunID]?[segmentID] else {
                continue
            }

            let speakers = speakerSpans.compactMap { span -> MaterializedSpeakerSpan? in
                let clippedStart = max(startFrame, span.startFrame)
                let clippedEnd = min(endFrame, span.endFrame)
                guard clippedStart < clippedEnd else { return nil }
                return MaterializedSpeakerSpan(
                    id: span.speakerID,
                    startMilliseconds: milliseconds(forFrame: clippedStart),
                    endMilliseconds: milliseconds(forFrame: clippedEnd),
                    confidence: span.confidence,
                    displayLabel: speakerLabels[span.speakerID]
                )
            }

            let scopeSpans = activeScopeSpans.compactMap { span -> MaterializedScopeSpan? in
                let clippedStart = max(startFrame, span.startFrame)
                let clippedEnd = min(endFrame, span.endFrame)
                guard clippedStart < clippedEnd else { return nil }
                return MaterializedScopeSpan(
                    startMilliseconds: milliseconds(forFrame: clippedStart),
                    endMilliseconds: milliseconds(forFrame: clippedEnd),
                    scope: span.scope,
                    confidence: span.confidence
                )
            }

            let source = asr.source
            let projection = try composer.projection(of: source, text: asr.result.text)
            let slices = (slicesBySource[source] ?? []).sorted { $0.sourceRange.start < $1.sourceRange.start }
            var covered = 0
            var previousEnd = 0
            for slice in slices {
                guard slice.sourceRange.start >= previousEnd else {
                    throw TranscriptMaterializationError.overlappingClauses(segmentID: segmentID)
                }
                previousEnd = slice.sourceRange.end
                covered += slice.sourceRange.end - slice.sourceRange.start
            }
            let state: TranscriptClauseState?
            if ASRRecognitionOutcome(text: asr.result.text) != .recognized {
                state = nil
            } else if let assembly {
                let unresolved = try assessedSources.contains(source)
                    && assembly.state(for: source) == .boundaryPending
                if pendingSources.contains(source) || unresolved {
                    state = .boundaryPending
                } else if !assessedSources.contains(source) || covered < projection.sourceUTF16Length {
                    state = .awaitingNextSegment
                } else if slices.contains(where: { clauses[$0.reference]?.isPriorityUnresolved == true }) {
                    state = .priorityPending
                } else {
                    state = .classified
                }
            } else {
                state = .boundaryPending
            }

            segments.append(MaterializedTranscriptSegment(
                segmentID: segmentID,
                source: source,
                startMilliseconds: milliseconds(forFrame: startFrame),
                endMilliseconds: milliseconds(forFrame: endFrame),
                text: asr.result.text,
                textProjection: projection,
                scene: scenes.scene(at: startFrame),
                speakers: speakers,
                scopeSpans: scopeSpans,
                clauseState: state,
                clauseSlices: slices,
                isDiarized: activeRuns.diarization != nil
            ))
        }
        return segments.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }

    private func milliseconds(forFrame frame: Int64) -> Int64 {
        Int64((Double(frame) * 1_000.0 / sampleRate).rounded(.towardZero))
    }
}

public struct LiveTranscriptRow: Sendable, Equatable, Identifiable {
    public var id: String { segmentID }
    public let segmentID: String
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    /// The filler-removed text, including low-priority text.
    public let text: String
    public let textFragments: [TranscriptTextFragment]
    public let scene: SceneState
    public let speakers: [MaterializedSpeakerSpan]
    public let displaySpeakerLabels: [String]
    public let scopeSpans: [MaterializedScopeSpan]
    public let clauseState: TranscriptClauseState
    public let shouldCollapseRow: Bool

    public init(segment: MaterializedTranscriptSegment, displaySpeakerLabels: [String]) throws {
        guard let state = segment.clauseState else {
            throw TranscriptMaterializationError.missingClauseState(segmentID: segment.segmentID)
        }
        let presentation = try TranscriptPriorityPresentationPolicy().present(
            text: segment.textProjection,
            slices: try segment.prioritySlices(),
            hasUnresolvedBoundary: state == .awaitingNextSegment || state == .boundaryPending
        )
        self.segmentID = segment.segmentID
        self.startMilliseconds = segment.startMilliseconds
        self.endMilliseconds = segment.endMilliseconds
        self.text = presentation.text
        self.textFragments = presentation.fragments
        self.scene = segment.scene
        self.speakers = segment.speakers
        self.displaySpeakerLabels = displaySpeakerLabels
        self.scopeSpans = segment.scopeSpans
        self.clauseState = state
        self.shouldCollapseRow = presentation.shouldCollapseRow
    }
}

/// Shared screen and transcript.txt projection.
public struct LiveTranscriptProjection: Sendable {
    public init() {}
    public func rows(for segments: [MaterializedTranscriptSegment]) throws -> [LiveTranscriptRow] {
        let allSpeakerSpans = segments.flatMap(\.speakers).map {
            SpeakerSpan(speakerID: $0.id, startFrame: $0.startMilliseconds, endFrame: $0.endMilliseconds, confidence: $0.confidence)
        }
        let labels = SpeakerDisplayMapper.makeLabels(spans: allSpeakerSpans)
        var rows: [LiveTranscriptRow] = []
        for segment in segments where segment.hasRecognizedText {
            let isBackgroundOnly = segment.scene == .discussion && !segment.scopeSpans.isEmpty
                && segment.scopeSpans.allSatisfy { $0.scope == .background }
            guard !isBackgroundOnly, !ClauseTextComposer.isBlank(segment.displayText) else { continue }
            rows.append(try LiveTranscriptRow(
                segment: segment,
                displaySpeakerLabels: segment.isDiarized ? SpeakerDisplayMapper.turnLabels(for: segment, labels: labels) : []
            ))
        }
        return rows
    }
}
