import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func finalSnapshotJoinsSegmentsIntoClausesAndClassifiesFillerRemovedText() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["えー、これは", "コピーと。うん、うん。", "次の話です"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let knownFiller = try TextUTF16Range(start: 0, end: 2)
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(
            continuing: ["s01"], fillerRangesBySegment: ["s01": [knownFiller]]
        ), priority: lowForBackchannel
    )
    let counter = DecisionUsageCounter()

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all, counter: counter)

    let boundaryRequests = await provider.boundaryRequests
    #expect(boundaryRequests.map(\.source.segmentID) == ["s01", "s02", "s03"])
    #expect(boundaryRequests.map { $0.next?.text } == ["コピーと。うん、うん。", "次の話です", nil])
    #expect(boundaryRequests[2].candidates.isEmpty)
    // Boundaries are judged on raw ASR text, filler included.
    #expect(boundaryRequests[0].text == "えー、これは")
    let priorityRequests = await provider.priorityRequests
    // One priority request for the clauses the boundaries closed; filler removed, parts joined without spaces.
    #expect(priorityRequests.map { $0.map(\.text) } == [["これはコピーと。", "うん、うん。", "次の話です"]])
    #expect(result.pendingBoundarySegments.isEmpty)
    #expect(result.pendingPriorityClauses.isEmpty)

    let published = try readPublished(root: root)
    #expect(published == result.materializedSegments)
    #expect(published.map(\.clauseState) == [.classified, .classified, .classified])
    #expect(published.map(\.text) == ["えー、これは", "コピーと。うん、うん。", "次の話です"])
    #expect(published.map(\.displayText) == ["これは", "コピーと。", "次の話です"])
    let spanning = published[0].clauseSlices[0].reference
    #expect(published[1].clauseSlices.map(\.reference).first == spanning)
    #expect(published[1].clauseSlices.map(\.priority) == [.primary, .lowPriority])
    #expect(try LiveTranscriptProjection().rows(for: published).map(\.text) == ["これは", "コピーと。", "次の話です"])

    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 3)
    #expect(snapshot.boundaryRequests.successCount == 3)
    #expect(snapshot.boundaryRequests.inputTokens == 30)
    #expect(snapshot.priorityRequests.sendCount == 1)
    #expect(snapshot.inputTokens == 40)
    #expect(snapshot.pendingBoundarySegmentCount == 0)

    let assigned = try eventObjects(root).filter { $0["event_type"] as? String == "content_priority.assigned" }
    #expect(assigned.count == 1)
    let payload = try requireValue(assigned[0]["payload"] as? [String: Any])
    #expect((payload["assignments"] as? [Any])?.count == 3)
    #expect((payload["request"] as? [String: Any])?["request_id"] != nil)
}

