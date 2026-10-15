import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func eventLogTranscriptReaderReconstructsOnlyActiveRuns() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)

    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        sourceStartFrame: 0,
        sourceEndFrame: 1_000,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr-stale",
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        payload: ASRCompletedEventPayload(
            text: "古い結果",
            detectedLanguage: "ja",
            provenance: RunProvenance(engine: "test", model: "test", version: "test", configuration: [:])
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr-active",
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        payload: ASRCompletedEventPayload(
            text: "現在の結果",
            detectedLanguage: "ja",
            provenance: RunProvenance(engine: "test", model: "test", version: "test", configuration: [:])
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "speaker.span",
        sessionID: sessionID,
        processingRunID: "diar-active",
        sourceStartFrame: 0,
        sourceEndFrame: 1_000,
        payload: SpeakerSpan(
            speakerID: "speaker-1",
            startFrame: 0,
            endFrame: 1_000,
            confidence: 0.9
        )
    ))
    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let activeRuns = ActiveRuns(
        segmentation: "seg-active",
        asr: "asr-active",
        diarization: "diar-active"
    )
    let events = try EventLogTranscriptReader().events(
        lines: recovered.lines,
        activeRuns: activeRuns
    )

    let materialized = try TranscriptMaterializer(
        sampleRate: 1_000
    ).materialize(
        events: events,
        activeRuns: activeRuns
    )

    #expect(materialized.count == 1)
    #expect(materialized[0].text == "現在の結果")
    #expect(materialized[0].speakers.first?.id == "speaker-1")
    #expect(materialized[0].clauseState == .boundaryPending)
}

private func eventLine(_ object: [String: Any]) throws -> Data {
    var envelope = object
    envelope["schema_version"] = EventLogSchema.version
    envelope["session_id"] = "0123ABCD-0000-0000-0000-000000000001"
    return try JSONSerialization.data(withJSONObject: envelope)
}

@Test
func eventLogTranscriptReaderRejectsAMalformedActiveRunEvent() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "segment.created",
            "segmentation_run_id": "seg", "segment_id": "s1",
            "source_start_frame": 0, "source_end_frame": 100,
        ]),
        try eventLine([
            "event_seq": 2, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["engine": "test", "model": "test", "outcome": "recognized"],
        ]),
    ]

    #expect(throws: EventLogTranscriptReaderError.malformedEvent(eventSeq: 2, eventType: "asr.completed")) {
        _ = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        )
    }
}

@Test
func eventLogTranscriptReaderSkipsOtherRunsAndUnknownEventTypes() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "segment.created",
            "segmentation_run_id": "seg", "segment_id": "s1",
            "source_start_frame": 0, "source_end_frame": 100,
        ]),
        try eventLine([
            "event_seq": 2, "event_type": "asr.completed",
            "processing_run_id": "asr-other", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["broken": true],
        ]),
        try eventLine(["event_seq": 3, "event_type": "future.event", "payload": 42]),
        try eventLine([
            "event_seq": 4, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["text": "発話", "engine": "test", "model": "test", "outcome": "recognized"],
        ]),
    ]

    let events = try EventLogTranscriptReader().events(
        lines: lines,
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )

    #expect(events.map(\.eventSeq) == [1, 4])
    #expect(events.last?.kind == .asrCompleted(ASRResult(text: "発話", detectedLanguage: nil)))
}

@Test
func eventLogTranscriptReaderRejectsAnOutcomeThatContradictsTheText() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["text": "発話", "engine": "test", "model": "test", "outcome": "empty"],
        ]),
    ]

    #expect(throws: EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: 1)) {
        _ = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        )
    }
}

@Test
func eventLogReadersRejectALineWithoutEnvelope() throws {
    let lines = [try eventLine(["event_type": "segment.created"])]

    #expect(throws: EventLogTranscriptReaderError.unreadableLine(index: 0)) {
        _ = try EventLogTranscriptReader().events(lines: lines, activeRuns: ActiveRuns(segmentation: "seg"))
    }
    #expect(throws: EventLogTranscriptReaderError.unreadableLine(index: 0)) {
        _ = try DecisionRetryAnalyzer().retryTargets(lines: lines, metadata: ProcessingMetadata(
            finalizationAttempt: nil, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"),
            pendingClauseBoundarySegments: [], pendingContentPriorityClauses: []
        ))
    }
}

