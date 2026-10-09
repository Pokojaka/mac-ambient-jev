import Foundation

/// Materializes the fixed live ASR/Jev runs. Historical rows and source projections are
/// indexed once; a batch journals only the clauses and sources it touches.
public final class IncrementalTranscriptMaterializer {
    private struct Segment {
        let id: String
        let createdSeq: UInt64
        let start: Int64
        let end: Int64
        var source: SegmentTextReference?
    }

    private struct Source {
        let text: String
        /// Nil only while an ASR completion's timeline is being validated.
        let projection: CleanedTranscriptText?
    }

    private struct Boundary {
        let state: ClauseBoundaryState
        let emptySeparator: Bool
        let missingPredecessor: Bool
    }

    private struct RowPart {
        let reference: ClauseReference
        let range: TextUTF16Range
    }

    private final class Cursor {
        var assembly: ClauseBoundaryAssembly
        init(runID: String) { assembly = ClauseBoundaryAssembly(boundaryRunID: runID) }
    }

    private let sampleRate: Double
    private let segmentationRunID: String
    private let asrRunID: String
    private let cursor: Cursor?
    private var segments: [Segment] = []
    private var segmentIndices: [String: Int] = [:]
    private var resultPositions: [Int] = []
    private var recognizedPositions: [Int] = []
    private var sources: [SegmentTextReference: Source] = [:]
    private var rowIndices: [SegmentTextReference: Int] = [:]
    private var rows: [MaterializedTranscriptSegment] = []
    private var boundaries: [SegmentTextReference: Boundary] = [:]
    private var lastBoundarySeq: UInt64?
    private var assembled: [ClauseReference: ClauseUnit] = [:]
    private var clauses: [ClauseReference: MaterializedClause] = [:]
    private var assigned: Set<ClauseReference> = []
    private var partsBySource: [SegmentTextReference: [RowPart]] = [:]
    private var provisionalStreamEnd: ClauseUnit?
    private var composer = ClauseTextComposer()

    public init(sampleRate: Double, segmentationRunID: String, asrRunID: String, clauseBoundaryRunID: String?) {
        self.sampleRate = sampleRate
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.cursor = clauseBoundaryRunID.map(Cursor.init(runID:))
    }

    /// Arrays share storage with snapshots until a caller retains one across a mutation.
    public var materializedSegments: [MaterializedTranscriptSegment] { rows }

    public func appendSourceEvent(_ event: TranscriptEvent) throws {
        switch event.kind {
        case .segmentCreated:
            try register(event)
        case .asrCompleted(let result):
            try complete(event, text: result.text)
        default:
            throw TranscriptMaterializationError.missingClauseSource
        }
    }

    private func register(_ event: TranscriptEvent) throws {
        guard event.segmentationRunID == segmentationRunID,
              let id = event.segmentID, segmentIndices[id] == nil,
              let start = event.sourceStartFrame, let end = event.sourceEndFrame,
              start >= 0, end > start else { throw TranscriptMaterializationError.missingClauseSource }
        let position = segments.last.map { $0.start <= start } ?? true
            ? segments.count : segments.firstIndex { $0.start > start } ?? segments.count
        segments.insert(Segment(id: id, createdSeq: event.eventSeq, start: start, end: end), at: position)
        for index in position..<segments.count { segmentIndices[segments[index].id] = index }
        shiftPositions(from: position, by: 1)
        do {
            try validateChangedTimeline(at: position)
        } catch {
            segments.remove(at: position)
            segmentIndices.removeValue(forKey: id)
            for index in position..<segments.count { segmentIndices[segments[index].id] = index }
            shiftPositions(from: position + 1, by: -1)
            throw error
        }
    }