@Test
func finalSnapshotPersistsModelProvenanceAndRequestRecords() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["最初。後続", "独立"], root: root, sessionID: sessionID)
    let initialMetadata = try publishLocal(root: root, events: events)
    let modelID = "sbintuitions/modernbert-ja-30m-multitagger"
    let revision = String(repeating: "a", count: 64)
    let counter = DecisionUsageCounter()
    let provider = FixedResponseDecisionProvider()
    let decisions = DecisionCoordinator(
        provider: provider, identity: try DecisionModelIdentity(model: modelID, modelRevision: revision), usageCounter: counter
    )
    let boundaryRunID = "boundary_local_final"
    let priorityRunID = "priority_local_final"
    let activeRuns = try requireValue(initialMetadata.activeRuns)
    let coordinator = DecisionEnrichmentCoordinator(
        sessionID: sessionID, boundaryRunID: boundaryRunID, priorityRunID: priorityRunID,
        writer: try SessionWriter(sessionURL: root), decisions: decisions,
        usageCounter: counter, materializer: TranscriptMaterializer(sampleRate: 1_000)
    )

    let result = try await coordinator.process(
        existingEvents: try EventLogTranscriptReader().events(lines: eventLines(root), activeRuns: activeRuns),
        activeRuns: activeRuns, scope: .all, reusableDecisions: [:], onEvent: nil
    )
    try ProcessingMetadataStore(sessionURL: root).publishDecisionSnapshot(
        basedOn: activeRuns, clauseBoundaryRunID: result.boundaryRunID,
        contentPriorityRunID: result.priorityRunID,
        pendingClauseBoundarySegments: result.pendingBoundarySegments,
        pendingContentPriorityClauses: result.pendingPriorityClauses
    )
    await coordinator.recordPublished(result, replacing: initialMetadata.pendingDecisionTargets)

    let objects = try eventObjects(root)
    let starts = objects.filter { $0["event_type"] as? String == "processing.run.started" }
        .filter { [boundaryRunID, priorityRunID].contains($0["processing_run_id"] as? String ?? "") }
    #expect(starts.compactMap { ($0["payload"] as? [String: Any])?["stage"] as? String }
        == [ProcessingStage.clauseBoundary.rawValue, ProcessingStage.contentPriority.rawValue])
    for start in starts {
        let provenance = try requireValue((start["payload"] as? [String: Any])?["provenance"] as? [String: Any])
        #expect(provenance["engine"] as? String == "coreml-clause-tagger")
        #expect(provenance["model"] as? String == modelID)
        #expect(provenance["version"] as? String == revision)
        let configuration = try requireValue(provenance["configuration"] as? [String: String])
        #expect(configuration["model_id"] == modelID)
        #expect(configuration["model_revision"] == revision)
        #expect(configuration["unit_policy"] == "btsj-utterance-sentence")
    }

    let boundaryPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.boundaryAssessed }
        .compactMap { $0["payload"] as? [String: Any] }
    let requestedBoundaries = boundaryPayloads.compactMap { $0["request"] as? [String: Any] }
    #expect(requestedBoundaries.count == 2)
    #expect(boundaryPayloads.map {
        ($0["candidates"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    } == [["b0001"], []])
    #expect((boundaryPayloads.first?["probabilities"] as? [String: Double])?["b0001"] == 0.99)
    #expect(boundaryPayloads.compactMap {
        ($0["source_decision"] as? [String: Any])?["kind"] as? String
    } == ["assessed", "assessed"])
    #expect(boundaryPayloads.allSatisfy { ($0["request"] as? [String: Any])?["request_id"] != nil })
    let priorityPayloads = objects.filter { $0["event_type"] as? String == ClauseEventType.priorityAssigned }
        .compactMap { $0["payload"] as? [String: Any] }
    #expect(priorityPayloads.count == 1)
    #expect((priorityPayloads.first?["assignments"] as? [Any])?.count == 3)

    let requestRecords = requestedBoundaries + priorityPayloads.compactMap { $0["request"] as? [String: Any] }
    #expect(requestRecords.count == 3)
    #expect(requestRecords.allSatisfy { ($0["request_id"] as? String)?.hasPrefix("decisionreq_") == true })
    #expect(requestRecords.allSatisfy { Set($0.keys) == ["request_id", "input_tokens"] })
    #expect(Set(requestRecords.compactMap { $0["input_tokens"] as? Int }) == [11, 17])

    let selectedRuns = activeRuns.withDecisionRuns(clauseBoundary: boundaryRunID, contentPriority: priorityRunID)
    let reconstructed = try EventLogTranscriptReader().events(lines: eventLines(root), activeRuns: selectedRuns)
    #expect(reconstructed.count == result.events.count)
    #expect(try readPublished(root: root).filter(\.hasRecognizedText).map(\.clauseState)
        == [.classified, .classified])
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 2)
    #expect(usage.boundaryRequests.successCount == 2)
    #expect(usage.boundaryRequests.inputTokens == 22)
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage.inputTokens == 39)
}

@Test
func boundaryAssessmentRequiresAndCarriesFillerRanges() throws {
    let source = try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s01", asrRunID: "asr", asrEventSeq: 1
    )
    let range = try TextUTF16Range(start: 1, end: 3)
    let request = try DecisionRequestRecord(requestID: "decisionreq_test", inputTokens: 1)
    let assessment = try ClauseBoundaryAssessment(
        source: source, candidates: [], probabilities: [:], nextHead: nil,
        continuationProbability: nil, fillerRanges: [range], request: request,
        sourceDecision: .assessed
    )
    let assessmentWithDifferentFillerRanges = try ClauseBoundaryAssessment(
        source: source, candidates: [], probabilities: [:], nextHead: nil,
        continuationProbability: nil, fillerRanges: [], request: request,
        sourceDecision: .assessed
    )
    #expect(!assessment.hasSameDecisions(as: assessmentWithDifferentFillerRanges))
    let encoded = try JSONEncoder().encode(assessment)
    #expect(try JSONDecoder().decode(ClauseBoundaryAssessment.self, from: encoded) == assessment)

    var payload = try requireValue(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(payload["filler_ranges"] != nil)
    payload.removeValue(forKey: "filler_ranges")
    let missingRanges = try JSONSerialization.data(withJSONObject: payload)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ClauseBoundaryAssessment.self, from: missingRanges)
    }

    let carried = try assessment.carriedOver(fromRunID: "boundary_source", eventSeq: 2)
    #expect(carried.fillerRanges == [range])
    #expect(assessment.hasSameDecisions(as: carried))
    #expect(try JSONDecoder().decode(ClauseBoundaryAssessment.self, from: JSONEncoder().encode(carried)) == carried)
}

