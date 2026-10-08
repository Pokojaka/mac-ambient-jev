import Foundation

public enum ClauseRecordError: LocalizedError, Sendable, Equatable {
    case invalidClauseReference
    case invalidClausePart
    case invalidClauseUnit
    case invalidAssessment
    case invalidPriorityAssignment
    case invalidPriorityEvent

    public var errorDescription: String? {
        switch self {
        case .invalidClauseReference: "節の参照が不正です"
        case .invalidClausePart: "節の原文範囲が不正です"
        case .invalidClauseUnit: "節の構成が不正です"
        case .invalidAssessment: "境界判定の記録が不正です"
        case .invalidPriorityAssignment: "優先度判定の記録が不正です"
        case .invalidPriorityEvent: "優先度判定イベントが不正です"
        }
    }
}

private func isNonblankIdentifier(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

public struct ClauseReference: Codable, Sendable, Hashable {
    public let boundaryRunID: String
    public let clauseID: String

    public init(boundaryRunID: String, clauseID: String) throws {
        guard isNonblankIdentifier(boundaryRunID), isNonblankIdentifier(clauseID) else {
            throw ClauseRecordError.invalidClauseReference
        }
        self.boundaryRunID = boundaryRunID
        self.clauseID = clauseID
    }

    enum CodingKeys: String, CodingKey {
        case boundaryRunID = "boundary_run_id", clauseID = "clause_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            boundaryRunID: c.decode(String.self, forKey: .boundaryRunID),
            clauseID: c.decode(String.self, forKey: .clauseID)
        )
    }
}

public struct ClauseSourcePart: Codable, Sendable, Hashable {
    public let source: SegmentTextReference
    public let range: TextUTF16Range

    public init(source: SegmentTextReference, range: TextUTF16Range) throws {
        guard range.start < range.end else { throw ClauseRecordError.invalidClausePart }
        self.source = source
        self.range = range
    }

    enum CodingKeys: String, CodingKey { case source, range }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SegmentTextReference.self, forKey: .source),
            range: c.decode(TextUTF16Range.self, forKey: .range)
        )
    }
}

public enum ClauseTermination: Codable, Sendable, Equatable {
    case internalBoundary(source: SegmentTextReference, candidateID: String)
    /// Jev answered that the clause does not continue into the next segment.
    case notContinued(source: SegmentTextReference)
    /// The text stream ended (recording stop, last segment, or an empty successor).
    /// This is not a grammatical boundary.
    case streamEnd

    private enum CodingKeys: String, CodingKey { case kind, source, candidateID = "candidate_id" }
    private enum Kind: String, Codable { case internalBoundary = "internal_boundary", notContinued = "not_continued", streamEnd = "stream_end" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .internalBoundary:
            let candidateID = try c.decode(String.self, forKey: .candidateID)
            _ = try ClauseBoundaryCandidate(id: candidateID, offsetUTF16: 1)
            self = .internalBoundary(source: try c.decode(SegmentTextReference.self, forKey: .source), candidateID: candidateID)
        case .notContinued:
            self = .notContinued(source: try c.decode(SegmentTextReference.self, forKey: .source))
        case .streamEnd:
            self = .streamEnd
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .internalBoundary(let source, let candidateID):
            try c.encode(Kind.internalBoundary, forKey: .kind)
            try c.encode(source, forKey: .source)
            try c.encode(candidateID, forKey: .candidateID)
        case .notContinued(let source):
            try c.encode(Kind.notContinued, forKey: .kind)
            try c.encode(source, forKey: .source)
        case .streamEnd:
            try c.encode(Kind.streamEnd, forKey: .kind)
        }
    }
}

/// A clause made of raw ASR text ranges. A clause spanning segments has one part per segment.
public struct ClauseUnit: Codable, Sendable, Equatable {
    public let reference: ClauseReference
    public let parts: [ClauseSourcePart]
    public let termination: ClauseTermination

    public static func clauseID(firstPart: ClauseSourcePart) -> String {
        "c\(firstPart.source.asrEventSeq)_\(firstPart.range.start)"
    }

    public init(reference: ClauseReference, parts: [ClauseSourcePart], termination: ClauseTermination) throws {
        guard let first = parts.first, reference.clauseID == Self.clauseID(firstPart: first) else {
            throw ClauseRecordError.invalidClauseUnit
        }
        for (previous, next) in zip(parts, parts.dropFirst()) {
            guard next.source.segmentationRunID == previous.source.segmentationRunID,
                  next.source.asrRunID == previous.source.asrRunID,
                  next.source.asrEventSeq > previous.source.asrEventSeq,
                  next.range.start == 0 else { throw ClauseRecordError.invalidClauseUnit }
        }
        switch termination {
        case .internalBoundary(let source, _), .notContinued(let source):
            guard source == parts[parts.count - 1].source else { throw ClauseRecordError.invalidClauseUnit }
        case .streamEnd:
            break
        }
        self.reference = reference
        self.parts = parts
        self.termination = termination
    }

