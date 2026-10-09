import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private let incrementalSegmentationRun = "seg_incremental"
private let incrementalASRRun = "asr_incremental"
private let incrementalBoundaryRun = "boundary_incremental"
private let incrementalPriorityRun = "priority_incremental"

private let incrementalRuns = ActiveRuns(segmentation: incrementalSegmentationRun, asr: incrementalASRRun,
    clauseBoundary: incrementalBoundaryRun, contentPriority: incrementalPriorityRun)

func incrementalAssessment(source: SegmentTextReference, text: String,
                           next: (SegmentTextReference, String)?, continues: Bool = false,
                           acceptBoundaries: Bool = true) throws -> ClauseBoundaryAssessment {
    let candidates = try ClauseBoundaryCandidate.candidates(in: text)
    let asks = !candidates.isEmpty || next != nil
    return try ClauseBoundaryAssessment(source: source, candidates: candidates,
        probabilities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, acceptBoundaries ? 0.95 : 0.05) }),
        nextHead: try next.map { try NextSegmentHead(source: $0.0, text: String($0.1.prefix(ClauseBoundaryPolicy.nextHeadCharacterLimit))) },
        continuationProbability: next.map { _ in continues ? 0.95 : 0.05 },
        request: asks ? JevRequestRecord(requestID: "boundary_\(source.asrEventSeq)",
            metadata: JevResponseMetadata(model: "synthetic", inputTokens: 1, outputTokens: nil)) : nil,
        sourceDecision: asks ? .assessed : .terminalWithoutQuestions)
}

private func incrementalCoreFixture(_ texts: [String?]) throws -> (
    materializer: IncrementalTranscriptMaterializer, events: [TranscriptEvent], sources: [SegmentTextReference?]
) {
    let materializer = IncrementalTranscriptMaterializer(sampleRate: 16_000,
        segmentationRunID: incrementalSegmentationRun, asrRunID: incrementalASRRun,
        clauseBoundaryRunID: incrementalBoundaryRun)
    var events: [TranscriptEvent] = []
    var sources: [SegmentTextReference?] = []
    for index in texts.indices {
        let event = TranscriptEvent.segmentCreated(seq: UInt64(index + 1), segmentationRunID: incrementalSegmentationRun,
            segmentID: "segment_\(index)", startFrame: Int64(index * 4), endFrame: Int64(index * 4 + 4))
        try materializer.appendSourceEvent(event)
        events.append(event)
    }
    for (index, text) in texts.enumerated() {
        guard let text else { sources.append(nil); continue }
        let event = TranscriptEvent.asrCompleted(seq: UInt64(texts.count + index + 1), runID: incrementalASRRun,
            segmentationRunID: incrementalSegmentationRun, segmentID: "segment_\(index)", text: text, detectedLanguage: "ja")
        try materializer.appendSourceEvent(event)
        events.append(event)
        sources.append(try event.asrSource())
        #expect(materializer.materializedSegments == (try TranscriptMaterializer(sampleRate: 16_000)
            .materialize(events: events, activeRuns: incrementalRuns)))
    }
    return (materializer, events, sources)
}

private func expectIncrementalParity(_ materializer: IncrementalTranscriptMaterializer, events: [TranscriptEvent]) throws {
    let canonical = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: incrementalRuns)
    let actual = materializer.materializedSegments
    #expect(actual == canonical)
    #expect(try LiveTranscriptProjection().rows(for: actual) == LiveTranscriptProjection().rows(for: canonical))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(actual) == encoder.encode(canonical))
}

