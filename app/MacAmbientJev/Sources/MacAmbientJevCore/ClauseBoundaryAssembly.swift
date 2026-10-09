import Foundation

public struct ClauseAssemblyInput: Sendable, Equatable {
    public let source: SegmentTextReference
    public let text: String
    public let state: ClauseBoundaryState

    public init(source: SegmentTextReference, text: String, state: ClauseBoundaryState) {
        self.source = source
        self.text = text
        self.state = state
    }
}

public enum ClauseAssemblyRowState: Sendable, Equatable {
    /// The row ends in a clause that continues into a segment not assessed yet.
    case awaitingNextSegment
    /// Part of the row depends on a boundary result that is pending.
    case boundaryPending
    case resolved
}

public struct ClauseAssemblyDelta: Sendable, Equatable {
    public let closed: [ClauseUnit]
    public let affectedSources: [SegmentTextReference]

    public init(closed: [ClauseUnit], affectedSources: [SegmentTextReference]) {
        self.closed = closed
        self.affectedSources = affectedSources
    }
}

public enum ClauseAssemblyError: LocalizedError, Sendable, Equatable {
    case finished
    case emptyText
    case outOfOrder
    case unexpectedSuccessor
    case candidateMismatch
    case sourceMismatch
    case unknownSource

    public var errorDescription: String? {
        switch self {
        case .finished: "節の組み立ては終了しています"
        case .emptyText: "空の区間は節の組み立てに使えません"
        case .outOfOrder: "節の組み立ての区間順序が不正です"
        case .unexpectedSuccessor: "境界判定の次区間が実際の次区間と一致しません"
        case .candidateMismatch: "境界判定の候補が原文と一致しません"
        case .sourceMismatch: "境界判定の区間が原文と一致しません"
        case .unknownSource: "節の組み立てに含まれない区間です"
        }
    }
}

/// Assembles clauses from boundary results consumed one source at a time in time order.
/// A pending result never closes a clause across it: the open tail it touches, the source
/// itself, and the head of the following source stay unresolved.
public struct ClauseBoundaryAssembly: Sendable {
    /// Immutable links make a transaction checkpoint independent of the open tail's length.
    private final class TailPart: Sendable {
        let part: ClauseSourcePart
        let previous: TailPart?
        let count: Int

        init(_ part: ClauseSourcePart, previous: TailPart?) {
            self.part = part
            self.previous = previous
            self.count = (previous?.count ?? 0) + 1
        }

        var parts: [ClauseSourcePart] {
            var result: [ClauseSourcePart] = []
            result.reserveCapacity(count)
            var link: TailPart? = self
            while let current = link {
                result.append(current.part)
                link = current.previous
            }
            result.reverse()
            return result
        }
    }

    private struct Tail: Sendable {
        var last: TailPart?
        let firstOrdinal: Int
        /// True when the tail touches a pending result and can never close as a clause.
        var unresolved: Bool

        var parts: [ClauseSourcePart] { last?.parts ?? [] }
        mutating func append(_ part: ClauseSourcePart) {
            last = TailPart(part, previous: last)
        }
    }

    private let boundaryRunID: String
    private var finished = false
    private var lastSource: SegmentTextReference?
    private var expectedSuccessor: NextSegmentHead?
    private var tail: Tail?
    private var unresolvedSources: Set<SegmentTextReference> = []
    private var consumedSources: [SegmentTextReference: Int] = [:]
    private var recordingUndo = false
    private var consumedUndo: [SegmentTextReference] = []
    private var unresolvedUndo: [SegmentTextReference] = []

    public init(boundaryRunID: String) {
        self.boundaryRunID = boundaryRunID
    }