@Test(arguments: [1, 2, 4, nil] as [Int?])
func readersAndWriterRejectAnyOtherEnvelopeVersion(version: Int?) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var object: [String: Any] = [
        "event_seq": 1, "event_type": "segment.created", "segmentation_run_id": "seg", "segment_id": "s1",
        "source_start_frame": 0, "source_end_frame": 100,
    ]
    object["schema_version"] = version
    let line = try JSONSerialization.data(withJSONObject: object)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try (line + Data([0x0A])).write(to: root.appending(path: "events.jsonl"))

    #expect(throws: EventLogSchemaError.unsupportedSchemaVersion(index: 0)) {
        _ = try EventLogTranscriptReader().events(lines: [line], activeRuns: ActiveRuns(segmentation: "seg"))
    }
    #expect(throws: EventLogSchemaError.unsupportedSchemaVersion(index: 0)) {
        _ = try EventLogTranscriptReader().liveContentPriorityDecisions(from: line + Data([0x0A]), modelRevision: testDecisionIdentity.modelRevision)
    }
    #expect(throws: EventLogSchemaError.unsupportedSchemaVersion(index: 0)) {
        _ = try SessionWriter(sessionURL: root)
    }
}

/// Writes a live ASR run and a live decision run where every segment is one clause that does not
/// continue, with the given priority results in order. A nil result is a pending assignment.
func writeLiveRun(
    root: URL, sessionID: UUID, texts: [String], fillerRangesByIndex: [Int: [TextUTF16Range]],
    results: [(index: Int, priority: ContentPriority?)], complete: Bool
) async throws {
    let writer = try SessionWriter(sessionURL: root)
    let provenance = RunProvenance(engine: "test", model: nil, version: "1", configuration: [:])
    var sources: [SegmentTextReference] = []
    for (index, text) in texts.enumerated() {
        let id = "live\(index)"
        try await writer.append(EventDraft(eventType: "segment.created", sessionID: sessionID, segmentationRunID: "live_seg",
                                           segmentID: id, sourceStartFrame: Int64(index * 100), sourceEndFrame: Int64(index * 100 + 90),
                                           payload: EmptyPayload()))
        let asr = try await writer.append(EventDraft(eventType: "asr.completed", sessionID: sessionID, processingRunID: "live_asr",
                                                     segmentationRunID: "live_seg", segmentID: id,
                                                     payload: ASRCompletedEventPayload(text: text, detectedLanguage: nil, provenance: provenance)))
        sources.append(try SegmentTextReference(segmentationRunID: "live_seg", segmentID: id, asrRunID: "live_asr", asrEventSeq: asr.eventSeq))
    }
    try await writer.append(EventDraft(eventType: "processing.run.started", sessionID: sessionID, processingRunID: "boundary_live",
                                       payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: DecisionRunProvenance.boundary(mode: "live", identity: testDecisionIdentity))))
    var assembly = ClauseBoundaryAssembly(boundaryRunID: "boundary_live")
    var units: [ClauseUnit] = []
    for (index, source) in sources.enumerated() {
        let next = index + 1 < texts.count ? try NextSegmentHead(source: sources[index + 1], text: texts[index + 1]) : nil
        let candidates = try ClauseBoundaryCandidate.candidates(in: texts[index])
        let assessment = try ClauseBoundaryAssessment(
            source: source, candidates: candidates,
            probabilities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.1) }),
            nextHead: next, continuationProbability: next.map { _ in 0.1 }, fillerRanges: fillerRangesByIndex[index] ?? [],
            request: DecisionRequestRecord(requestID: "b\(index)", inputTokens: testInputTokens),
            sourceDecision: .assessed
        )
        try await writer.append(EventDraft(eventType: ClauseEventType.boundaryAssessed, sessionID: sessionID,
                                           processingRunID: "boundary_live", payload: assessment))
        for unit in try assembly.consume(ClauseAssemblyInput(source: source, text: texts[index], state: .assessed(assessment))).closed {
            try await writer.append(EventDraft(eventType: ClauseEventType.clauseClosed, sessionID: sessionID,
                                               processingRunID: "boundary_live", payload: unit))
            units.append(unit)
        }
    }
    try await writer.append(EventDraft(eventType: "processing.run.started", sessionID: sessionID, processingRunID: "priority_live",
                                       payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(mode: "live", identity: testDecisionIdentity))))
    for (order, result) in results.enumerated() {
        let reference = units[result.index].reference
        let payload: ContentPriorityAssignedPayload
        if let priority = result.priority {
            let decision = try ContentPriorityDecision(priority: priority, confidence: 0.95,
                                                       probabilities: priority == .primary ? ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025] : ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975])
            payload = try ContentPriorityAssignedPayload(assignments: [ClausePriorityAssignment(
                reference: reference, priority: priority, needsRetry: false,
                decision: .classified(requestID: "p\(order)", answerKey: "u0001", response: decision)
            )], request: DecisionRequestRecord(requestID: "p\(order)", inputTokens: testInputTokens))
        } else {
            payload = try ClausePriorityBatch.pending(references: [reference], reason: .requestFailed, message: "x")
        }
        try await writer.append(EventDraft(eventType: ClauseEventType.priorityAssigned, sessionID: sessionID,
                                           processingRunID: "priority_live", payload: payload))
    }
    if complete {
        for (runID, stage) in [("boundary_live", ProcessingStage.clauseBoundary), ("priority_live", .contentPriority)] {
            let pendingCount = results.filter { $0.priority == nil }.count
            let completedCount = stage == .clauseBoundary ? sources.count : results.count - pendingCount
            try await writer.append(EventDraft(eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
                                               payload: ProcessingRunCompletedPayload(
                                                stage: stage, succeeded: true, completedCount: completedCount,
                                                failedCount: stage == .clauseBoundary ? 0 : pendingCount
                                               )))
        }
    }
}

