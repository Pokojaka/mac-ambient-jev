import Foundation
import Testing
@testable import MacAmbientJevCore

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
func malformedFillerRangesFailTheBoundaryRequestWithoutSuccessUsage() async throws {
    let provider = ScriptedDecisionProvider(boundary: { request in
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.9) }),
            continuationProbability: nil,
            fillerRanges: [try TextUTF16Range(start: 0, end: 3)],
            inputTokens: testInputTokens
        )
    }, priority: lowForBackchannel)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let source = try SegmentTextReference(
        segmentationRunID: "seg", segmentID: "s01", asrRunID: "asr", asrEventSeq: 1
    )

    let state = try await ClauseBoundaryStep.assess(source: source, text: "本文", next: nil, decisions: decisions)

    guard case .pending(.requestFailed, _) = state else {
        Issue.record("a malformed filler range must leave the source pending")
        return
    }
    let usage = await counter.snapshot()
    #expect(usage.boundaryRequests.sendCount == 1)
    #expect(usage.boundaryRequests.successCount == 0)
    #expect(usage.boundaryRequests.failureCount == 1)
    #expect(usage.boundaryRequests.inputTokens == 0)
}