    /// Journals only newly touched sources. A failed batch restores the cursor without
    /// copying its historical source indexes or its possibly long cross-segment tail.
    public mutating func withTransaction<Result>(
        _ body: (inout ClauseBoundaryAssembly) throws -> Result
    ) rethrows -> Result {
        precondition(!recordingUndo, "clause assembly transactions cannot nest")
        let previousFinished = finished
        let previousSource = lastSource
        let previousSuccessor = expectedSuccessor
        let previousTail = tail
        recordingUndo = true
        defer {
            recordingUndo = false
            consumedUndo.removeAll(keepingCapacity: true)
            unresolvedUndo.removeAll(keepingCapacity: true)
        }
        do {
            return try body(&self)
        } catch {
            for source in consumedUndo { consumedSources.removeValue(forKey: source) }
            for source in unresolvedUndo { unresolvedSources.remove(source) }
            finished = previousFinished
            lastSource = previousSource
            expectedSuccessor = previousSuccessor
            tail = previousTail
            throw error
        }
    }

    /// Checks a stored stream-end closure without finishing the live cursor.
    public func openStreamEndClause() throws -> ClauseUnit? {
        guard let tail, !tail.unresolved, tail.last != nil else { return nil }
        return try clause(parts: tail.parts, termination: .streamEnd)
    }

    public mutating func consume(_ input: ClauseAssemblyInput) throws -> ClauseAssemblyDelta {
        guard !finished else { throw ClauseAssemblyError.finished }
        guard ASRRecognitionOutcome(text: input.text) == .recognized else { throw ClauseAssemblyError.emptyText }
        if let lastSource {
            guard input.source.segmentationRunID == lastSource.segmentationRunID,
                  input.source.asrRunID == lastSource.asrRunID,
                  input.source.asrEventSeq > lastSource.asrEventSeq else { throw ClauseAssemblyError.outOfOrder }
        }
        if let expectedSuccessor {
            guard expectedSuccessor.source == input.source,
                  String(input.text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)).utf8
                    .elementsEqual(expectedSuccessor.text.utf8) else {
                throw ClauseAssemblyError.unexpectedSuccessor
            }
        }
        let length = input.text.utf16.count
        var closed: [ClauseUnit] = []
        var affected: [SegmentTextReference] = []

        switch input.state {
        case .pending:
            let whole = try ClauseSourcePart(source: input.source, range: TextUTF16Range(start: 0, end: length))
            let alreadyUnresolved = tail?.unresolved == true
            if tail == nil {
                tail = Tail(last: nil, firstOrdinal: consumedSources.count, unresolved: true)
            }
            tail!.append(whole)
            tail!.unresolved = true
            markUnresolved(alreadyUnresolved ? [whole] : tail!.parts, affected: &affected)
            expectedSuccessor = nil

        case .assessed(let assessment):
            guard assessment.source == input.source else { throw ClauseAssemblyError.sourceMismatch }
            guard assessment.candidates == (try ClauseBoundaryCandidate.candidates(in: input.text)) else {
                throw ClauseAssemblyError.candidateMismatch
            }
            var start = 0
            for boundary in assessment.acceptedBoundaries {
                let part = try ClauseSourcePart(
                    source: input.source, range: TextUTF16Range(start: start, end: boundary.offsetUTF16)
                )
                var clauseParts = [part]
                var unresolved = false
                if let open = tail {
                    clauseParts = open.parts + clauseParts
                    unresolved = open.unresolved
                    tail = nil
                }
                if unresolved {
                    markUnresolved(clauseParts, affected: &affected)
                } else {
                    closed.append(try clause(parts: clauseParts, termination: .internalBoundary(
                        source: input.source, candidateID: boundary.id
                    )))
                }
                start = boundary.offsetUTF16
            }
            let last = try ClauseSourcePart(source: input.source, range: TextUTF16Range(start: start, end: length))
            if tail != nil {
                tail!.append(last)
            } else {
                tail = Tail(last: TailPart(last, previous: nil), firstOrdinal: consumedSources.count, unresolved: false)
            }
            if assessment.nextHead == nil {
                try closeTail(termination: .streamEnd, closed: &closed, affected: &affected)
            } else if !assessment.continuesIntoNext {
                try closeTail(termination: .notContinued(source: input.source), closed: &closed, affected: &affected)
            }
            // A successor head is sent only for a non-empty successor, which is consumed next.
            expectedSuccessor = assessment.nextHead
        }