@Test(arguments: [false, true])
func liveReuseKeepsTheLatestClassifiedTextAndIgnoresLaterPendingResults(complete: Bool) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeLiveRun(
        root: root, sessionID: UUID(), texts: ["えー、同じ本文", "同じ本文", "同じ本文", "別の本文"],
        fillerRangesByIndex: [0: [try TextUTF16Range(start: 0, end: 2)]],
        results: [(0, .lowPriority), (1, .primary), (2, nil), (3, nil)], complete: complete
    )

    let reused = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: try Data(contentsOf: root.appending(path: "events.jsonl")),
        modelRevision: testDecisionIdentity.modelRevision
    )

    #expect(Array(reused.keys) == [ExactClauseTextKey(text: "同じ本文")])
    let decision = try requireValue(reused[ExactClauseTextKey(text: "同じ本文")])
    #expect(decision.visiblePriority == .primary)
    #expect(decision.sourcePriorityRunID == "priority_live")
    #expect(decision.sourceClause.boundaryRunID == "boundary_live")
}

@Test
func liveReuseSkipsRunsOfAnotherTaggerRevision() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeLiveRun(root: root, sessionID: UUID(), texts: ["同じ本文"], fillerRangesByIndex: [:], results: [(0, .lowPriority)], complete: true)
    let log = try Data(contentsOf: root.appending(path: "events.jsonl"))

    let current = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: log, modelRevision: testDecisionIdentity.modelRevision
    )
    let replaced = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: log, modelRevision: String(repeating: "f", count: 64)
    )

    #expect(current[ExactClauseTextKey(text: "同じ本文")]?.visiblePriority == .lowPriority)
    #expect(replaced.isEmpty)
}

@Test
func liveReuseRejectsAClauseThatTheSavedBoundariesDoNotProduce() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(root: root, sessionID: sessionID, texts: ["一つ"], fillerRangesByIndex: [:], results: [], complete: false)
    let asr = try requireValue(try eventObjects(root).first { $0["event_type"] as? String == "asr.completed" })
    let source = try SegmentTextReference(segmentationRunID: "live_seg", segmentID: "live0", asrRunID: "live_asr",
                                          asrEventSeq: try requireValue(asr["event_seq"] as? UInt64))
    let forged = try ClauseUnit(
        reference: ClauseReference(boundaryRunID: "boundary_live", clauseID: "c\(source.asrEventSeq)_1"),
        parts: [ClauseSourcePart(source: source, range: TextUTF16Range(start: 1, end: 2))],
        termination: .streamEnd
    )
    try await SessionWriter(sessionURL: root).append(EventDraft(
        eventType: ClauseEventType.clauseClosed, sessionID: sessionID, processingRunID: "boundary_live", payload: forged
    ))
    try await SessionWriter(sessionURL: root).append(EventDraft(
        eventType: ClauseEventType.priorityAssigned, sessionID: sessionID, processingRunID: "priority_live",
        payload: try ClausePriorityBatch.pending(references: [forged.reference], reason: .requestFailed, message: "x")
    ))

    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try EventLogTranscriptReader().liveContentPriorityDecisions(
            from: try Data(contentsOf: root.appending(path: "events.jsonl")),
            modelRevision: testDecisionIdentity.modelRevision
        )
    }
}

