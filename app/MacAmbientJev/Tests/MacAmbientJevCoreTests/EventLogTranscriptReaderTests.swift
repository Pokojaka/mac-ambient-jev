import Foundation
import Testing
@testable import MacAmbientJevCore

private func eventLine(_ object: [String: Any], sessionID: UUID) throws -> Data {
    var envelope = object
    envelope["schema_version"] = EventLogSchema.version
    envelope["session_id"] = sessionID.uuidString
    return try JSONSerialization.data(withJSONObject: envelope)
}

private func temporaryEventRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

private func decodedEventObjects(_ root: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: root.appending(path: "events.jsonl"))
    return try SessionRecovery.recoverJSONL(data).lines.map {
        try JSONSerialization.jsonObject(with: $0) as! [String: Any]
    }
}

private func encodedEventLines(_ objects: [[String: Any]]) throws -> [Data] {
    try objects.map { try JSONSerialization.data(withJSONObject: $0) }
}

private func writeEventObjects(_ objects: [[String: Any]], to root: URL) throws {
    var data = Data()
    for line in try encodedEventLines(objects) {
        data.append(line)
        data.append(0x0A)
    }
    try data.write(to: root.appending(path: "events.jsonl"))
}

@Test
func eventLogTranscriptReaderSkipsOtherRunsAndUnknownEventTypes() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["発話"], fillerRangesByIndex: [:], results: [], complete: false
    )

    var objects = try decodedEventObjects(root)
    let lastSequence = try #require(objects.last?["event_seq"] as? UInt64)
    objects.append([
        "schema_version": EventLogSchema.version, "event_seq": lastSequence + 1,
        "event_type": "asr.completed", "session_id": sessionID.uuidString,
        "processing_run_id": "asr-other", "segmentation_run_id": "live_seg", "segment_id": "live0",
        "payload": ["broken": true],
    ])
    objects.append([
        "schema_version": EventLogSchema.version, "event_seq": lastSequence + 2,
        "event_type": "future.event", "session_id": sessionID.uuidString, "payload": 42,
    ])
    let expected = try #require(try EventLogTranscriptReader().read(
        lines: encodedEventLines(Array(objects.dropLast(2))), sessionID: sessionID
    ))
    let actual = try #require(try EventLogTranscriptReader().read(
        lines: encodedEventLines(objects), sessionID: sessionID
    ))

    #expect(actual.events == expected.events)
    #expect(actual.state.events == expected.state.events)
    #expect(actual.state.runs == ActiveRuns(
        segmentation: "live_seg", asr: "live_asr", clauseBoundary: "boundary_live", contentPriority: "priority_live"
    ))
}

@Test
func eventLogTranscriptReaderRejectsAMalformedSelectedEvent() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["発話"], fillerRangesByIndex: [:], results: [], complete: false
    )
    var objects = try decodedEventObjects(root)
    let index = try #require(objects.firstIndex { $0["event_type"] as? String == "asr.completed" })
    let eventSequence = try #require(objects[index]["event_seq"] as? UInt64)
    objects[index]["payload"] = ["engine": "test", "model": "test", "outcome": "recognized"]
    let lines = try encodedEventLines(objects)

    #expect(throws: EventLogTranscriptReaderError.malformedEvent(
        eventSeq: eventSequence, eventType: "asr.completed"
    )) {
        _ = try EventLogTranscriptReader().read(lines: lines, sessionID: sessionID)
    }
}

@Test
func eventLogTranscriptReaderRejectsAnOutcomeThatContradictsTheText() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["発話"], fillerRangesByIndex: [:], results: [], complete: false
    )
    var objects = try decodedEventObjects(root)
    let index = try #require(objects.firstIndex { $0["event_type"] as? String == "asr.completed" })
    let eventSequence = try #require(objects[index]["event_seq"] as? UInt64)
    var payload = try #require(objects[index]["payload"] as? [String: Any])
    payload["outcome"] = "empty"
    objects[index]["payload"] = payload

    #expect(throws: EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: eventSequence)) {
        _ = try EventLogTranscriptReader().read(lines: encodedEventLines(objects), sessionID: sessionID)
    }
}

@Test
func eventLogReadersRejectALineWithoutEnvelope() throws {
    let sessionID = UUID()
    let line = try eventLine(["event_type": "segment.created"], sessionID: sessionID)

    #expect(throws: EventLogTranscriptReaderError.unreadableLine(index: 0)) {
        _ = try EventLogTranscriptReader().read(lines: [line], sessionID: sessionID)
    }
}