@Test
func malformedFillerRangesFailBoundaryRequestWithoutSuccessUsage() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["本文"], root: root, sessionID: sessionID)
    let local = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: { request in
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: nil,
            fillerRanges: [try TextUTF16Range(start: 0, end: 3)],
            inputTokens: testInputTokens
        )
    }, priority: lowForBackchannel)
    let counter = DecisionUsageCounter()

    let result = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider, scope: .all, counter: counter
    )

    #expect(await provider.boundaryRequests.count == 1)
    #expect(result.pendingBoundarySegments == local.pendingClauseBoundarySegments)
    #expect(result.pendingPriorityClauses.isEmpty)
    #expect(try readPublished(root: root).first?.clauseState == .boundaryPending)
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.boundaryRequests.successCount == 0)
    #expect(usage.boundaryRequests.failureCount == 1)
    #expect(usage.boundaryRequests.inputTokens == 0)
    #expect(usage.pendingBoundarySegmentCount == 1)
}

@Test
func fortyOneClausesAreSentAsTwoOrderedPriorityRequests() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let text = (1...41).map { "文\($0)。" }.joined() + "終わり"
    _ = try publishLocal(root: root, events: try await writeTranscript([text], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)

    let requests = await provider.priorityRequests
    #expect(requests.map(\.count) == [40, 2])
    #expect(requests[0].first?.text == "文1。")
    #expect(requests[1].map(\.text) == ["文41。", "終わり"])
    #expect(await provider.boundaryRequests.count == 1)
    #expect(result.materializedSegments.first?.clauseSlices.count == 42)
}

@Test(arguments: [40, 41])
func priorityBatchLimitAppliesAfterRemovingDurableReusableClauses(_ remaining: Int) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let texts = (1...(remaining + 1)).map { "文\($0)。" }
    _ = try publishLocal(root: root, events: try await writeTranscript([texts.joined()], root: root, sessionID: sessionID))
    try await writeLiveRun(root: root, sessionID: sessionID, texts: [texts[0]],
                           fillerRangesByIndex: [:], results: [(0, .lowPriority)], complete: false)
    let reusable = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: Data(contentsOf: root.appending(path: "events.jsonl")),
        modelRevision: testDecisionIdentity.modelRevision
    )
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider, scope: .all,
        reusable: reusable, counter: counter
    )
    let requests = await provider.priorityRequests
    #expect(requests.map(\.count) == (remaining == 40 ? [40] : [40, 1]))
    #expect(requests.flatMap { $0.map(\.text) } == Array(texts.dropFirst()))
    #expect(result.materializedSegments.first?.clauseSlices.first?.priority == .lowPriority)
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.priorityRequests.sendCount == (remaining == 40 ? 1 : 2))
    #expect(usage.inputTokens == (remaining == 40 ? 20 : 30))
    #expect(try readPublished(root: root) == result.materializedSegments)
}