@Test
func savedFillerRangeRemovesOnlyDisplayText() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["えー本文"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let fillerRange = try TextUTF16Range(start: 0, end: 2)
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: ["s01": [fillerRange]]),
        priority: lowForBackchannel
    )
    _ = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)

    let segment = try #require(try readPublished(root: root).first)
    #expect(segment.text == "えー本文")
    #expect(segment.displayText == "本文")
}

@Test
func eventLogTranscriptReaderRejectsSavedFillerRangeOutsideSourceText() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeLiveRun(root: root, sessionID: UUID(), texts: ["えー本文"], fillerRangesByIndex: [:], results: [], complete: false)
    var objects = try eventObjects(root)
    let assessmentIndex = try #require(objects.firstIndex {
        $0["event_type"] as? String == ClauseEventType.boundaryAssessed
    })
    var payload = try #require(objects[assessmentIndex]["payload"] as? [String: Any])
    payload["filler_ranges"] = [["start": 0, "end": 5]]
    objects[assessmentIndex]["payload"] = payload
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    let activeRuns = ActiveRuns(
        segmentation: "live_seg", asr: "live_asr", clauseBoundary: "boundary_live", contentPriority: "priority_live"
    )

    #expect(throws: (any Error).self) {
        _ = try EventLogTranscriptReader().events(lines: lines, activeRuns: activeRuns)
    }
}

@Test
func publishedSnapshotRejectsAPendingListThatContradictsTheLog() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["一。二"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    var metadata = try requireValue(try ProcessingMetadataStore(sessionURL: root).load())

    #expect(try DecisionRetryAnalyzer().retryTargets(lines: eventLines(root), metadata: metadata)
        == DecisionRetryTargets(boundarySegments: [], clauses: result.pendingPriorityClauses))

    metadata.pendingContentPriorityClauses = [result.pendingPriorityClauses[0]]
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try DecisionRetryAnalyzer().retryTargets(lines: eventLines(root), metadata: metadata)
    }
    metadata.pendingContentPriorityClauses = result.pendingPriorityClauses
    metadata.pendingClauseBoundarySegments = [try source("s01", in: events)]
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try DecisionRetryAnalyzer().retryTargets(lines: eventLines(root), metadata: metadata)
    }
}

@Test
func readerRejectsAPublishedClauseRunWhoseClausesDoNotMatchItsBoundaries() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["一。二"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    _ = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    #expect(try readPublished(root: root).map(\.clauseState) == [.classified])

    // Moving one raw boundary by a character must not be read as a valid split.
    let url = root.appending(path: "events.jsonl")
    let tampered = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: #""range":{"end":2,"start":0}"#, with: #""range":{"end":1,"start":0}"#)
        .replacingOccurrences(of: #""range":{"start":0,"end":2}"#, with: #""range":{"start":0,"end":1}"#)
    #expect(tampered != (try String(contentsOf: url, encoding: .utf8)))
    try tampered.write(to: url, atomically: true, encoding: .utf8)

    #expect(throws: (any Error).self) { try readPublished(root: root) }
}

@Test
func malformedUnrelatedRunsDoNotInvalidatePublishedClauseSnapshot() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["一。二"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let snapshot = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    let url = root.appending(path: "events.jsonl")
    var bytes = try Data(contentsOf: url)
    let lastSeq = try #require(try eventObjects(root).last?["event_seq"] as? UInt64)
    for (offset, type) in ["asr.completed", ClauseEventType.boundaryAssessed, ClauseEventType.priorityAssigned].enumerated() {
        let corrupted: [String: Any] = [
            "schema_version": EventLogSchema.version, "event_seq": lastSeq + UInt64(offset) + 1, "event_type": type,
            "session_id": sessionID.uuidString, "processing_run_id": "unpublished",
            "segmentation_run_id": "unused", "payload": [:]
        ]
        bytes.append(try JSONSerialization.data(withJSONObject: corrupted))
        bytes.append(0x0A)
    }
    try bytes.write(to: url)
    #expect(try readPublished(root: root) == snapshot.materializedSegments)
    let metadata = try requireValue(try ProcessingMetadataStore(sessionURL: root).load())
    #expect(try DecisionRetryAnalyzer().retryTargets(lines: eventLines(root), metadata: metadata)
        == DecisionRetryTargets(boundarySegments: [], clauses: []))
}

