import Foundation
import Testing
@testable import MacAmbientJevCore

private func ref(_ id: String, _ seq: UInt64) throws -> SegmentTextReference {
    try SegmentTextReference(segmentationRunID: "seg", segmentID: id, asrRunID: "asr", asrEventSeq: seq)
}

/// An assessment of `text` accepting the candidates at `accepted` (0-based) and continuing when `continues`.
private func assessed(
    _ source: SegmentTextReference, _ text: String, accepted: Set<Int> = [],
    next: (SegmentTextReference, String)?, continues: Bool = false
) throws -> ClauseAssemblyInput {
    let candidates = try ClauseBoundaryCandidate.candidates(in: text)
    var probabilities: [String: Double] = [:]
    for (index, candidate) in candidates.enumerated() { probabilities[candidate.id] = accepted.contains(index) ? 0.9 : 0.5 }
    let head = try next.map { try NextSegmentHead(source: $0.0, text: String($0.1.prefix(60))) }
    let decision: BoundaryDecisionSource = candidates.isEmpty && head == nil ? .terminalWithoutQuestions : .assessed
    let assessment = try ClauseBoundaryAssessment(
        source: source, candidates: candidates, probabilities: probabilities, nextHead: head,
        continuationProbability: head.map { _ in continues ? 0.51 : 0.5 },
        request: decision == .assessed ? DecisionRequestRecord(requestID: "r-\(source.segmentID)", metadata: testMetadata) : nil,
        sourceDecision: decision
    )
    return ClauseAssemblyInput(source: source, text: text, state: .assessed(assessment))
}

private func part(_ source: SegmentTextReference, _ start: Int, _ end: Int) throws -> ClauseSourcePart {
    try ClauseSourcePart(source: source, range: TextUTF16Range(start: start, end: end))
}