@Test
func liveDecisionIsReusedOnlyForTheByteIdenticalFilteredText() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    // The first clause differs from the live text only by a removed filler; the second by Unicode normalization.
    _ = try publishLocal(root: root, events: try await writeTranscript(["えー、同じ発話。か\u{3099}くせい"], root: root, sessionID: sessionID))
    let knownFiller = try TextUTF16Range(start: 0, end: 2)
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: ["s01": [knownFiller]]),
        priority: lowForBackchannel
    )
    try await writeLiveRun(
        root: root, sessionID: sessionID, texts: ["同じ発話。", "がくせい"],
        fillerRangesByIndex: [:], results: [(0, .lowPriority), (1, .lowPriority)], complete: false
    )
    let reusable = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: Data(contentsOf: root.appending(path: "events.jsonl")),
        modelRevision: testDecisionIdentity.modelRevision
    )

    let result = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider, scope: .all,
        reusable: reusable
    )

    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["か\u{3099}くせい"]])
    let slices = try requireValue(result.materializedSegments.first).clauseSlices
    #expect(slices.map(\.priority) == [.lowPriority, .primary])
    let assigned = try eventObjects(root).filter {
        $0["event_type"] as? String == "content_priority.assigned"
            && $0["processing_run_id"] as? String == result.priorityRunID
    }
    let carried = try requireValue(assigned.first?["payload"] as? [String: Any])
    #expect(carried["request"] is NSNull)
    let decision = try requireValue(((carried["assignments"] as? [[String: Any]])?.first?["decision"]) as? [String: Any])
    #expect(decision["kind"] as? String == "carried_over")
    #expect(decision["source_priority_run_id"] as? String == "priority_live")
    #expect(decision["source_event_seq"] as? UInt64 == reusable[ExactClauseTextKey(text: "同じ発話。")]?.sourceEventSeq)
}

@Test
func nonexistentReuseIsRejectedBeforeAnyBoundaryRequest() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["本文。次"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let reuse = ReusableClauseDecision(
        sourcePriorityRunID: "unknown", sourceEventSeq: 999,
        sourceClause: try ClauseReference(boundaryRunID: "missing", clauseID: "c1_0"),
        decision: try ContentPriorityDecision(priority: .primary, confidence: 1, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]),
        visiblePriority: .primary
    )
    await #expect(throws: EventLogTranscriptReaderError.self) {
        try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all,
                                  reusable: [ExactClauseTextKey(text: "本文。"): reuse])
    }
    #expect(await provider.boundaryRequests.isEmpty)
    #expect(await provider.priorityRequests.isEmpty)
}

@Test
func localOnlyTargetedBoundaryRetryLeavesOtherSourcesPending() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["最初。後半", "", "独立"], root: root, sessionID: sessionID)
    let local = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: [try source("s01", in: events)], clauses: []))
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01"])
    #expect(result.pendingBoundarySegments == [local.pendingClauseBoundarySegments[1]])
    #expect(try readPublished(root: root).filter(\.hasRecognizedText).map(\.clauseState) == [.classified, .boundaryPending])
}

@Test
func emptyASRTerminatesAnUnresolvedComponentWithoutResolvingIt() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["保留。末尾", "", "独立。次"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s01" { throw DecisionResponseError.missingAnswer }
        return try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)
    _ = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["独立。", "次"]])
    let rows = try readPublished(root: root).filter(\.hasRecognizedText)
    #expect(rows.map(\.clauseState) == [.boundaryPending, .classified])
    #expect(rows[0].clauseSlices.isEmpty)
}