        consumedSources[input.source] = consumedSources.count
        if recordingUndo { consumedUndo.append(input.source) }
        lastSource = input.source
        affected.append(input.source)
        for unit in closed { affected.append(contentsOf: unit.parts.map(\.source)) }
        return ClauseAssemblyDelta(closed: closed, affectedSources: Self.unique(affected))
    }

    /// A failed ASR segment leaves the next head's start unknown, even when no recognized
    /// source preceded the gap. Only a later accepted internal boundary can end that head.
    public mutating func beginAfterASRGap() throws -> ClauseAssemblyDelta {
        guard !finished else { throw ClauseAssemblyError.finished }
        var affected: [SegmentTextReference] = []
        let alreadyUnresolved = tail?.unresolved == true
        if tail == nil {
            tail = Tail(last: nil, firstOrdinal: consumedSources.count, unresolved: true)
        }
        tail!.unresolved = true
        if !alreadyUnresolved { markUnresolved(tail!.parts, affected: &affected) }
        expectedSuccessor = nil
        return ClauseAssemblyDelta(closed: [], affectedSources: Self.unique(affected))
    }

    /// An empty successful ASR segment ends the text stream. Pending ranges remain pending,
    /// but cannot contaminate a later stream's head. This never invents a closed clause.
    public mutating func endTextStream() throws -> ClauseAssemblyDelta {
        guard !finished else { throw ClauseAssemblyError.finished }
        var affected: [SegmentTextReference] = []
        if let open = tail {
            guard open.unresolved else { throw ClauseAssemblyError.unexpectedSuccessor }
            markUnresolved(open.parts, affected: &affected)
        }
        tail = nil
        expectedSuccessor = nil
        return ClauseAssemblyDelta(closed: [], affectedSources: Self.unique(affected))
    }

    /// Closes the tail the assessments already ended. A tail touching a pending result stays
    /// unresolved. Calling it again returns an empty delta.
    public mutating func finish() throws -> ClauseAssemblyDelta {
        guard !finished else { return ClauseAssemblyDelta(closed: [], affectedSources: []) }
        finished = true
        var closed: [ClauseUnit] = []
        var affected: [SegmentTextReference] = []
        try closeTail(termination: .streamEnd, closed: &closed, affected: &affected)
        for unit in closed { affected.append(contentsOf: unit.parts.map(\.source)) }
        return ClauseAssemblyDelta(closed: closed, affectedSources: Self.unique(affected))
    }

    public func state(for source: SegmentTextReference) throws -> ClauseAssemblyRowState {
        guard let ordinal = consumedSources[source] else { throw ClauseAssemblyError.unknownSource }
        if unresolvedSources.contains(source) { return .boundaryPending }
        if let tail, ordinal >= tail.firstOrdinal { return .awaitingNextSegment }
        return .resolved
    }

    private mutating func closeTail(
        termination: ClauseTermination,
        closed: inout [ClauseUnit],
        affected: inout [SegmentTextReference]
    ) throws {
        guard let open = tail else { return }
        tail = nil
        if open.unresolved {
            markUnresolved(open.parts, affected: &affected)
        } else {
            closed.append(try clause(parts: open.parts, termination: termination))
        }
    }

    private mutating func markUnresolved(_ parts: [ClauseSourcePart], affected: inout [SegmentTextReference]) {
        for part in parts {
            if unresolvedSources.insert(part.source).inserted, recordingUndo {
                unresolvedUndo.append(part.source)
            }
            affected.append(part.source)
        }
    }

    private func clause(parts: [ClauseSourcePart], termination: ClauseTermination) throws -> ClauseUnit {
        try ClauseUnit(
            reference: ClauseReference(boundaryRunID: boundaryRunID, clauseID: ClauseUnit.clauseID(firstPart: parts[0])),
            parts: parts,
            termination: termination
        )
    }

    private static func unique(_ sources: [SegmentTextReference]) -> [SegmentTextReference] {
        var seen: Set<SegmentTextReference> = []
        return sources.filter { seen.insert($0).inserted }.sorted { $0.asrEventSeq < $1.asrEventSeq }
    }
}