@Test(arguments: ["missingCandidate", "insideCharacter", "coverageGap", "unknownSource", "nextHead", "duplicatePriority", "completionCount"])
func everyClauseConsumerRejectsCorruptDurableSnapshot(kind: String) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeLiveRun(root: root, sessionID: UUID(), texts: ["えー、👩🏽‍💻。後", "本文"],
                           fillerRangesByIndex: [:], results: [(0, .primary), (1, .lowPriority)], complete: true)
    var objects = try eventObjects(root)
    let index = try #require(objects.firstIndex {
        $0["event_type"] as? String == (kind == "coverageGap" ? ClauseEventType.clauseClosed
            : kind == "duplicatePriority" ? ClauseEventType.priorityAssigned
            : kind == "completionCount" ? "processing.run.completed" : ClauseEventType.boundaryAssessed)
    })
    var payload = try #require(objects[index]["payload"] as? [String: Any])
    switch kind {
    case "missingCandidate":
        var candidates = try #require(payload["candidates"] as? [[String: Any]])
        let removed = candidates.removeFirst()
        var probabilities = try #require(payload["probabilities"] as? [String: Any])
        probabilities.removeValue(forKey: try #require(removed["id"] as? String))
        payload["candidates"] = candidates
        payload["probabilities"] = probabilities
    case "insideCharacter":
        var candidates = try #require(payload["candidates"] as? [[String: Any]])
        candidates[1]["offset_utf16"] = 5
        payload["candidates"] = candidates
    case "coverageGap":
        var parts = try #require(payload["parts"] as? [[String: Any]])
        var range = try #require(parts[0]["range"] as? [String: Any])
        range["end"] = 3
        parts[0]["range"] = range
        payload["parts"] = parts
    case "unknownSource":
        var source = try #require(payload["source"] as? [String: Any])
        source["asr_event_seq"] = 1
        payload["source"] = source
    case "nextHead":
        var head = try #require(payload["next_head"] as? [String: Any])
        head["text"] = "異なる本文"
        payload["next_head"] = head
    case "duplicatePriority":
        let assignments = try #require(payload["assignments"] as? [[String: Any]])
        payload["assignments"] = assignments + assignments
    default:
        payload["completed_count"] = 9
    }
    objects[index]["payload"] = payload
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    let active = ActiveRuns(segmentation: "live_seg", asr: "live_asr",
                            clauseBoundary: "boundary_live", contentPriority: "priority_live")
    let metadata = ProcessingMetadata(finalizationAttempt: nil, activeRuns: active,
                                      pendingClauseBoundarySegments: [], pendingContentPriorityClauses: [])
    #expect(throws: (any Error).self) {
        _ = try EventLogTranscriptReader().events(lines: lines, activeRuns: active)
    }
    #expect(throws: (any Error).self) {
        _ = try DecisionRetryAnalyzer().retryTargets(lines: lines, metadata: metadata)
    }
    let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    #expect(throws: (any Error).self) {
        _ = try EventLogTranscriptReader().liveContentPriorityDecisions(from: data, modelRevision: testDecisionIdentity.modelRevision)
    }
}