@Test
func punctuationOnlyASRTerminatesBoundaryStream() async throws {
    #expect(ASRRecognitionOutcome(text: " \t\n。？！") == .empty)
    #expect(ASRRecognitionOutcome(text: "本文") == .recognized)
    #expect(ASRRecognitionOutcome(text: "★") == .recognized)
    #expect(ASRRecognitionOutcome(text: "😀") == .recognized)

    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["最初。後続", "。", "次の本文"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: { request in
        if request.next != nil {
            _ = try ClauseTaggerEncoding.continuationInput(request) { piece -> [ClauseTaggerToken] in
                var offsetUTF16 = 0
                return try piece.unicodeScalars.enumerated().map { id, scalar in
                    let startUTF16 = offsetUTF16
                    offsetUTF16 += scalar.value > 0xFFFF ? 2 : 1
                    return ClauseTaggerToken(
                        id: id,
                        range: try TextUTF16Range(start: startUTF16, end: offsetUTF16)
                    )
                }
            }
        }
        return try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)

    let boundaryRequests = await provider.boundaryRequests
    #expect(boundaryRequests.map(\.source.segmentID) == ["s01", "s03"])
    #expect(boundaryRequests.allSatisfy { $0.next == nil })
    #expect(boundaryRequests[1].candidates.isEmpty)
    #expect(result.pendingBoundarySegments.isEmpty)

    let punctuationEvents = try eventObjects(root).filter {
        $0["event_type"] as? String == "asr.completed" && $0["segment_id"] as? String == "s02"
    }
    #expect(punctuationEvents.count == 1)
    let punctuationPayload = punctuationEvents.first?["payload"] as? [String: Any]
    #expect(punctuationPayload?["text"] as? String == "。")
    #expect(punctuationPayload?["outcome"] as? String == ASRRecognitionOutcome.empty.rawValue)

    let published = try readPublished(root: root)
    #expect(published.map(\.segmentID) == ["s01", "s02", "s03"])
    let punctuationSegment = try requireValue(published.first { $0.segmentID == "s02" })
    #expect(punctuationSegment.text == "。")
    #expect(!punctuationSegment.hasRecognizedText)
    #expect(try LiveTranscriptProjection().rows(for: published).map(\.segmentID) == ["s01", "s03"])
}

@Test
func failedBoundaryRequestsLeaveRecognizedSourcesUnresolved() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["一つ目。二つ目", "三つ目"], root: root, sessionID: sessionID)
    let local = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(
        boundary: { _ in throw DecisionResponseError.missingAnswer }, priority: lowForBackchannel
    )
    let counter = DecisionUsageCounter()
    await counter.recordDeferred(sessionID: sessionID, targets: local.pendingDecisionTargets)

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all, counter: counter)

    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01", "s02"])
    #expect(await provider.priorityRequests.isEmpty)
    #expect(result.pendingBoundarySegments == local.pendingClauseBoundarySegments)
    let published = try readPublished(root: root)
    #expect(published.map(\.clauseState) == [.boundaryPending, .boundaryPending])
    #expect(published.allSatisfy { $0.clauseSlices.isEmpty })
    // Unsplit rows stay normal text; a failed boundary is never turned into "no".
    #expect(try LiveTranscriptProjection().rows(for: published).map(\.text) == ["一つ目。二つ目", "三つ目"])
    let reasons = try eventObjects(root).filter { $0["event_type"] as? String == "clause_boundaries.pending" }
        .compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    #expect(reasons == ["request_failed", "request_failed"])
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 2)
    #expect(snapshot.failureCount == 2)
    #expect(snapshot.pendingBoundarySegmentCount == 2)
}

@Test
func requestSpecificBoundaryFailureKeepsSendingTheRemainingSegments() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let texts = (1...5).map { "説明その\($0)。続き" }
    _ = try publishLocal(root: root, events: try await writeTranscript(texts, root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(
        boundary: { _ in throw ClauseTaggerEncodingError.missingJunction }, priority: lowForBackchannel
    )

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)

    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01", "s02", "s03", "s04", "s05"])
    #expect(result.pendingBoundarySegments.map(\.segmentID) == ["s01", "s02", "s03", "s04", "s05"])
    #expect(try readPublished(root: root).map(\.clauseState) == Array(repeating: .boundaryPending, count: 5))
}

@Test
func requestSpecificPriorityFailureKeepsItsBatchPendingAndSendsTheNext() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let text = (1...41).map { "文\($0)。" }.joined()
    _ = try publishLocal(root: root, events: try await writeTranscript([text], root: root, sessionID: sessionID))
    let failedFirst = Locked(false)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { targets in
        if !failedFirst.value {
            failedFirst.set(true)
            throw DecisionResponseError.missingAnswer
        }
        return try lowForBackchannel(targets)
    })

    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)

    #expect(await provider.priorityRequests.map(\.count) == [40, 1])
    #expect(result.pendingPriorityClauses.count == 40)
    let published = try readPublished(root: root)
    #expect(published.map(\.clauseState) == [.priorityPending])
    #expect(try LiveTranscriptProjection().rows(for: published).map(\.text) == [text])
}

