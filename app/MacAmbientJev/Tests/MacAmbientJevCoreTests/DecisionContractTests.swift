import Foundation
import Testing
@testable import MacAmbientJevCore

/// The confidence the tagger derives for probabilities 0.8 and 0.7: `2 * max - 1`.
private let confidenceFor08: Double = 2 * 0.8 - 1
private let confidenceFor07: Double = 2 * 0.7 - 1
private let lowWithinSumTolerance: Double = 0.2 + 9e-6
private let lowBelowSumTolerance: Double = 0.2 - 9e-6

private func contractSource(_ segment: String, seq: UInt64) throws -> SegmentTextReference {
    try SegmentTextReference(segmentationRunID: "private-segmentation", segmentID: segment, asrRunID: "private-asr", asrEventSeq: seq)
}

@Test
func sharedCodableTypesAndCandidateCoverageRejectInvalidData() throws {
    let source = try contractSource("one", seq: 1)
    #expect(try JSONDecoder().decode(SegmentTextReference.self, from: JSONEncoder().encode(source)) == source)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(SegmentTextReference.self, from: Data(#"{"segmentation_run_id":" ","segment_id":"s","asr_run_id":"a","asr_event_seq":1}"#.utf8)) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ClauseBoundaryCandidate.self, from: Data(#"{"id":"b0000","offset_utf16":1}"#.utf8)) }
    #expect(throws: (any Error).self) { try JSONDecoder().decode(DecisionRequestRecord.self, from: Data(#"{"request_id":"decisionreq_1","input_tokens":-1}"#.utf8)) }
    #expect(throws: (any Error).self) { try ContentPriorityDecision(priority: .primary, confidence: .nan, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]) }
    #expect(throws: (any Error).self) { try ContentPriorityDecision(priority: .primary, confidence: 1, probabilities: ["PRIMARY": .infinity, "LOW_PRIORITY": 0]) }
    #expect(throws: (any Error).self) { try NextSegmentHead(source: source, text: String(repeating: "😀", count: 61)) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "😀。後", candidates: [.init(id: "b0001", offsetUTF16: 2)], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [.init(id: "b0002", offsetUTF16: 2)], next: nil) }
    #expect(throws: (any Error).self) { try ClauseBoundaryRequest(source: source, text: "前。後", candidates: [.init(id: "b0001", offsetUTF16: 2), .init(id: "b0001", offsetUTF16: 2)], next: nil) }
}

@Test(arguments: [(0.5.nextDown, false), (0.5, false), (0.5.nextUp, true)])
func boundaryPolicyUsesStrictThreshold(_ probability: Double, _ expected: Bool) {
    #expect(ClauseBoundaryPolicy.acceptsBoundary(probability) == expected)
    #expect(ClauseBoundaryPolicy.acceptsContinuation(probability) == expected)
}

@Test
func codableProbabilityAndNextHeadValidationCannotBeBypassed() throws {
    let decision = try ContentPriorityDecision(priority: .primary, confidence: 1, probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0])
    #expect(try JSONDecoder().decode(ContentPriorityDecision.self, from: JSONEncoder().encode(decision)) == decision)
    let encoded = try JSONEncoder().encode(decision)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["confidence"] = -1
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ContentPriorityDecision.self, from: invalid) }
    let source = try contractSource("one", seq: 1)
    let head = try NextSegmentHead(source: source, text: "次")
    var headObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(head)) as? [String: Any])
    headObject["text"] = String(repeating: "👩🏽‍💻", count: 61)
    let invalidHead = try JSONSerialization.data(withJSONObject: headObject)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(NextSegmentHead.self, from: invalidHead) }
    #expect(throws: (any Error).self) { try DecisionModelIdentity(backend: "test-backend", model: " ", modelRevision: String(repeating: "0", count: 64)) }
    #expect(throws: (any Error).self) { try DecisionModelIdentity(backend: " ", model: "m", modelRevision: String(repeating: "0", count: 64)) }
    #expect(throws: (any Error).self) { try DecisionRequestRecord(requestID: "decisionreq_1", inputTokens: -1) }
}