@Test
func clauseSpanningThreeSegmentsClosesAtTheFirstInternalBoundaryOfTheLast() throws {
    let a = try ref("a", 1), b = try ref("b", 2), c = try ref("c", 3)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")

    let first = try assembly.consume(assessed(a, "これは", next: (b, "コピーと"), continues: true))
    #expect(first.closed.isEmpty)
    #expect(try assembly.state(for: a) == .awaitingNextSegment)
    let second = try assembly.consume(assessed(b, "コピーと", next: (c, "いうか。次です"), continues: true))
    #expect(second.closed.isEmpty)
    #expect(try assembly.state(for: b) == .awaitingNextSegment)

    let third = try assembly.consume(assessed(c, "いうか。次です", accepted: [0], next: nil))
    #expect(third.closed.map(\.reference.clauseID) == ["c1_0", "c3_4"])
    #expect(third.closed[0].parts == [try part(a, 0, 3), try part(b, 0, 4), try part(c, 0, 4)])
    #expect(third.closed[0].termination == .internalBoundary(source: c, candidateID: "b0001"))
    #expect(third.closed[1].parts == [try part(c, 4, 7)])
    #expect(third.closed[1].termination == .streamEnd)
    #expect(third.affectedSources == [a, b, c])
    for source in [a, b, c] { #expect(try assembly.state(for: source) == .resolved) }
}

@Test
func weakCandidatesAndExactlyHalfDoNotSplitWhileAcceptedBoundariesCutRawRanges() throws {
    let a = try ref("a", 1)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    // Candidates: after "、" (rejected at 0.5), after "。" (accepted), after "？" (rejected at 0.5).
    let delta = try assembly.consume(assessed(a, "えー、今日は。そう？はい", accepted: [1], next: nil))
    #expect(delta.closed.map(\.parts) == [[try part(a, 0, 7)], [try part(a, 7, 12)]])
    #expect(!ClauseBoundaryPolicy.acceptsBoundary(0.5))
    #expect(ClauseBoundaryPolicy.acceptsBoundary(0.5000001))
}

@Test(arguments: ["前、弱。？！後。", "句読点なし", "か\u{3099}😀、後"])
func rejectedCandidatesPreserveTheEntireRawClauseUntilStreamEnd(_ text: String) throws {
    let source = try ref("raw", 1)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    let delta = try assembly.consume(assessed(source, text, next: nil))
    #expect(delta.closed.map(\.parts) == [[try part(source, 0, text.utf16.count)]])
    #expect(delta.closed.map(\.termination) == [.streamEnd])
    #expect(try assembly.state(for: source) == .resolved)
}

@Test
func trailingPunctuationCandidatesPreserveCharacterBoundariesAndUTF16Offsets() throws {
    #expect(try ClauseBoundaryCandidate.candidates(in: "本当？！").isEmpty)
    #expect(try ClauseBoundaryCandidate.candidates(in: "、。？！?!").isEmpty)

    let mixed = try ClauseBoundaryCandidate.candidates(in: "a。!b？！")
    #expect(mixed.map(\.id) == ["b0001", "b0002"])
    #expect(mixed.map(\.offsetUTF16) == [2, 3])

    let emoji = try ClauseBoundaryCandidate.candidates(in: "😀a。!b？！")
    #expect(emoji.map(\.id) == ["b0001", "b0002"])
    #expect(emoji.map(\.offsetUTF16) == [4, 5])

    let combining = try ClauseBoundaryCandidate.candidates(in: "か\u{3099}😀、後。")
    #expect(combining.map(\.id) == ["b0001"])
    #expect(combining.map(\.offsetUTF16) == [5])

    let whitespace = try ClauseBoundaryCandidate.candidates(in: "a! ")
    #expect(whitespace.map(\.id) == ["b0001"])
    #expect(whitespace.map(\.offsetUTF16) == [2])
}

@Test
func consecutiveAcceptedPunctuationNeverCreatesEmptyClausesOrAnEndCandidate() throws {
    let source = try ref("raw", 1)
    let text = "前？！後。"
    #expect(try ClauseBoundaryCandidate.candidates(in: text).map(\.offsetUTF16) == [2, 3])
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    let delta = try assembly.consume(assessed(source, text, accepted: [0, 1], next: nil))
    #expect(delta.closed.map(\.parts) == [
        [try part(source, 0, 2)], [try part(source, 2, 3)], [try part(source, 3, 5)]
    ])
}

@Test
func continuationAfterAFinalPeriodJoinsTheNextSegmentAndNoClosesIt() throws {
    let a = try ref("a", 1), b = try ref("b", 2), c = try ref("c", 3)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    // The period at the raw end is not a candidate; only the continuation question decides.
    _ = try assembly.consume(assessed(a, "これはコピーと。", next: (b, "いうか"), continues: true))
    let joined = try assembly.consume(assessed(b, "いうか", next: (c, "次"), continues: false))
    #expect(joined.closed.map(\.parts) == [[try part(a, 0, 8), try part(b, 0, 3)]])
    #expect(joined.closed.map(\.termination) == [.notContinued(source: b)])
    let last = try assembly.consume(assessed(c, "次", next: nil))
    #expect(last.closed.map(\.termination) == [.streamEnd])
}

@Test
func pendingResultLeavesNeighboursUnresolvedButKeepsIndependentClauses() throws {
    let a = try ref("a", 1), b = try ref("b", 2), c = try ref("c", 3)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    let closedBefore = try assembly.consume(assessed(a, "前。続く", accepted: [0], next: (b, "途中"), continues: true))
    #expect(closedBefore.closed.map(\.parts) == [[try part(a, 0, 2)]])
    _ = try assembly.consume(ClauseAssemblyInput(source: b, text: "途中", state: .pending(reason: .requestFailed, message: "x")))
    let after = try assembly.consume(assessed(c, "頭で。独立。", accepted: [0], next: nil))
    // The head of c up to its first boundary is not assumed to start a clause after a pending result.
    #expect(after.closed.map(\.parts) == [[try part(c, 3, 6)]])
    #expect(try assembly.state(for: a) == .boundaryPending)
    #expect(try assembly.state(for: b) == .boundaryPending)
    #expect(try assembly.state(for: c) == .boundaryPending)
    #expect(try assembly.finish().closed.isEmpty)
}