@Test
func priorityOnlyRetryRequestsOnlyTheTargetsAndCarriesEveryOtherResult() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["一。二。三"], root: root, sessionID: sessionID))
    let failing = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: failing, scope: .all)
    #expect(first.pendingPriorityClauses.count == 3)
    let counter = DecisionUsageCounter()
    await counter.recordDeferred(sessionID: sessionID, targets: first.pendingTargets)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let target = first.pendingPriorityClauses[1]

    let retried = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: [], clauses: [target]), counter: counter,
        boundaryRunID: first.boundaryRunID
    )

    #expect(await provider.boundaryRequests.isEmpty)
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["二。"]])
    #expect(retried.boundaryRunID == first.boundaryRunID)
    // Pending results that were not requested stay pending; they are never turned into results.
    #expect(retried.pendingPriorityClauses == [first.pendingPriorityClauses[0], first.pendingPriorityClauses[2]])
    let metadata = try requireValue(try ProcessingMetadataStore(sessionURL: root).load())
    #expect(metadata.activeRuns?.contentPriority == retried.priorityRunID)
    #expect(metadata.pendingContentPriorityClauses == retried.pendingPriorityClauses)
    #expect(try readPublished(root: root).first?.clauseSlices.map(\.needsRetry) == [true, false, true])
    let snapshot = await counter.snapshot()
    #expect(snapshot.pendingPriorityClauseCount == 2)
    #expect(snapshot.priorityRequests.sendCount == 1)
}

@Test
func boundaryRetryCarriesPublishedAssessmentsAndRequestsOnlyPendingSegments() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["前。続く", "途中", "終わり。後"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let failingMiddle = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s02" { throw DecisionResponseError.missingAnswer }
        return try punctuationBoundaries(continuing: ["s01", "s02"], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: failingMiddle, scope: .all)
    #expect(first.pendingBoundarySegments == [try source("s02", in: events)])
    // Only "前。" closed independently; the clause touching the pending segment stays unsplit.
    #expect(try readPublished(root: root).map(\.clauseState) == [.boundaryPending, .boundaryPending, .boundaryPending])
    #expect(await failingMiddle.priorityRequests.map { $0.map(\.text) } == [["前。", "後"]])

    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: ["s01", "s02"], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let retried = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: Set(first.pendingBoundarySegments), clauses: [])
    )

    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s02"])
    // Unchanged clauses keep their priority; only the clause that now closes is classified.
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["続く途中終わり。"]])
    #expect(retried.pendingBoundarySegments.isEmpty)
    #expect(try readPublished(root: root).map(\.clauseState) == [.classified, .classified, .classified])
    let carried = try eventObjects(root).filter {
        $0["event_type"] as? String == "clause_boundaries.assessed" && $0["processing_run_id"] as? String == retried.boundaryRunID
    }.compactMap { (($0["payload"] as? [String: Any])?["source_decision"] as? [String: Any])?["kind"] as? String }
    #expect(carried == ["carried_over", "assessed", "carried_over"])
}

@Test
func boundaryRetryWithoutTheNextASRSourceFailsBeforeSending() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["前", nil, "後"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    #expect(first.pendingBoundarySegments == [try source("s01", in: events)])
    let requestsBefore = await provider.boundaryRequests.count

    await #expect(throws: DecisionEnrichmentError.missingNextASRSource(segmentID: "s01")) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: provider,
            scope: .retry(boundarySegments: Set(first.pendingBoundarySegments), clauses: [])
        )
    }
    #expect(await provider.boundaryRequests.count == requestsBefore)
}

@Test
func retryRejectsTargetsThatAreNotPublishedPendingResults() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["一。二"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    let resolved = try requireValue(first.materializedSegments.first?.clauseSlices.first?.reference)

    await #expect(throws: DecisionEnrichmentError.unknownRetryTarget(resolved.clauseID)) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: provider,
            scope: .retry(boundarySegments: [], clauses: [resolved]), boundaryRunID: first.boundaryRunID
        )
    }
    await #expect(throws: DecisionEnrichmentError.unknownRetryTarget("s01")) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: provider,
            scope: .retry(boundarySegments: [try source("s01", in: events)], clauses: [])
        )
    }
}

private actor SuspendedPriorityProvider: DecisionProvider {
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var response: CheckedContinuation<Void, Never>?

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        didStart = true
        started?.resume()
        started = nil
        // Ignores cancellation, like a provider that answers late.
        await withCheckedContinuation { response = $0 }
        return try lowForBackchannel(targets)
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { started = $0 }
    }

    func releaseResponse() {
        response?.resume()
        response = nil
    }
}