    enum CodingKeys: String, CodingKey { case reference, parts, termination }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: c.decode(ClauseReference.self, forKey: .reference),
            parts: c.decode([ClauseSourcePart].self, forKey: .parts),
            termination: c.decode(ClauseTermination.self, forKey: .termination)
        )
    }
}

/// One HTTP request to Jev and the metadata of its response.
public struct JevRequestRecord: Codable, Sendable, Equatable {
    public let requestID: String
    public let metadata: JevResponseMetadata

    public init(requestID: String, metadata: JevResponseMetadata) throws {
        guard isNonblankIdentifier(requestID) else { throw ClauseRecordError.invalidAssessment }
        self.requestID = requestID
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey { case requestID = "request_id", metadata }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: c.decode(String.self, forKey: .requestID),
            metadata: c.decode(JevResponseMetadata.self, forKey: .metadata)
        )
    }
}

public enum ClausePendingReason: String, Codable, Sendable {
    case unconfigured
    case stopped
    case initializationFailed = "initialization_failed"
    case authorizationRejected = "authorization_rejected"
    case requestFailed = "request_failed"
    case asrGap = "asr_gap"
    case cancelled
}

public enum BoundaryDecisionSource: Codable, Sendable, Equatable {
    /// Jev answered this boundary request in this run.
    case assessed
    /// The last text segment had no candidate and no successor, so no request was needed.
    case terminalWithoutQuestions
    /// A retry run reused the published assessment of this source.
    case carriedOver(sourceBoundaryRunID: String, sourceEventSeq: UInt64)

    private enum CodingKeys: String, CodingKey {
        case kind, sourceBoundaryRunID = "source_boundary_run_id", sourceEventSeq = "source_event_seq"
    }
    private enum Kind: String, Codable {
        case assessed, terminalWithoutQuestions = "terminal_without_questions", carriedOver = "carried_over"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .assessed: self = .assessed
        case .terminalWithoutQuestions: self = .terminalWithoutQuestions
        case .carriedOver:
            let runID = try c.decode(String.self, forKey: .sourceBoundaryRunID)
            guard isNonblankIdentifier(runID) else { throw ClauseRecordError.invalidAssessment }
            self = .carriedOver(sourceBoundaryRunID: runID, sourceEventSeq: try c.decode(UInt64.self, forKey: .sourceEventSeq))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .assessed: try c.encode(Kind.assessed, forKey: .kind)
        case .terminalWithoutQuestions: try c.encode(Kind.terminalWithoutQuestions, forKey: .kind)
        case .carriedOver(let runID, let seq):
            try c.encode(Kind.carriedOver, forKey: .kind)
            try c.encode(runID, forKey: .sourceBoundaryRunID)
            try c.encode(seq, forKey: .sourceEventSeq)
        }
    }
}

/// Payload of `clause_boundaries.assessed`.
public struct ClauseBoundaryAssessment: Codable, Sendable, Equatable {
    public let source: SegmentTextReference
    public let candidates: [ClauseBoundaryCandidate]
    public let probabilities: [String: Double]
    public let nextHead: NextSegmentHead?
    public let continuationProbability: Double?
    public let request: JevRequestRecord?
    public let sourceDecision: BoundaryDecisionSource