@Test(arguments: [
    (0.99, 0.01, 0.98, ContentPriority.lowPriority),
    (0.01, 0.01, 0.0, ContentPriority.primary),
    (0.8, 0.8, 0.6, ContentPriority.primary),
    (0.5, 0.5, 0.95, ContentPriority.lowPriority),
    (0.8, 0.2, 0.616, ContentPriority.primary),
    (0.499, 0.501, 0.002, ContentPriority.primary),
    (-Double.leastNonzeroMagnitude, 1.0, 1.0, ContentPriority.lowPriority),
    (Double(1).nextUp, 0.0, 1.0, ContentPriority.primary),
    (0.8, 0.189, 0.6, ContentPriority.primary),
    (0.8, 0.19, confidenceFor08, ContentPriority.primary),
    (0.8, 0.2, 0.6, ContentPriority.primary),
    (0.8, 0.2, confidenceFor08.nextUp, ContentPriority.primary)
])
func inconsistentPriorityDecisionIsRejectedByConstructionAndDecoding(
    _ primary: Double, _ low: Double, _ confidence: Double, _ priority: ContentPriority
) throws {
    let probabilities = ["PRIMARY": primary, "LOW_PRIORITY": low]
    #expect(throws: ClauseValidationError.invalidProbability) {
        try ContentPriorityDecision(priority: priority, confidence: confidence, probabilities: probabilities)
    }
    let stored: [String: Any] = ["priority": priority.rawValue, "confidence": confidence, "probabilities": probabilities]
    let data = try JSONSerialization.data(withJSONObject: stored)
    #expect(throws: ClauseValidationError.invalidProbability) {
        try JSONDecoder().decode(ContentPriorityDecision.self, from: data)
    }
}

@Test(arguments: [
    (0.5, 0.5, 0.0, ContentPriority.primary),
    (0.5, 0.5, 0.0, ContentPriority.lowPriority),
    (1.0, 0.0, 1.0, ContentPriority.primary),
    (0.0, 1.0, 1.0, ContentPriority.lowPriority),
    (0.8, 0.2, confidenceFor08, ContentPriority.primary),
    (0.8, lowWithinSumTolerance, confidenceFor08, ContentPriority.primary),
    (0.8, lowBelowSumTolerance, confidenceFor08, ContentPriority.primary),
    (0.3, 0.7, confidenceFor07, ContentPriority.lowPriority)
])
func priorityDecisionTiesTaggerSumToleranceAndClosedBoundariesPreserveReportedValues(
    _ primary: Double, _ low: Double, _ confidence: Double, _ priority: ContentPriority
) throws {
    let decision = try ContentPriorityDecision(
        priority: priority, confidence: confidence, probabilities: ["PRIMARY": primary, "LOW_PRIORITY": low]
    )
    #expect(decision.priority == priority)
    #expect(decision.confidence == confidence)
    #expect(decision.probabilities == ["PRIMARY": primary, "LOW_PRIORITY": low])
}

@Test(arguments: [(0.99, 0.01, 0.98), (0.01, 0.01, 0.0), (0.5, 0.5, 0.95)])
func invalidPriorityDecisionLeavesDurablePriorityPendingWithoutRetry(
    _ primary: Double, _ low: Double, _ confidence: Double
) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["本文"], root: root, sessionID: sessionID))
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: { targets in
            let decision = try ContentPriorityDecision(
                priority: .lowPriority, confidence: confidence, probabilities: ["PRIMARY": primary, "LOW_PRIORITY": low]
            )
            return PriorityBatchResponse(decisions: [targets[0].key: decision], inputTokens: testInputTokens)
        }
    )
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(root: root, sessionID: sessionID, provider: provider, scope: .all, counter: counter)
    #expect(result.pendingPriorityClauses.count == 1)
    let published = try readPublished(root: root)
    #expect(published.first?.clauseState == .priorityPending)
    #expect(published.first?.clauseSlices.first?.priority == nil)
    #expect(published.first?.clauseSlices.first?.needsRetry == true)
    #expect(await provider.boundaryRequests.count == 1)
    let boundaryRequest = await provider.boundaryRequests.first
    #expect(boundaryRequest?.candidates.isEmpty == true)
    #expect(boundaryRequest?.next == nil)
    #expect(await provider.priorityRequests.count == 1)
    let usage = await counter.snapshot()
    #expect(usage.sendCount == 2)
    #expect(usage.inputTokens == testInputTokens)
    #expect(usage.successCount == 1)
    #expect(usage.failureCount == 1)
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.boundaryRequests.successCount == 1)
    #expect(usage.boundaryRequests.inputTokens == testInputTokens)
    #expect(usage.priorityRequests.sendCount == 1)
    #expect(usage.priorityRequests.failureCount == 1)
    #expect(usage.priorityRequests.successCount == 0)
    #expect(usage.priorityRequests.inputTokens == 0)
}