@Test
func cancelledSnapshotDoesNotSaveAResponseThatArrivesLate() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["一。"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let provider = SuspendedPriorityProvider()
    let coordinator = DecisionEnrichmentCoordinator(
        sessionID: sessionID, boundaryRunID: "boundary", priorityRunID: "priority",
        writer: try SessionWriter(sessionURL: root),
        decisions: DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: DecisionUsageCounter()),
        usageCounter: DecisionUsageCounter(), materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let task = Task {
        try await coordinator.process(
            existingEvents: events, activeRuns: transcriptRuns, scope: .all, reusableDecisions: [:], onEvent: nil
        )
    }
    await provider.waitUntilStarted()
    task.cancel()
    await provider.releaseResponse()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try eventObjects(root).filter { $0["event_type"] as? String == "content_priority.assigned" }.isEmpty)
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

@Test
func leadingASRGapDoesNotInventTheFollowingHeadsStart() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript([nil, "未解決。独立"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    _ = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all)
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["独立"]])
    let row = try requireValue(try readPublished(root: root).first)
    #expect(row.clauseState == .boundaryPending)
    #expect(row.clauseSlices.map(\.sourceRange) == [try TextUTF16Range(start: 4, end: 6)])
}

@Test
func boundaryRetryReusesExactPublishedTextAtDifferentRawParts() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(
        ["同じ。", "", "同じ。後半"], root: root, sessionID: sessionID
    ))
    let failing = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s03" { throw DecisionResponseError.missingAnswer }
        return try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: failing, scope: .all)
    #expect(await failing.boundaryRequests.map(\.source.segmentID) == ["s01", "s03"])
    #expect(first.pendingBoundarySegments.map(\.segmentID) == ["s03"])
    let originalClause = try requireValue(first.materializedSegments.first?.clauseSlices.first?.reference)

    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let retried = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: Set(first.pendingBoundarySegments), clauses: [])
    )

    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["後半"]])
    let rows = retried.materializedSegments.filter(\.hasRecognizedText)
    #expect(rows.map { $0.clauseSlices.map(\.priority) } == [[.primary], [.primary, .primary]])
    let matchingClause = try requireValue(rows[1].clauseSlices.first?.reference)
    let carriedPayload = try requireValue(try eventObjects(root).first { event in
        event["event_type"] as? String == "content_priority.assigned"
            && event["processing_run_id"] as? String == retried.priorityRunID
            && ((event["payload"] as? [String: Any])?["request"] is NSNull)
    }.flatMap { $0["payload"] as? [String: Any] })
    let carriedAssignments = try requireValue(carriedPayload["assignments"] as? [[String: Any]]).map { assignmentObject in
        try JSONDecoder().decode(
            ClausePriorityAssignment.self,
            from: JSONSerialization.data(withJSONObject: assignmentObject)
        )
    }
    let carriedAssignment = try requireValue(carriedAssignments.first { $0.reference == matchingClause })
    #expect(carriedAssignment.reference == matchingClause)
    guard case .carriedOver(_, _, let sourceClause, _) = carriedAssignment.decision else {
        #expect(Bool(false))
        return
    }
    #expect(sourceClause == originalClause)
}

@Test
func boundaryRetryDoesNotReusePriorityWhenFillerChangesExactText() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(
        ["えー、同じ。", "", "えー、同じ。後半"], root: root, sessionID: sessionID
    ))
    let knownFiller = try TextUTF16Range(start: 0, end: 2)
    let failing = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s03" { throw DecisionResponseError.missingAnswer }
        return try punctuationBoundaries(
            continuing: [], fillerRangesBySegment: ["s01": [knownFiller]]
        )(request)
    }, priority: lowForBackchannel)
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: failing, scope: .all)
    #expect(first.pendingBoundarySegments.map(\.segmentID) == ["s03"])
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
                                            priority: lowForBackchannel)
    let retried = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: Set(first.pendingBoundarySegments), clauses: [])
    )
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["えー、同じ。", "後半"]])
    let rows = retried.materializedSegments.filter(\.hasRecognizedText)
    #expect(rows.map { $0.clauseSlices.map(\.priority) } == [[.primary], [.primary, .primary]])
    #expect(rows[0].clauseSlices[0].reference != rows[1].clauseSlices[0].reference)
}