    public init(
        source: SegmentTextReference,
        candidates: [ClauseBoundaryCandidate],
        probabilities: [String: Double],
        nextHead: NextSegmentHead?,
        continuationProbability: Double?,
        request: JevRequestRecord?,
        sourceDecision: BoundaryDecisionSource
    ) throws {
        guard Set(probabilities.keys) == Set(candidates.map(\.id)),
              Set(candidates.map(\.id)).count == candidates.count,
              probabilities.values.allSatisfy(isValidProbability),
              (nextHead == nil) == (continuationProbability == nil),
              continuationProbability.map(isValidProbability) ?? true else {
            throw ClauseRecordError.invalidAssessment
        }
        for (previous, next) in zip(candidates, candidates.dropFirst()) where next.offsetUTF16 <= previous.offsetUTF16 {
            throw ClauseRecordError.invalidAssessment
        }
        if let nextHead {
            guard nextHead.source.segmentationRunID == source.segmentationRunID,
                  nextHead.source.asrRunID == source.asrRunID,
                  nextHead.source.segmentID != source.segmentID,
                  nextHead.source.asrEventSeq > source.asrEventSeq else { throw ClauseRecordError.invalidAssessment }
        }
        switch sourceDecision {
        case .assessed:
            guard request != nil, !candidates.isEmpty || nextHead != nil else { throw ClauseRecordError.invalidAssessment }
        case .terminalWithoutQuestions:
            guard request == nil, candidates.isEmpty, nextHead == nil else { throw ClauseRecordError.invalidAssessment }
        case .carriedOver(let sourceBoundaryRunID, let sourceEventSeq):
            guard request == nil, isNonblankIdentifier(sourceBoundaryRunID), sourceEventSeq > 0 else {
                throw ClauseRecordError.invalidAssessment
            }
        }
        self.source = source
        self.candidates = candidates
        self.probabilities = probabilities
        self.nextHead = nextHead
        self.continuationProbability = continuationProbability
        self.request = request
        self.sourceDecision = sourceDecision
    }

    /// The candidates Jev accepted as absolute or strong boundaries, in text order.
    public var acceptedBoundaries: [ClauseBoundaryCandidate] {
        candidates.filter { candidate in
            probabilities[candidate.id].map(ClauseBoundaryPolicy.acceptsBoundary) == true
        }
    }

    /// True when the clause at the end of this source continues into `nextHead`.
    public var continuesIntoNext: Bool {
        continuationProbability.map(ClauseBoundaryPolicy.acceptsContinuation) ?? false
    }

    /// The same decisions recorded as carried over from `eventSeq` of `runID`.
    public func carriedOver(fromRunID runID: String, eventSeq: UInt64) throws -> ClauseBoundaryAssessment {
        try ClauseBoundaryAssessment(
            source: source, candidates: candidates, probabilities: probabilities,
            nextHead: nextHead, continuationProbability: continuationProbability,
            request: nil, sourceDecision: .carriedOver(sourceBoundaryRunID: runID, sourceEventSeq: eventSeq)
        )
    }

    /// True when both record the same Jev decisions for the same source and successor head.
    public func hasSameDecisions(as other: ClauseBoundaryAssessment) -> Bool {
        guard source == other.source, candidates == other.candidates,
              probabilities == other.probabilities,
              continuationProbability == other.continuationProbability else { return false }
        switch (nextHead, other.nextHead) {
        case (nil, nil):
            return true
        case (.some(let head), .some(let otherHead)):
            return head.source == otherHead.source && head.text.utf8.elementsEqual(otherHead.text.utf8)
        default:
            return false
        }
    }

    enum CodingKeys: String, CodingKey {
        case source, candidates, probabilities
        case nextHead = "next_head"
        case continuationProbability = "continuation_probability"
        case request
        case sourceDecision = "source_decision"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SegmentTextReference.self, forKey: .source),
            candidates: c.decode([ClauseBoundaryCandidate].self, forKey: .candidates),
            probabilities: c.decode([String: Double].self, forKey: .probabilities),
            nextHead: c.decode(NextSegmentHead?.self, forKey: .nextHead),
            continuationProbability: c.decode(Double?.self, forKey: .continuationProbability),
            request: c.decode(JevRequestRecord?.self, forKey: .request),
            sourceDecision: c.decode(BoundaryDecisionSource.self, forKey: .sourceDecision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(candidates, forKey: .candidates)
        try c.encode(probabilities, forKey: .probabilities)
        try c.encode(nextHead, forKey: .nextHead)
        try c.encode(continuationProbability, forKey: .continuationProbability)
        try c.encode(request, forKey: .request)
        try c.encode(sourceDecision, forKey: .sourceDecision)
    }
}

/// Payload of `clause_boundaries.pending`: the source has no boundary result in this run.
public struct ClauseBoundaryPendingPayload: Codable, Sendable, Equatable {
    public let source: SegmentTextReference
    public let reason: ClausePendingReason
    public let message: String

    public init(source: SegmentTextReference, reason: ClausePendingReason, message: String) {
        self.source = source
        self.reason = reason
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case source, reason, message }
}

public enum ClauseBoundaryState: Sendable, Equatable {
    case assessed(ClauseBoundaryAssessment)
    case pending(reason: ClausePendingReason, message: String)
}