@Test(arguments: [1, 2, 3, 5, nil] as [Int?])
func readersAndWriterRejectAnyOtherEnvelopeVersion(version: Int?) async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    var object: [String: Any] = [
        "event_seq": 1, "event_type": "segment.created", "segmentation_run_id": "seg", "segment_id": "s1",
        "source_start_frame": 0, "source_end_frame": 100,
    ]
    let validLine = try eventLine(object, sessionID: sessionID)
    object = try JSONSerialization.jsonObject(with: validLine) as! [String: Any]
    object["schema_version"] = version
    let line = try JSONSerialization.data(withJSONObject: object)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try (line + Data([0x0A])).write(to: root.appending(path: "events.jsonl"))

    #expect(throws: EventLogSchemaError.unsupportedSchemaVersion(index: 0)) {
        _ = try EventLogTranscriptReader().read(lines: [line], sessionID: sessionID)
    }
    #expect(throws: EventLogSchemaError.unsupportedSchemaVersion(index: 0)) {
        _ = try SessionWriter(sessionURL: root)
    }
}

@Test
func resetImmediatelySelectsAnEmptyGeneration() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)
    let eventsURL = SessionLayout(sessionURL: root).eventsURL
    let provenance = RunProvenance(engine: "test", model: "test", version: "1", configuration: [:])
    let originalGeneration = PipelineGeneration(
        id: UUID(), runs: ActiveRuns(segmentation: "seg-old", asr: "asr-old"), sampleRate: 1_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    try await writer.append(originalGeneration.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "seg-old"), (.asr, "asr-old")] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    try await writer.append(.segmentCreated(
        sessionID: sessionID,
        segment: SegmentReference(segmentationRunID: "seg-old", segmentID: "old-segment", speechRanges: [0..<90])
    ))
    try await writer.append(EventDraft(
        eventType: "asr.completed", sessionID: sessionID, processingRunID: "asr-old",
        segmentationRunID: "seg-old", segmentID: "old-segment",
        payload: ASRCompletedEventPayload(text: "以前の本文", detectedLanguage: "ja", provenance: provenance)
    ))

    let reader = EventLogTranscriptReader()
    let oldStored = try #require(try reader.read(eventsURL: eventsURL, sessionID: sessionID))
    let oldSegments = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: oldStored.events, activeRuns: oldStored.state.runs
    )
    let oldRows = try LiveTranscriptProjection().rows(for: oldSegments)
    #expect(oldStored.events.count == 2)
    #expect(oldStored.state.segments.map(\.segmentID) == ["old-segment"])
    #expect(oldRows.map(\.text) == ["以前の本文"])
    #expect(oldRows.first?.clauseState == .boundaryPending)
    let oldBytes = try Data(contentsOf: eventsURL)

    let newGeneration = PipelineGeneration(
        id: UUID(), runs: ActiveRuns(segmentation: "seg-new", asr: "asr-new"), sampleRate: 1_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    try await writer.append(newGeneration.startEvent(sessionID: sessionID))
    let newBytes = try Data(contentsOf: eventsURL)
    let newStored = try #require(try reader.read(eventsURL: eventsURL, sessionID: sessionID))
    let newSegments = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: newStored.events, activeRuns: newStored.state.runs
    )

    #expect(newBytes.starts(with: oldBytes))
    #expect(newStored.state.generation.id == newGeneration.id)
    #expect(newStored.state.runs == ActiveRuns(segmentation: "seg-new", asr: "asr-new"))
    #expect(newStored.events.isEmpty)
    #expect(newStored.state.segments.isEmpty)
    #expect(newSegments.isEmpty)
    #expect(try LiveTranscriptProjection().rows(for: newSegments).isEmpty)
}

@Test
func validateCompletionRequiresCompletedRecognitionStages() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["本文"], fillerRangesByIndex: [:], results: [], complete: false
    )
    let reader = EventLogTranscriptReader()
    let partial = try #require(try reader.read(eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID))
    #expect(!partial.state.recognitionCompleted)
    #expect(throws: ProcessingLogStateError.incompleteRecognition) {
        _ = try reader.validateCompletion(
            eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID, frameCount: 90
        )
    }

    let completedRoot = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: completedRoot) }
    try await writeLiveRun(
        root: completedRoot, sessionID: sessionID, texts: ["本文"], fillerRangesByIndex: [:],
        results: [(0, .primary)], complete: true
    )
    let completed = try reader.validateCompletion(
        eventsURL: completedRoot.appending(path: "events.jsonl"), sessionID: sessionID, frameCount: 90
    )
    #expect(completed.state.recognitionCompleted)
    #expect(completed.state.events.count == 2)
}