@Test
func finishClosesOnlyAnAssessedOpenTailAndIsIdempotent() throws {
    let a = try ref("a", 1), b = try ref("b", 2)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    _ = try assembly.consume(assessed(a, "続く", next: (b, "次"), continues: true))
    let finished = try assembly.finish()
    #expect(finished.closed.map(\.parts) == [[try part(a, 0, 2)]])
    #expect(finished.closed.map(\.termination) == [.streamEnd])
    #expect(try assembly.finish() == ClauseAssemblyDelta(closed: [], affectedSources: []))
    #expect(throws: ClauseAssemblyError.finished) {
        try assembly.consume(assessed(b, "次", next: nil))
    }
}

@Test
func assemblyRejectsInputsThatDoNotMatchTheTextOrOrder() throws {
    let a = try ref("a", 2), b = try ref("b", 3), early = try ref("early", 1)
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    _ = try assembly.consume(assessed(a, "一つ", next: (b, "二つ"), continues: true))
    #expect(throws: ClauseAssemblyError.outOfOrder) {
        try assembly.consume(assessed(early, "前", next: nil))
    }
    #expect(throws: ClauseAssemblyError.unexpectedSuccessor) {
        try assembly.consume(assessed(b, "違う本文", next: nil))
    }
    var other = ClauseBoundaryAssembly(boundaryRunID: "boundary")
    let wrongText = try assessed(a, "一つ。二つ", accepted: [0], next: nil)
    #expect(throws: ClauseAssemblyError.candidateMismatch) {
        try other.consume(ClauseAssemblyInput(source: a, text: "一つ二つ", state: wrongText.state))
    }
    #expect(throws: ClauseAssemblyError.emptyText) {
        try other.consume(ClauseAssemblyInput(source: a, text: " ", state: .pending(reason: .unconfigured, message: "")))
    }
    #expect(throws: ClauseAssemblyError.unknownSource) { try other.state(for: b) }
}

@Test
func clauseRecordsRejectInconsistentPayloads() throws {
    let a = try ref("a", 4)
    #expect(throws: ClauseRecordError.invalidClauseUnit) {
        try ClauseUnit(reference: ClauseReference(boundaryRunID: "b", clauseID: "c4_1"),
                       parts: [part(a, 0, 2)], termination: .streamEnd)
    }
    let low = try ContentPriorityDecision(priority: .lowPriority, confidence: 0.89, probabilities: ["PRIMARY": 0.055, "LOW_PRIORITY": 0.945])
    let reference = try ClauseReference(boundaryRunID: "b", clauseID: "c4_0")
    // Below 0.90 the actual decision stays recorded but the visible priority is PRIMARY.
    #expect(throws: ClauseRecordError.invalidPriorityAssignment) {
        try ClausePriorityAssignment(reference: reference, priority: .lowPriority, needsRetry: false,
                                     decision: .classified(requestID: "r", answerKey: "u0001", response: low))
    }
    #expect(throws: ClauseRecordError.invalidPriorityAssignment) {
        try ClausePriorityAssignment(reference: reference, priority: .primary, needsRetry: true,
                                     decision: .retryPending(reason: .requestFailed, message: "x"))
    }
    let classified = try ClausePriorityAssignment(reference: reference, priority: .primary, needsRetry: false,
                                                  decision: .classified(requestID: "r", answerKey: "u0001", response: low))
    #expect(throws: ClauseRecordError.invalidPriorityEvent) {
        try ContentPriorityAssignedPayload(assignments: [classified], request: nil)
    }
    #expect(ExactClauseTextKey(text: "が") != ExactClauseTextKey(text: "か\u{3099}"))
    #expect(ExactClauseTextKey(text: "が") == ExactClauseTextKey(text: "が"))
}