public enum ClausePriorityDecision: Codable, Sendable, Equatable {
    case classified(requestID: String, answerKey: String, response: ContentPriorityDecision)
    case retryPending(reason: ClausePendingReason, message: String)
    case carriedOver(sourcePriorityRunID: String, sourceEventSeq: UInt64, sourceClause: ClauseReference, sourceNeedsRetry: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestID = "request_id", answerKey = "answer_key", response
        case reason, message
        case sourcePriorityRunID = "source_priority_run_id", sourceEventSeq = "source_event_seq"
        case sourceClause = "source_clause", sourceNeedsRetry = "source_needs_retry"
    }
    private enum Kind: String, Codable { case classified, retryPending = "retry_pending", carriedOver = "carried_over" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .classified:
            let requestID = try c.decode(String.self, forKey: .requestID)
            let answerKey = try c.decode(String.self, forKey: .answerKey)
            guard isNonblankIdentifier(requestID), isRequestLocalKey(answerKey, prefix: "u") else {
                throw ClauseRecordError.invalidPriorityAssignment
            }
            self = .classified(requestID: requestID, answerKey: answerKey, response: try c.decode(ContentPriorityDecision.self, forKey: .response))
        case .retryPending:
            self = .retryPending(reason: try c.decode(ClausePendingReason.self, forKey: .reason), message: try c.decode(String.self, forKey: .message))
        case .carriedOver:
            let runID = try c.decode(String.self, forKey: .sourcePriorityRunID)
            guard isNonblankIdentifier(runID) else { throw ClauseRecordError.invalidPriorityAssignment }
            self = .carriedOver(
                sourcePriorityRunID: runID,
                sourceEventSeq: try c.decode(UInt64.self, forKey: .sourceEventSeq),
                sourceClause: try c.decode(ClauseReference.self, forKey: .sourceClause),
                sourceNeedsRetry: try c.decode(Bool.self, forKey: .sourceNeedsRetry)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .classified(let requestID, let answerKey, let response):
            try c.encode(Kind.classified, forKey: .kind)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(answerKey, forKey: .answerKey)
            try c.encode(response, forKey: .response)
        case .retryPending(let reason, let message):
            try c.encode(Kind.retryPending, forKey: .kind)
            try c.encode(reason, forKey: .reason)
            try c.encode(message, forKey: .message)
        case .carriedOver(let runID, let seq, let clause, let needsRetry):
            try c.encode(Kind.carriedOver, forKey: .kind)
            try c.encode(runID, forKey: .sourcePriorityRunID)
            try c.encode(seq, forKey: .sourceEventSeq)
            try c.encode(clause, forKey: .sourceClause)
            try c.encode(needsRetry, forKey: .sourceNeedsRetry)
        }
    }
}

public struct ClausePriorityAssignment: Codable, Sendable, Equatable {
    public let reference: ClauseReference
    public let priority: ContentPriority?
    public let needsRetry: Bool
    public let decision: ClausePriorityDecision

    public init(reference: ClauseReference, priority: ContentPriority?, needsRetry: Bool, decision: ClausePriorityDecision) throws {
        switch decision {
        case .classified(let requestID, let answerKey, let response):
            guard isNonblankIdentifier(requestID), isRequestLocalKey(answerKey, prefix: "u"),
                  !needsRetry, priority == ContentPriorityPolicy.visiblePriority(for: response) else {
                throw ClauseRecordError.invalidPriorityAssignment
            }
        case .retryPending:
            guard needsRetry, priority == nil else { throw ClauseRecordError.invalidPriorityAssignment }
        case .carriedOver(let sourcePriorityRunID, let sourceEventSeq, _, let sourceNeedsRetry):
            guard isNonblankIdentifier(sourcePriorityRunID), sourceEventSeq > 0,
                  needsRetry == sourceNeedsRetry, (priority == nil) == needsRetry else {
                throw ClauseRecordError.invalidPriorityAssignment
            }
        }
        self.reference = reference
        self.priority = priority
        self.needsRetry = needsRetry
        self.decision = decision
    }

    enum CodingKeys: String, CodingKey { case reference, priority, needsRetry = "needs_retry", decision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: c.decode(ClauseReference.self, forKey: .reference),
            priority: c.decode(ContentPriority?.self, forKey: .priority),
            needsRetry: c.decode(Bool.self, forKey: .needsRetry),
            decision: c.decode(ClausePriorityDecision.self, forKey: .decision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(priority, forKey: .priority)
        try c.encode(needsRetry, forKey: .needsRetry)
        try c.encode(decision, forKey: .decision)
    }
}

/// Payload of `content_priority.assigned`: every result of one Choice request, or
/// assignments made without a request (carried over or left pending).
public struct ContentPriorityAssignedPayload: Codable, Sendable, Equatable {
    public let assignments: [ClausePriorityAssignment]
    public let request: JevRequestRecord?