@Test
func savedFillerRangeChangesOnlyDisplayText() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let fillerRange = try TextUTF16Range(start: 0, end: 2)
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["えー本文"], fillerRangesByIndex: [0: [fillerRange]],
        results: [], complete: false
    )
    let stored = try #require(try EventLogTranscriptReader().read(
        eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID
    ))
    let segments = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: stored.events, activeRuns: stored.state.runs
    )
    let segment = try #require(segments.first)
    let rows = try LiveTranscriptProjection().rows(for: segments)

    #expect(segment.text == "えー本文")
    #expect(segment.displayText == "本文")
    #expect(rows.map(\.text) == ["本文"])
}

@Test
func eventLogTranscriptReaderRejectsSavedFillerRangeOutsideSourceText() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["えー本文"], fillerRangesByIndex: [:], results: [], complete: false
    )
    var objects = try decodedEventObjects(root)
    let assessmentIndex = try #require(objects.firstIndex {
        $0["event_type"] as? String == ClauseEventType.boundaryAssessed
    })
    var payload = try #require(objects[assessmentIndex]["payload"] as? [String: Any])
    payload["filler_ranges"] = [["start": 0, "end": 5]]
    objects[assessmentIndex]["payload"] = payload

    #expect(throws: (any Error).self) {
        _ = try EventLogTranscriptReader().read(lines: encodedEventLines(objects), sessionID: sessionID)
    }
}

@Test(arguments: ["missingCandidate", "insideCharacter", "coverageGap", "unknownSource", "nextHead", "duplicatePriority", "completionCount"])
func readerRejectsCorruptDecisionRecords(kind: String) async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["えー、👩🏽‍💻。後", "本文"], fillerRangesByIndex: [:],
        results: [(0, .primary), (1, .lowPriority)], complete: true
    )
    var objects = try decodedEventObjects(root)
    let index = try #require(objects.firstIndex {
        if kind == "coverageGap" { return $0["event_type"] as? String == ClauseEventType.clauseClosed }
        if kind == "duplicatePriority" { return $0["event_type"] as? String == ClauseEventType.priorityAssigned }
        if kind == "completionCount" {
            return $0["event_type"] as? String == "processing.run.completed"
                && $0["processing_run_id"] as? String == "boundary_live"
        }
        return $0["event_type"] as? String == ClauseEventType.boundaryAssessed
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
    let lines = try encodedEventLines(objects)

    #expect(throws: (any Error).self) {
        _ = try EventLogTranscriptReader().read(lines: lines, sessionID: sessionID)
    }
    if kind == "completionCount" {
        try writeEventObjects(objects, to: root)
        #expect(throws: (any Error).self) {
            _ = try EventLogTranscriptReader().validateCompletion(
                eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID, frameCount: 190
            )
        }
    }
}

@Test
func readerRejectsADecisionSelectionThatReturnsToAnEarlierPriorityRun() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["本文"], fillerRangesByIndex: [:],
        results: [(0, .primary)], complete: true
    )
    let writer = try SessionWriter(sessionURL: root)
    let generationID = try #require(try EventLogTranscriptReader().read(
        eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID
    )?.state.generation.id)
    let original = DecisionRunIDs(boundary: "boundary_live", priority: "priority_live")
    let second = DecisionRunIDs(boundary: "boundary_b", priority: "priority_b")
    let third = DecisionRunIDs(boundary: "boundary_c", priority: "priority_live")
    try await writer.append(DecisionRunReplacement(
        generationID: generationID, previous: original, replacement: second
    ).selectionEvent(sessionID: sessionID))
    let returning = try await writer.append(DecisionRunReplacement(
        generationID: generationID, previous: second, replacement: third
    ).selectionEvent(sessionID: sessionID))

    #expect(throws: EventLogTranscriptReaderError.malformedEvent(
        eventSeq: returning.eventSeq, eventType: "pipeline.decisions.replaced"
    )) {
        _ = try EventLogTranscriptReader().read(
            eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID
        )
    }
}

@Test
func appendRejectsMissingClauseFieldsWithoutChangingTheLog() async throws {
    let root = temporaryEventRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try SessionWriter(sessionURL: root)
    await #expect(throws: EventLogTranscriptReaderError.malformedEvent(eventSeq: 1, eventType: ClauseEventType.priorityAssigned)) {
        try await writer.append(EventDraft(
            eventType: ClauseEventType.priorityAssigned, sessionID: UUID(), processingRunID: "priority",
            payload: EmptyPayload()
        ))
    }
    #expect(try Data(contentsOf: root.appending(path: "events.jsonl")).isEmpty)
}