    private func complete(_ event: TranscriptEvent, text: String) throws {
        guard event.processingRunID == asrRunID, event.segmentationRunID == segmentationRunID,
              let id = event.segmentID, let position = segmentIndices[id],
              segments[position].createdSeq < event.eventSeq,
              segments[position].source == nil, let source = try event.asrSource() else {
            throw TranscriptMaterializationError.missingClauseSource
        }
        let recognized = ASRRecognitionOutcome(text: text) == .recognized
        let resultIndex = insertionIndex(position, in: resultPositions)
        let recognizedIndex = insertionIndex(position, in: recognizedPositions)
        if recognized, cursor != nil {
            if recognizedIndex > 0,
               let previous = segments[recognizedPositions[recognizedIndex - 1]].source,
               previous.asrEventSeq >= source.asrEventSeq { throw JevEnrichmentError.invalidSourceTimeline }
            if recognizedIndex < recognizedPositions.count,
               let next = segments[recognizedPositions[recognizedIndex]].source,
               source.asrEventSeq >= next.asrEventSeq { throw JevEnrichmentError.invalidSourceTimeline }
        }
        segments[position].source = source
        sources[source] = Source(text: text, projection: nil)
        resultPositions.insert(position, at: resultIndex)
        if recognized { recognizedPositions.insert(position, at: recognizedIndex) }
        do {
            try validateChangedTimeline(at: position)
            let projection = try composer.projection(of: source, text: text)
            sources[source] = Source(text: text, projection: projection)
            let row = try makeRow(source, assembly: nil)
            let rowIndex = rows.last.map { rowPrecedes($0, row) } ?? true
                ? rows.count : rows.firstIndex { rowPrecedes(row, $0) } ?? rows.count
            rows.insert(row, at: rowIndex)
            for index in rowIndex..<rows.count { rowIndices[rows[index].source] = index }
        } catch {
            segments[position].source = nil
            sources.removeValue(forKey: source)
            resultPositions.remove(at: resultIndex)
            if recognized { recognizedPositions.remove(at: recognizedIndex) }
            throw error
        }
    }