@Test
func incrementalClausesMatchRebuildAcrossContinuationPendingAndStreamEnd() throws {
    let texts = ["えー、第一", "続き。次", "未判定", "末尾", "", "別の流れ"]
    let fixture = try incrementalCoreFixture(texts.map(Optional.some))
    var events = fixture.events
    var assembly = ClauseBoundaryAssembly(boundaryRunID: incrementalBoundaryRun)
    let heldSnapshot = fixture.materializer.materializedSegments
    for index in texts.indices where !texts[index].isEmpty {
        let source = try #require(fixture.sources[index])
        if index == 5 { _ = try assembly.endTextStream() }
        let next: (SegmentTextReference, String)? = index + 1 < texts.count && !texts[index + 1].isEmpty
            ? (try #require(fixture.sources[index + 1]), texts[index + 1]) : nil
        let state: ClauseBoundaryState = index == 2
            ? .pending(reason: .requestFailed, message: "synthetic boundary pending")
            : .assessed(try incrementalAssessment(source: source, text: texts[index], next: next, continues: index < 3))
        let kind: TranscriptEventKind
        switch state {
        case .assessed(let assessment): kind = .clauseBoundaryAssessed(assessment)
        case .pending(let reason, let message): kind = .clauseBoundaryPending(ClauseBoundaryPendingPayload(source: source, reason: reason, message: message))
        }
        var batch = [TranscriptEvent.clause(seq: UInt64(100 + index * 10), runID: incrementalBoundaryRun, kind: kind)]
        let delta = try assembly.consume(ClauseAssemblyInput(source: source, text: texts[index], state: state))
        for (offset, unit) in delta.closed.enumerated() {
            batch.append(.clause(seq: UInt64(101 + index * 10 + offset), runID: incrementalBoundaryRun, kind: .clauseClosed(unit)))
        }
        if index == 3 { _ = try assembly.endTextStream() }
        // Lists may arrive in reverse order; durable sequence numbers determine replay order.
        try fixture.materializer.applyClauseEvents(Array(batch.reversed()))
        events.append(contentsOf: batch.reversed())
        try expectIncrementalParity(fixture.materializer, events: events)
        if let unit = delta.closed.first, !ClauseTextComposer.isBlank(try ClauseTextComposer().textForTest(unit: unit, texts: texts, sources: fixture.sources)) {
            let payload: ContentPriorityAssignedPayload
            if index == 1 {
                let response = try ContentPriorityDecision(priority: .lowPriority, confidence: 0.95,
                    probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975])
                payload = try ContentPriorityAssignedPayload(assignments: [
                    ClausePriorityAssignment(reference: unit.reference, priority: .lowPriority, needsRetry: false,
                        decision: .classified(requestID: "priority_1", answerKey: "u0001", response: response))
                ], request: JevRequestRecord(requestID: "priority_1",
                    metadata: JevResponseMetadata(model: "synthetic", inputTokens: 1, outputTokens: nil)))
            } else {
                payload = try ClausePriorityBatch.pending(references: [unit.reference], reason: .requestFailed, message: "synthetic priority pending")
            }
            let priority = TranscriptEvent.clause(seq: UInt64(109 + index * 10), runID: incrementalPriorityRun, kind: .contentPriorityAssigned(payload))
            try fixture.materializer.applyClauseEvents([priority])
            events.append(priority)
            try expectIncrementalParity(fixture.materializer, events: events)
        }
    }
    #expect(heldSnapshot.allSatisfy { $0.clauseSlices.isEmpty })
    #expect(fixture.materializer.materializedSegments[2].clauseState == .boundaryPending)
    #expect(fixture.materializer.materializedSegments.last?.clauseState == .priorityPending)
}

private extension ClauseTextComposer {
    func textForTest(unit: ClauseUnit, texts: [String], sources: [SegmentTextReference?]) throws -> String {
        var composer = self
        return try composer.text(of: unit.parts) { source in
            let index = try #require(sources.firstIndex(of: source))
            return texts[index]
        }
    }
}