@Test(arguments: [false, true])
func unpublishedRetryRebuildsFromPublishedAssessmentsWithoutResendingBoundaries(pending: Bool) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(
        ["前。後"], root: root, sessionID: sessionID
    ))
    let initial = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { targets in
        if pending { throw DecisionResponseError.missingAnswer }
        return try lowForBackchannel(targets)
    })
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: initial, scope: .all)
    let writer = try SessionWriter(sessionURL: root)
    try await writer.append(EventDraft(
        eventType: "processing.run.started", sessionID: sessionID, processingRunID: "interrupted_retry",
        payload: ProcessingRunStartedPayload(stage: .contentPriority,
                                             provenance: DecisionRunProvenance.priority(mode: "retry", identity: testDecisionIdentity))
    ))
    // A durable but unpublished answer must not leak into either reuse or retry selection.
    let reference = try requireValue(first.materializedSegments.first?.clauseSlices.first?.reference)
    let unpublishedDecision = try ContentPriorityDecision(
        priority: .lowPriority, confidence: 1, probabilities: ["PRIMARY": 0, "LOW_PRIORITY": 1]
    )
    try await writer.append(EventDraft(
        eventType: ClauseEventType.priorityAssigned, sessionID: sessionID,
        processingRunID: "interrupted_retry",
        payload: try ContentPriorityAssignedPayload(
            assignments: [ClausePriorityAssignment(
                reference: reference, priority: .lowPriority, needsRetry: false,
                decision: .classified(requestID: "unpublished", answerKey: "u0001", response: unpublishedDecision)
            )],
            request: DecisionRequestRecord(requestID: "unpublished", inputTokens: testInputTokens)
        )
    ))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
                                            priority: lowForBackchannel)
    let retried = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider,
        scope: .retry(boundarySegments: [], clauses: Set(first.pendingPriorityClauses))
    )
    #expect(retried.boundaryRunID != first.boundaryRunID)
    #expect(await provider.boundaryRequests.isEmpty)
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == (pending ? [["前。", "後"]] : []))
    #expect(retried.pendingTargets.isEmpty)
    #expect(try readPublished(root: root) == retried.materializedSegments)
    #expect(retried.materializedSegments.first?.clauseSlices.map(\.priority) == [.primary, .primary])
}

@Test
func priorityRetryCannotAppendIntoThePublishedPriorityRun() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["本文"], root: root, sessionID: sessionID))
    let failing = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
                                           priority: { _ in throw DecisionResponseError.missingAnswer })
    let first = try await buildAndPublish(root: root, sessionID: sessionID, provider: failing, scope: .all)
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    await #expect(throws: DecisionEnrichmentError.invalidPriorityRun) {
        try await buildAndPublish(root: root, sessionID: sessionID, provider: provider,
            scope: .retry(boundarySegments: [], clauses: Set(first.pendingPriorityClauses)),
            boundaryRunID: first.boundaryRunID, priorityRunID: first.priorityRunID)
    }
    #expect(await provider.priorityRequests.isEmpty)
    #expect(try readPublished(root: root) == first.materializedSegments)
}

@Test(arguments: [" 同じ。", "同じ。 ", "同じ！"])
func liveReuseDoesNotTrimWhitespaceOrNormalizePunctuation(_ finalText: String) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript([finalText], root: root, sessionID: sessionID))
    try await writeLiveRun(root: root, sessionID: sessionID, texts: ["同じ。"],
                           fillerRangesByIndex: [:], results: [(0, .lowPriority)], complete: false)
    let reusable = try EventLogTranscriptReader().liveContentPriorityDecisions(
        from: Data(contentsOf: root.appending(path: "events.jsonl")),
        modelRevision: testDecisionIdentity.modelRevision
    )
    let provider = ScriptedDecisionProvider(boundary: { request in
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.1) }),
            continuationProbability: nil, fillerRanges: [], inputTokens: testInputTokens
        )
    }, priority: lowForBackchannel)
    let result = try await buildAndPublish(
        root: root, sessionID: sessionID, provider: provider, scope: .all, reusable: reusable
    )
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [[finalText]])
    #expect(result.materializedSegments.first?.clauseSlices.map(\.priority) == [.primary])
    #expect(try readPublished(root: root) == result.materializedSegments)
}

private struct FixedResponseDecisionProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.99) }),
            continuationProbability: request.next.map { _ in 0.01 },
            fillerRanges: [], inputTokens: 11
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decisions = try Dictionary(uniqueKeysWithValues: targets.map { target in
            (target.key, try ContentPriorityDecision(
                priority: .primary, confidence: 0.98,
                probabilities: ["PRIMARY": 0.99, "LOW_PRIORITY": 0.01]
            ))
        })
        return PriorityBatchResponse(decisions: decisions, inputTokens: 17)
    }
}