    /// The caller checks run ownership. Event-list order is immaterial, as in the canonical
    /// rebuild; boundary chronology, source identity and clause/priority uniqueness are not.
    public func applyClauseEvents(_ events: [TranscriptEvent]) throws {
        guard !events.isEmpty else { return }
        guard let cursor else { throw TranscriptMaterializationError.missingClauseSource }
        let ordered = events.sorted { $0.eventSeq < $1.eventSeq }
        var addedBoundaries: [SegmentTextReference] = []
        var addedAssembled: [ClauseReference] = []
        var addedClauses: [ClauseReference] = []
        var addedAssignments: [ClauseReference] = []
        var replacedClauses: [(ClauseReference, MaterializedClause)] = []
        var dirty: Set<SegmentTextReference> = []
        let previousSeq = lastBoundarySeq
        let previousProvisional = provisionalStreamEnd
        do {
            try cursor.assembly.withTransaction { assembly in
                for event in ordered {
                    let source: SegmentTextReference
                    let state: ClauseBoundaryState
                    switch event.kind {
                    case .clauseBoundaryAssessed(let assessment):
                        source = assessment.source
                        state = .assessed(assessment)
                    case .clauseBoundaryPending(let pending):
                        source = pending.source
                        state = .pending(reason: pending.reason, message: pending.message)
                    default: continue
                    }
                    guard let entry = sources[source], let position = segmentIndices[source.segmentID],
                          segments[position].source == source, source.asrEventSeq < event.eventSeq,
                          lastBoundarySeq.map({ $0 <= event.eventSeq }) ?? true else {
                        throw TranscriptMaterializationError.missingClauseSource
                    }
                    let context = try boundaryContext(at: position, state: state)
                    if context.emptySeparator { dirty.formUnion(try assembly.endTextStream().affectedSources) }
                    if context.missingPredecessor { dirty.formUnion(try assembly.beginAfterASRGap().affectedSources) }
                    let delta = try assembly.consume(ClauseAssemblyInput(source: source, text: entry.text, state: state))
                    dirty.formUnion(delta.affectedSources)
                    for unit in delta.closed {
                        assembled[unit.reference] = unit
                        addedAssembled.append(unit.reference)
                    }
                    if successorIsEmpty(at: position) {
                        dirty.formUnion(try assembly.endTextStream().affectedSources)
                    }
                    boundaries[source] = Boundary(state: state,
                        emptySeparator: context.emptySeparator, missingPredecessor: context.missingPredecessor)
                    addedBoundaries.append(source)
                    lastBoundarySeq = event.eventSeq
                }
                // A stream-end clause produced only by a hypothetical finish cannot survive
                // a later change to that tail. Check it only when the cursor actually changes.
                if !addedBoundaries.isEmpty, let previousProvisional,
                   assembled[previousProvisional.reference] != previousProvisional {
                    guard try assembly.openStreamEndClause() == previousProvisional else {
                        throw TranscriptMaterializationError.clauseNotAssembled(clauseID: previousProvisional.reference.clauseID)
                    }
                }
                for event in ordered {
                    guard case .clauseClosed(let unit) = event.kind else { continue }
                    guard clauses[unit.reference] == nil else {
                        throw TranscriptMaterializationError.duplicateClause(clauseID: unit.reference.clauseID)
                    }
                    if assembled[unit.reference] != unit {
                        guard try assembly.openStreamEndClause() == unit else {
                            throw TranscriptMaterializationError.clauseNotAssembled(clauseID: unit.reference.clauseID)
                        }
                        provisionalStreamEnd = unit
                    }
                    let text = try composer.text(of: unit.parts) { source in
                        guard let entry = self.sources[source] else { throw TranscriptMaterializationError.missingClauseSource }
                        return entry.text
                    }
                    clauses[unit.reference] = MaterializedClause(unit: unit, isBlank: ClauseTextComposer.isBlank(text),
                        priority: nil, needsRetry: false, decision: nil)
                    addedClauses.append(unit.reference)
                    for part in unit.parts {
                        partsBySource[part.source, default: []].append(RowPart(reference: unit.reference, range: part.range))
                        dirty.insert(part.source)
                    }
                }
                for event in ordered {
                    guard case .contentPriorityAssigned(let payload) = event.kind else { continue }
                    for assignment in payload.assignments {
                        guard assigned.insert(assignment.reference).inserted else {
                            throw TranscriptMaterializationError.duplicatePriority(clauseID: assignment.reference.clauseID)
                        }
                        addedAssignments.append(assignment.reference)
                        guard let clause = clauses[assignment.reference] else {
                            throw TranscriptMaterializationError.unknownPriorityClause(clauseID: assignment.reference.clauseID)
                        }
                        guard !clause.isBlank else {
                            throw TranscriptMaterializationError.priorityForBlankClause(clauseID: assignment.reference.clauseID)
                        }
                        replacedClauses.append((assignment.reference, clause))
                        clauses[assignment.reference] = MaterializedClause(unit: clause.unit, isBlank: false,
                            priority: assignment.priority, needsRetry: assignment.needsRetry, decision: assignment.decision)
                        dirty.formUnion(clause.unit.parts.map(\.source))
                    }
                }
                // Prepare every changed row before publishing any of them.
                let replacements = try dirty.map { source -> (Int, MaterializedTranscriptSegment) in
                    guard let index = rowIndices[source] else { throw TranscriptMaterializationError.missingClauseSource }
                    return (index, try makeRow(source, assembly: assembly))
                }
                for (index, row) in replacements { rows[index] = row }
            }
        } catch {
            for source in addedBoundaries { boundaries.removeValue(forKey: source) }
            for reference in addedAssembled { assembled.removeValue(forKey: reference) }
            for (reference, clause) in replacedClauses { clauses[reference] = clause }
            for reference in addedAssignments { assigned.remove(reference) }
            for reference in addedClauses {
                if let clause = clauses.removeValue(forKey: reference) {
                    for part in clause.unit.parts {
                        partsBySource[part.source]?.removeAll { $0.reference == reference }
                    }
                }
            }
            lastBoundarySeq = previousSeq
            provisionalStreamEnd = previousProvisional
            throw error
        }
    }

    private func makeRow(_ source: SegmentTextReference, assembly: ClauseBoundaryAssembly?) throws -> MaterializedTranscriptSegment {
        guard let entry = sources[source], let projection = entry.projection,
              let position = segmentIndices[source.segmentID] else {
            throw TranscriptMaterializationError.missingClauseSource
        }
        let segment = segments[position]
        var slices: [ClauseRowSlice] = []
        var priorityPending = false
        for part in partsBySource[source] ?? [] {
            guard let clause = clauses[part.reference] else { throw TranscriptMaterializationError.missingClauseSource }
            priorityPending = priorityPending || clause.isPriorityUnresolved
            slices.append(ClauseRowSlice(reference: part.reference, sourceRange: part.range,
                displayRanges: try projection.displayRanges(for: part.range),
                priority: clause.priority, needsRetry: clause.needsRetry))
        }
        slices.sort { $0.sourceRange.start < $1.sourceRange.start }
        var covered = 0
        var previousEnd = 0
        for slice in slices {
            guard slice.sourceRange.start >= previousEnd else {
                throw TranscriptMaterializationError.overlappingClauses(segmentID: source.segmentID)
            }
            previousEnd = slice.sourceRange.end
            covered += slice.sourceRange.end - slice.sourceRange.start
        }
        let state: TranscriptClauseState?
        if ASRRecognitionOutcome(text: entry.text) != .recognized {
            state = nil
        } else if cursor == nil {
            state = .boundaryPending
        } else if let boundary = boundaries[source], let assembly {
            if case .pending = boundary.state {
                state = .boundaryPending
            } else if try assembly.state(for: source) == .boundaryPending {
                state = .boundaryPending
            } else if covered < projection.sourceUTF16Length {
                state = .awaitingNextSegment
            } else {
                state = priorityPending ? .priorityPending : .classified
            }
        } else {
            state = .awaitingNextSegment
        }
        return MaterializedTranscriptSegment(segmentID: source.segmentID, source: source,
            startMilliseconds: milliseconds(segment.start), endMilliseconds: milliseconds(segment.end),
            text: entry.text, textProjection: projection, speakers: [],
            clauseState: state, clauseSlices: slices, isDiarized: false)
    }