@Test
func incrementalLongTailClosesEverySourceWithoutTruncation() throws {
    let count = 257
    let fixture = try incrementalCoreFixture(Array(repeating: Optional("続く"), count: count))
    var events = fixture.events
    var assembly = ClauseBoundaryAssembly(boundaryRunID: incrementalBoundaryRun)
    var finalClause: ClauseUnit?
    for index in 0..<count {
        let source = try #require(fixture.sources[index])
        let next: (SegmentTextReference, String)? = index + 1 < count ? (try #require(fixture.sources[index + 1]), "続く") : nil
        let assessment = try incrementalAssessment(source: source, text: "続く", next: next, continues: true)
        var batch = [TranscriptEvent.clause(seq: UInt64(1_000 + index * 2), runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(assessment))]
        let delta = try assembly.consume(ClauseAssemblyInput(source: source, text: "続く", state: .assessed(assessment)))
        if let unit = delta.closed.first {
            finalClause = unit
            batch.append(.clause(seq: UInt64(1_001 + index * 2), runID: incrementalBoundaryRun, kind: .clauseClosed(unit)))
        }
        try fixture.materializer.applyClauseEvents(batch)
        events.append(contentsOf: batch)
        try expectIncrementalParity(fixture.materializer, events: events)
    }
    let unit = try #require(finalClause)
    #expect(unit.parts.map(\.source) == fixture.sources.compactMap { $0 })
    #expect(fixture.materializer.materializedSegments.allSatisfy { $0.clauseState == .priorityPending && $0.clauseSlices.first?.reference == unit.reference })
    let pending = try ClausePriorityBatch.pending(references: [unit.reference], reason: .requestFailed, message: "synthetic priority pending")
    let event = TranscriptEvent.clause(seq: 2_000, runID: incrementalPriorityRun, kind: .contentPriorityAssigned(pending))
    try fixture.materializer.applyClauseEvents([event])
    events.append(event)
    try expectIncrementalParity(fixture.materializer, events: events)
}

@Test
func incrementalFailedASRGapMatchesCanonicalPendingHead() throws {
    let fixture = try incrementalCoreFixture([nil, "未確定。確定", "", nil, "後続"])
    var events = fixture.events
    var assembly = ClauseBoundaryAssembly(boundaryRunID: incrementalBoundaryRun)
    for index in [1, 4] {
        if index == 4 { _ = try assembly.endTextStream() }
        _ = try assembly.beginAfterASRGap()
        let text = index == 1 ? "未確定。確定" : "後続"
        let source = try #require(fixture.sources[index])
        let assessment = try incrementalAssessment(source: source, text: text, next: nil)
        let delta = try assembly.consume(ClauseAssemblyInput(source: source, text: text, state: .assessed(assessment)))
        var batch = [TranscriptEvent.clause(seq: UInt64(100 + index * 10), runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(assessment))]
        batch.append(contentsOf: delta.closed.enumerated().map { .clause(seq: UInt64(101 + index * 10 + $0.offset), runID: incrementalBoundaryRun, kind: .clauseClosed($0.element)) })
        if index == 1 { _ = try assembly.endTextStream() }
        try fixture.materializer.applyClauseEvents(batch)
        events.append(contentsOf: batch)
        try expectIncrementalParity(fixture.materializer, events: events)
    }
}

@Test
func incrementalInvalidBatchRollsBackAssemblyClausesAndPriorityIndexes() throws {
    let fixture = try incrementalCoreFixture(["第一", "第二"])
    let first = try #require(fixture.sources[0])
    let second = try #require(fixture.sources[1])
    let assessment = try incrementalAssessment(source: first, text: "第一", next: (second, "第二"))
    var assembly = ClauseBoundaryAssembly(boundaryRunID: incrementalBoundaryRun)
    let delta = try assembly.consume(ClauseAssemblyInput(source: first, text: "第一", state: .assessed(assessment)))
    let unit = try #require(delta.closed.first)
    let good = [TranscriptEvent.clause(seq: 100, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(assessment)),
                .clause(seq: 101, runID: incrementalBoundaryRun, kind: .clauseClosed(unit))]
    let unknown = try ClauseReference(boundaryRunID: incrementalBoundaryRun, clauseID: "c999_0")
    let invalidPriority = try ClausePriorityBatch.pending(references: [unknown], reason: .requestFailed, message: "unknown clause")
    let before = fixture.materializer.materializedSegments
    #expect(throws: TranscriptMaterializationError.self) {
        try fixture.materializer.applyClauseEvents(good + [.clause(seq: 102, runID: incrementalPriorityRun, kind: .contentPriorityAssigned(invalidPriority))])
    }
    #expect(fixture.materializer.materializedSegments == before)
    try fixture.materializer.applyClauseEvents(good)
    var events = fixture.events + good
    try expectIncrementalParity(fixture.materializer, events: events)
    let pending = try ClausePriorityBatch.pending(references: [unit.reference], reason: .requestFailed, message: "pending")
    let assignment = TranscriptEvent.clause(seq: 103, runID: incrementalPriorityRun, kind: .contentPriorityAssigned(pending))
    #expect(throws: TranscriptMaterializationError.self) { try fixture.materializer.applyClauseEvents([assignment, assignment]) }
    try fixture.materializer.applyClauseEvents([assignment])
    events.append(assignment)
    try expectIncrementalParity(fixture.materializer, events: events)
    #expect(throws: (any Error).self) { try fixture.materializer.applyClauseEvents([good[0]]) }
    try expectIncrementalParity(fixture.materializer, events: events)
    let reordered = try incrementalAssessment(source: second, text: "第二", next: nil)
    #expect(throws: (any Error).self) {
        try fixture.materializer.applyClauseEvents([.clause(seq: 99, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(reordered))])
    }
    let wrongCandidates = try incrementalAssessment(source: second, text: "第二。追加", next: nil)
    #expect(throws: ClauseAssemblyError.self) {
        try fixture.materializer.applyClauseEvents([.clause(seq: 104, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(wrongCandidates))])
    }
    let validEnd = TranscriptEvent.clause(seq: 104, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(reordered))
    try fixture.materializer.applyClauseEvents([validEnd])
    events.append(validEnd)
    try expectIncrementalParity(fixture.materializer, events: events)
}