/// Writes a live ASR run and a live decision run where every segment is one clause that does not
/// continue, with the given priority results in order. A nil result is a pending assignment.
func writeLiveRun(
    root: URL, sessionID: UUID, texts: [String], fillerRangesByIndex: [Int: [TextUTF16Range]],
    results: [(index: Int, priority: ContentPriority?)], complete: Bool
) async throws {
    let writer = try SessionWriter(sessionURL: root)
    let provenance = RunProvenance(engine: "test", model: nil, version: "1", configuration: [:])
    let selectedRuns = ActiveRuns(
        segmentation: "live_seg", asr: "live_asr", clauseBoundary: "boundary_live", contentPriority: "priority_live"
    )
    let generation = PipelineGeneration(
        id: UUID(), runs: selectedRuns, sampleRate: 1_000,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    try await writer.append(generation.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "live_seg"), (.asr, "live_asr")] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }

    var sources: [SegmentTextReference] = []
    for (index, text) in texts.enumerated() {
        let segmentID = "live\(index)"
        let startFrame = Int64(index * 100)
        let segment = SegmentReference(
            segmentationRunID: "live_seg", segmentID: segmentID, speechRanges: [startFrame..<(startFrame + 90)]
        )
        try await writer.append(.segmentCreated(sessionID: sessionID, segment: segment))
        let asr = try await writer.append(EventDraft(
            eventType: "asr.completed", sessionID: sessionID, processingRunID: "live_asr",
            segmentationRunID: "live_seg", segmentID: segmentID,
            payload: ASRCompletedEventPayload(text: text, detectedLanguage: nil, provenance: provenance)
        ))
        sources.append(try SegmentTextReference(
            segmentationRunID: "live_seg", segmentID: segmentID, asrRunID: "live_asr", asrEventSeq: asr.eventSeq
        ))
    }

    if complete {
        let frameCount = Int64(texts.count * 100 - (texts.isEmpty ? 0 : 10))
        try await writer.append(EventDraft(
            eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: "live_seg",
            payload: SegmentationInputSealedPayload(frameCount: frameCount)
        ))
        try await writer.append(EventDraft(
            eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: "live_seg",
            payload: SegmentationCompletedPayload(consumedFrames: frameCount, segmentCount: texts.count)
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "live_seg",
            payload: ProcessingRunCompletedPayload(stage: .segmentation, succeeded: true, completedCount: texts.count, failedCount: 0)
        ))
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "live_asr",
            payload: ProcessingRunCompletedPayload(stage: .asr, succeeded: true, completedCount: texts.count, failedCount: 0)
        ))
    }

    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: sessionID, processingRunID: "boundary_live",
        payload: ProcessingRunStartedPayload(stage: .clauseBoundary, provenance: DecisionRunProvenance.boundary(identity: testDecisionIdentity))
    ))
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
        try await writer.append(EventDraft(
            eventType: ClauseEventType.boundaryAssessed, sessionID: sessionID,
            processingRunID: "boundary_live", payload: assessment
        ))
        for unit in try assembly.consume(ClauseAssemblyInput(source: source, text: texts[index], state: .assessed(assessment))).closed {
            try await writer.append(EventDraft(
                eventType: ClauseEventType.clauseClosed, sessionID: sessionID,
                processingRunID: "boundary_live", payload: unit
            ))
            units.append(unit)
        }
    }

    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: sessionID, processingRunID: "priority_live",
        payload: ProcessingRunStartedPayload(stage: .contentPriority, provenance: DecisionRunProvenance.priority(identity: testDecisionIdentity))
    ))
    for (order, result) in results.enumerated() {
        let reference = units[result.index].reference
        let payload: ContentPriorityAssignedPayload
        if let priority = result.priority {
            let decision = try ContentPriorityDecision(
                priority: priority, confidence: 0.95,
                probabilities: priority == .primary ? ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025] : ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975]
            )
            payload = try ContentPriorityAssignedPayload(assignments: [ClausePriorityAssignment(
                reference: reference, priority: priority, needsRetry: false,
                decision: .classified(requestID: "p\(order)", answerKey: "u0001", response: decision)
            )], request: DecisionRequestRecord(requestID: "p\(order)", inputTokens: testInputTokens))
        } else {
            payload = try ClausePriorityBatch.pending(references: [reference], reason: .requestFailed, message: "x")
        }
        try await writer.append(EventDraft(
            eventType: ClauseEventType.priorityAssigned, sessionID: sessionID,
            processingRunID: "priority_live", payload: payload
        ))
    }
    if complete {
        for (runID, stage) in [("boundary_live", ProcessingStage.clauseBoundary), ("priority_live", .contentPriority)] {
            let pendingCount = results.filter { $0.priority == nil }.count
            let completedCount = stage == .clauseBoundary ? sources.count : results.count - pendingCount
            try await writer.append(EventDraft(
                eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
                payload: ProcessingRunCompletedPayload(
                    stage: stage, succeeded: true, completedCount: completedCount,
                    failedCount: stage == .clauseBoundary ? 0 : pendingCount
                )
            ))
        }
    }
}