    private func boundaryContext(at position: Int, state: ClauseBoundaryState) throws -> (emptySeparator: Bool, missingPredecessor: Bool) {
        if case .assessed(let assessment) = state {
            let next = position + 1
            if next == segments.count {
                guard assessment.nextHead == nil else { throw ClauseAssemblyError.unexpectedSuccessor }
            } else if let source = segments[next].source, let entry = sources[source] {
                if ASRRecognitionOutcome(text: entry.text) == .recognized {
                    guard let head = assessment.nextHead, head.source == source,
                          head.text.utf8.elementsEqual(String(entry.text.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit)).utf8) else {
                        throw ClauseAssemblyError.unexpectedSuccessor
                    }
                } else {
                    guard assessment.nextHead == nil else { throw ClauseAssemblyError.unexpectedSuccessor }
                }
            } else {
                throw ClauseAssemblyError.unexpectedSuccessor
            }
        }
        let priorIndex = insertionIndex(position, in: resultPositions)
        let empty = priorIndex > 0 && successorIsEmpty(at: resultPositions[priorIndex - 1] - 1)
        return (empty, position > 0 && segments[position - 1].source == nil)
    }

    private func validateChangedTimeline(at position: Int) throws {
        guard cursor != nil else { return }
        var affected: Set<Int> = [position]
        if position > 0 { affected.insert(position - 1) }
        let next = insertionIndex(position + 1, in: recognizedPositions)
        if next < recognizedPositions.count { affected.insert(recognizedPositions[next]) }
        for index in affected {
            guard let source = segments[index].source, let boundary = boundaries[source] else { continue }
            let context = try boundaryContext(at: index, state: boundary.state)
            guard context.emptySeparator == boundary.emptySeparator,
                  context.missingPredecessor == boundary.missingPredecessor else {
                throw ClauseAssemblyError.unexpectedSuccessor
            }
        }
    }

    private func successorIsEmpty(at position: Int) -> Bool {
        let next = position + 1
        guard next >= 0, next < segments.count, let source = segments[next].source, let entry = sources[source] else { return false }
        return ASRRecognitionOutcome(text: entry.text) != .recognized
    }

    private func insertionIndex(_ value: Int, in positions: [Int]) -> Int {
        var lower = 0
        var upper = positions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if positions[middle] < value { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func shiftPositions(from position: Int, by offset: Int) {
        // Appending a registered segment does not touch the historical indexes.
        if let last = resultPositions.last, last >= position {
            for index in insertionIndex(position, in: resultPositions)..<resultPositions.count { resultPositions[index] += offset }
        }
        if let last = recognizedPositions.last, last >= position {
            for index in insertionIndex(position, in: recognizedPositions)..<recognizedPositions.count { recognizedPositions[index] += offset }
        }
    }

    private func rowPrecedes(_ lhs: MaterializedTranscriptSegment, _ rhs: MaterializedTranscriptSegment) -> Bool {
        if lhs.startMilliseconds != rhs.startMilliseconds { return lhs.startMilliseconds < rhs.startMilliseconds }
        guard let left = segmentIndices[lhs.segmentID], let right = segmentIndices[rhs.segmentID] else { preconditionFailure("indexed rows have segments") }
        return segments[left].createdSeq < segments[right].createdSeq
    }

    private func milliseconds(_ frame: Int64) -> Int64 {
        Int64((Double(frame) * 1_000 / sampleRate).rounded(.towardZero))
    }
}