    public init(assignments: [ClausePriorityAssignment], request: JevRequestRecord?) throws {
        guard !assignments.isEmpty,
              Set(assignments.map(\.reference)).count == assignments.count else {
            throw ClauseRecordError.invalidPriorityEvent
        }
        var answerKeys: Set<String> = []
        for assignment in assignments {
            if case .classified(let requestID, let answerKey, _) = assignment.decision {
                guard requestID == request?.requestID, answerKeys.insert(answerKey).inserted else {
                    throw ClauseRecordError.invalidPriorityEvent
                }
            } else if request != nil {
                throw ClauseRecordError.invalidPriorityEvent
            }
        }
        guard answerKeys.count <= JevPriorityBatchPolicy.maximumTargets else { throw ClauseRecordError.invalidPriorityEvent }
        if request != nil {
            let expected = Set((1...assignments.count).map { String(format: "u%04d", $0) })
            guard answerKeys == expected else { throw ClauseRecordError.invalidPriorityEvent }
        }
        self.assignments = assignments
        self.request = request
    }

    enum CodingKeys: String, CodingKey { case assignments, request }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            assignments: c.decode([ClausePriorityAssignment].self, forKey: .assignments),
            request: c.decode(JevRequestRecord?.self, forKey: .request)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assignments, forKey: .assignments)
        try c.encode(request, forKey: .request)
    }
}

/// Exact filler-removed clause text. Equality and hashing use the UTF-8 bytes, not
/// Swift's canonical string equivalence.
public struct ExactClauseTextKey: Sendable, Hashable {
    public let text: String
    public init(text: String) { self.text = text }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in text.utf8 { hasher.combine(byte) }
    }
}

/// A durable classified live decision that finalization may carry over.
public struct ReusableClauseDecision: Sendable, Equatable {
    public let sourcePriorityRunID: String
    public let sourceEventSeq: UInt64
    public let sourceClause: ClauseReference
    public let decision: ContentPriorityDecision
    public let visiblePriority: ContentPriority

    public init(
        sourcePriorityRunID: String,
        sourceEventSeq: UInt64,
        sourceClause: ClauseReference,
        decision: ContentPriorityDecision,
        visiblePriority: ContentPriority
    ) {
        self.sourcePriorityRunID = sourcePriorityRunID
        self.sourceEventSeq = sourceEventSeq
        self.sourceClause = sourceClause
        self.decision = decision
        self.visiblePriority = visiblePriority
    }
}

/// What a pending Jev result waits for: a segment's boundary request or a clause's priority.
public enum JevPendingTarget: Sendable, Hashable {
    case boundary(SegmentTextReference)
    case priority(ClauseReference)
}

/// Builds the filler-removed text of clauses from the raw ASR text of their parts.
public struct ClauseTextComposer: Sendable {
    private let projector = TranscriptTextProjector(detector: FillerTextSpanDetector())
    private var projections: [SegmentTextReference: CleanedTranscriptText] = [:]
    private var displayCursors: [SegmentTextReference: (offset: Int, index: String.Index)] = [:]

    public init() {}

    public mutating func projection(of source: SegmentTextReference, text: String) throws -> CleanedTranscriptText {
        if let cached = projections[source] { return cached }
        let projected = try projector.project(sourceText: text)
        projections[source] = projected
        return projected
    }

    /// Parts are joined without inserting any separator.
    public mutating func text(
        of parts: [ClauseSourcePart],
        sourceText: (SegmentTextReference) throws -> String
    ) throws -> String {
        var result = ""
        for part in parts {
            let projected = try projection(of: part.source, text: sourceText(part.source))
            for range in try projected.displayRanges(for: part.range) {
                let prior = displayCursors[part.source]
                let cursor = prior.flatMap { $0.offset <= range.start ? $0 : nil }
                    ?? (offset: 0, index: projected.text.utf16.startIndex)
                let lower16 = projected.text.utf16.index(cursor.index, offsetBy: range.start - cursor.offset)
                let upper16 = projected.text.utf16.index(lower16, offsetBy: range.end - range.start)
                guard let lower = String.Index(lower16, within: projected.text),
                      let upper = String.Index(upper16, within: projected.text) else {
                    throw TextUTF16RangeError.invalidCharacterBoundary(start: range.start, end: range.end)
                }
                result.append(contentsOf: projected.text[lower..<upper])
                displayCursors[part.source] = (range.end, upper16)
            }
        }
        return result
    }

    public static func isBlank(_ text: String) -> Bool {
        !text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