@Test
func appendRejectsMissingClauseFieldsWithoutChangingTheLog() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionWriter(sessionURL: root)
    await #expect(throws: EventLogTranscriptReaderError.self) {
        try await writer.append(EventDraft(eventType: ClauseEventType.priorityAssigned, sessionID: UUID(),
                                           processingRunID: "priority", payload: EmptyPayload()))
    }
    let url = root.appending(path: "events.jsonl")
    #expect(try Data(contentsOf: url).isEmpty)
    let original = try eventLine(["event_seq": 1, "event_type": ClauseEventType.priorityAssigned,
                                  "processing_run_id": "priority", "payload": [:]]) + Data([0x0A])
    try original.write(to: url)
    #expect(throws: EventLogTranscriptReaderError.self) { _ = try SessionWriter(sessionURL: root) }
    #expect(try Data(contentsOf: url) == original)
}

@Test
func liveReuseRejectsUnfinishedFinalRunAsACarryOrigin() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try await writeLiveRun(root: root, sessionID: UUID(), texts: ["本文"], fillerRangesByIndex: [:], results: [(0, .primary)], complete: false)
    var objects = try eventObjects(root)
    let index = try #require(objects.firstIndex { $0["event_type"] as? String == "processing.run.started" })
    var payload = try #require(objects[index]["payload"] as? [String: Any])
    var provenance = try #require(payload["provenance"] as? [String: Any])
    var configuration = try #require(provenance["configuration"] as? [String: Any])
    configuration["mode"] = "final"
    provenance["configuration"] = configuration
    payload["provenance"] = provenance
    objects[index]["payload"] = payload
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    let data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try EventLogTranscriptReader().liveContentPriorityDecisions(from: data, modelRevision: testDecisionIdentity.modelRevision)
    }
}

@Test
func liveReuseDoesNotInventAStreamEndForAnUnassessedSuccessor() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(root: root, sessionID: sessionID, texts: ["先頭", "続き"], fillerRangesByIndex: [:], results: [], complete: false)
    var objects = try eventObjects(root)
    let assessmentIndex = try #require(objects.firstIndex { $0["event_type"] as? String == ClauseEventType.boundaryAssessed })
    var payload = try #require(objects[assessmentIndex]["payload"] as? [String: Any])
    payload["continuation_probability"] = 0.9
    objects[assessmentIndex]["payload"] = payload
    let sourceObject = try #require(payload["source"] as? [String: Any])
    let source = try JSONDecoder().decode(SegmentTextReference.self, from: JSONSerialization.data(withJSONObject: sourceObject))
    let forged = try ClauseUnit(reference: ClauseReference(boundaryRunID: "boundary_live", clauseID: "c\(source.asrEventSeq)_0"),
                                parts: [ClauseSourcePart(source: source, range: TextUTF16Range(start: 0, end: 2))],
                                termination: .streamEnd)
    let clauseIndex = try #require(objects.firstIndex { $0["event_type"] as? String == ClauseEventType.clauseClosed })
    objects[clauseIndex]["payload"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(forged))
    let cutoff = objects[clauseIndex]["event_seq"] as! UInt64
    objects = objects.filter { ($0["event_seq"] as! UInt64) <= cutoff || $0["event_type"] as? String == "processing.run.started" }
    let lines = try objects.map { try JSONSerialization.data(withJSONObject: $0) }
    let decoded = try EventLogLine.decode(lines)
    let log = try ClauseEventLog(lines: decoded)
    #expect(throws: EventLogTranscriptReaderError.self) { _ = try log.boundaryRun("boundary_live") }
}

@Test(arguments: [ProcessingStage.segmentation, .asr, .diarization])
func readersRejectUnknownLocalPointersInsteadOfInventingAnEmptyTranscript(stage: ProcessingStage) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await writeTranscript([], root: root, sessionID: UUID())
    let lines = try eventLines(root)
    #expect(try EventLogTranscriptReader().events(lines: lines, activeRuns: transcriptRuns).isEmpty)
    let invalid = ActiveRuns(
        segmentation: stage == .segmentation ? "missing" : "seg",
        asr: stage == .asr ? "missing" : "asr",
        diarization: stage == .diarization ? "missing" : "diar"
    )
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try EventLogTranscriptReader().events(lines: lines, activeRuns: invalid)
    }
    #expect(throws: EventLogTranscriptReaderError.self) {
        _ = try DecisionRetryAnalyzer().retryTargets(
            lines: lines, metadata: ProcessingMetadata(finalizationAttempt: nil, activeRuns: invalid,
                                                       pendingClauseBoundarySegments: [], pendingContentPriorityClauses: [])
        )
    }
}