@Test
func incrementalASRAfterClauseUpdatePreservesClassifiedHistory() throws {
    let fixture = try incrementalCoreFixture(["第一", "第二"])
    let first = try #require(fixture.sources[0])
    let second = try #require(fixture.sources[1])
    let assessment = try incrementalAssessment(source: first, text: "第一", next: (second, "第二"))
    var assembly = ClauseBoundaryAssembly(boundaryRunID: incrementalBoundaryRun)
    let delta = try assembly.consume(ClauseAssemblyInput(source: first, text: "第一", state: .assessed(assessment)))
    let unit = try #require(delta.closed.first)
    let response = try ContentPriorityDecision(priority: .lowPriority, confidence: 0.95,
        probabilities: ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975])
    let payload = try ContentPriorityAssignedPayload(assignments: [
        ClausePriorityAssignment(reference: unit.reference, priority: .lowPriority, needsRetry: false,
            decision: .classified(requestID: "priority_1", answerKey: "u0001", response: response))
    ], request: JevRequestRecord(requestID: "priority_1",
        metadata: JevResponseMetadata(model: "synthetic", inputTokens: 1, outputTokens: nil)))
    let batch = [
        TranscriptEvent.clause(seq: 100, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(assessment)),
        .clause(seq: 101, runID: incrementalBoundaryRun, kind: .clauseClosed(unit)),
        .clause(seq: 102, runID: incrementalPriorityRun, kind: .contentPriorityAssigned(payload)),
    ]
    try fixture.materializer.applyClauseEvents(batch)
    var events = fixture.events + batch
    let held = fixture.materializer.materializedSegments
    let created = TranscriptEvent.segmentCreated(seq: 5, segmentationRunID: incrementalSegmentationRun,
        segmentID: "segment_2", startFrame: 8, endFrame: 12)
    let completed = TranscriptEvent.asrCompleted(seq: 6, runID: incrementalASRRun,
        segmentationRunID: incrementalSegmentationRun, segmentID: "segment_2", text: "第三", detectedLanguage: "ja")
    for event in [created, completed] {
        try fixture.materializer.appendSourceEvent(event)
        events.append(event)
        try expectIncrementalParity(fixture.materializer, events: events)
    }
    #expect(fixture.materializer.materializedSegments[0] == held[0])
    #expect(held.map(\.text) == ["第一", "第二"])
    #expect(fixture.materializer.materializedSegments.map(\.clauseState) == [.classified, .awaitingNextSegment, .awaitingNextSegment])
}

actor IncrementalFixtureASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "synthetic-incremental", model: nil, version: "1", configuration: [:])
    private let texts: [String]
    private var index = 0
    init(texts: [String]) { self.texts = texts }
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        defer { index += 1 }
        return ASRResult(text: texts[index], detectedLanguage: "ja")
    }
}

func incrementalLiveFixture(count: Int) async throws -> (root: URL, session: LiveASRSession) {
    let root = FileManager.default.temporaryDirectory.appending(path: "clause-incremental-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audio = try DurableAudioWriter(directory: root, chunkDurationSeconds: 1, sessionURL: root)
    try await audio.append(samples: Array(repeating: Float(0.1), count: 16_000))
    let checkpoint = await audio.committedSnapshot()
    let session = LiveASRSession(sessionID: UUID(), sessionURL: root,
        segmentationRunID: incrementalSegmentationRun, asrRunID: incrementalASRRun, processingDirectory: root,
        writer: try SessionWriter(sessionURL: root), asr: IncrementalFixtureASR(texts: Array(repeating: "合成の発話", count: count)),
        sampleRate: checkpoint.sampleRate, clauseBoundaryRunID: incrementalBoundaryRun, contentPriorityRunID: incrementalPriorityRun)
    let segments = (0..<count).map { SegmentReference(segmentationRunID: incrementalSegmentationRun,
        segmentID: "segment_\($0)", startFrame: Int64($0 * 4), endFrame: Int64($0 * 4 + 4)) }
    _ = try await session.process(segments: segments, checkpoint: checkpoint)
    return (root, session)
}

@Test
func liveIncrementalForeignAndMalformedEventsNeverPublishPartialBatch() async throws {
    let fixture = try await incrementalLiveFixture(count: 3)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = await fixture.session.snapshot()
    let rows = before.progress.materializedSegments
    let assessment = try incrementalAssessment(source: rows[0].source, text: rows[0].text,
        next: (rows[1].source, rows[1].text))
    let event = TranscriptEvent.clause(seq: 100, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(assessment))
    let foreign = TranscriptEvent.clause(seq: 101, runID: "foreign-boundary", kind: .clauseBoundaryAssessed(assessment))
    await #expect(throws: LiveASRSessionError.self) { try await fixture.session.applyClauseEvents([event, foreign]) }
    #expect(await fixture.session.snapshot() == before)
    let wrongSuccessor = try incrementalAssessment(source: rows[1].source, text: rows[1].text, next: nil)
    await #expect(throws: ClauseAssemblyError.self) {
        try await fixture.session.applyClauseEvents([event, .clause(seq: 101, runID: incrementalBoundaryRun, kind: .clauseBoundaryAssessed(wrongSuccessor))])
    }
    #expect(await fixture.session.snapshot() == before)
    let after = try await fixture.session.applyClauseEvents([event])
    let canonical = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: after.events, activeRuns: after.activeRuns)
    #expect(after.progress.materializedSegments == canonical)
    #expect(try LiveTranscriptProjection().rows(for: after.progress.materializedSegments) == LiveTranscriptProjection().rows(for: canonical))
}
