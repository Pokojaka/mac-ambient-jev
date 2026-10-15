import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FailingDecisionProvider: DecisionProvider {
    let error: any Error

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw error
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        throw error
    }
}

@Test(arguments: [
    DecisionResponseError.missingAnswer as any Error,
    ClauseTaggerEncodingError.missingJunction,
    ClauseValidationError.invalidProbability
])
func aFailedRequestReportsItsError(error: any Error) async {
    let coordinator = DecisionCoordinator(
        provider: FailingDecisionProvider(error: error),
        identity: testDecisionIdentity,
        usageCounter: DecisionUsageCounter()
    )

    let result = await coordinator.classifyPriorities([PriorityTextTarget(key: "u0001", text: "えー")])

    guard case .failed(let message) = result else {
        Issue.record("expected a failure, got \(result)")
        return
    }
    #expect(message == error.localizedDescription)
}

/// A LOW_PRIORITY decision as the tagger derives it from its LOW_PRIORITY probability.
private func lowPriority(probability: Double) throws -> ContentPriorityDecision {
    try ContentPriorityDecision(
        priority: .lowPriority,
        confidence: 2 * probability - 1,
        probabilities: ["PRIMARY": 1 - probability, "LOW_PRIORITY": probability]
    )
}

// 2 * 0.95 - 1 is 0.8999999999999999 in Double, so 0.95 itself stays below the 0.90 threshold.
@Test(arguments: [Double(0.95).nextUp, 0.96])
func confidentLowPriorityDemotesAnyUtterance(_ probability: Double) throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(probability: probability)) == .lowPriority)
}

@Test(arguments: [0.95, 0.945])
func lowPriorityBelowThresholdStaysPrimary(_ probability: Double) throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(probability: probability)) == .primary)
}

@Test
func confidentPrimaryStaysPrimary() throws {
    let decision = try ContentPriorityDecision(
        priority: .primary,
        confidence: 0.99,
        probabilities: ["PRIMARY": 0.995, "LOW_PRIORITY": 0.005]
    )
    #expect(ContentPriorityPolicy.visiblePriority(for: decision) == .primary)
}

private func boundarySource(_ id: String, _ seq: UInt64) throws -> SegmentTextReference {
    try SegmentTextReference(segmentationRunID: "seg", segmentID: id, asrRunID: "asr", asrEventSeq: seq)
}

@Test
func oneBoundaryRequestCarriesEveryCandidateAndTheContinuationAndCountsOnce() async throws {
    let counter = DecisionUsageCounter()
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: ["a"], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let coordinator = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let request = try ClauseBoundaryRequest(
        source: boundarySource("a", 1), text: "一。二、三。四",
        next: NextSegmentHead(source: boundarySource("b", 2), text: "次の区間")
    )

    guard case .answered(let response, let record) = await coordinator.assessBoundaries(request) else {
        Issue.record("expected an answer")
        return
    }
    #expect(response.probabilities == ["b0001": 0.9, "b0002": 0.1, "b0003": 0.9])
    #expect(response.continuationProbability == 0.9)
    #expect(record.inputTokens == testInputTokens)
    #expect(await provider.boundaryRequests.count == 1)
    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 1)
    #expect(snapshot.boundaryRequests.successCount == 1)
    #expect(snapshot.boundaryRequests.inputTokens == 10)
    #expect(snapshot.priorityRequests.sendCount == 0)
}

@Test
func terminalCandidateFreeBoundaryRequestIsSentAndCountedOnce() async throws {
    let counter = DecisionUsageCounter()
    let provider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: lowForBackchannel
    )
    let coordinator = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let source = try boundarySource("a", 1)

    guard case .assessed(let assessment) = try await ClauseBoundaryStep.assess(
        source: source, text: "本文", next: nil, decisions: coordinator
    ) else {
        Issue.record("expected an assessed terminal boundary without candidates")
        return
    }
    #expect(assessment.source == source)
    #expect(assessment.candidates.isEmpty)
    #expect(assessment.probabilities.isEmpty)
    #expect(assessment.continuationProbability == nil)
    #expect(assessment.fillerRanges.isEmpty)
    #expect(assessment.request?.inputTokens == testInputTokens)
    let requests = await provider.boundaryRequests
    #expect(requests.count == 1)
    #expect(requests.first?.source == source)
    #expect(requests.first?.candidates.isEmpty == true)
    #expect(requests.first?.next == nil)
    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 1)
    #expect(snapshot.boundaryRequests.successCount == 1)
    #expect(snapshot.boundaryRequests.inputTokens == testInputTokens)
    #expect(snapshot.priorityRequests.sendCount == 0)
}

@Test
func fortyPriorityTargetsAreOneRequestWithOneTokenReport() async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(
        provider: ScriptedDecisionProvider(
            boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
            priority: lowForBackchannel
        ),
        identity: testDecisionIdentity,
        usageCounter: counter
    )
    let targets = ClausePriorityBatch.targets(texts: (1...40).map { "節\($0)" })

    guard case .answered(let response, _) = await coordinator.classifyPriorities(targets) else {
        Issue.record("expected an answer")
        return
    }
    #expect(response.decisions.count == 40)
    #expect(targets.first?.key == "u0001")
    #expect(targets.last?.key == "u0040")
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.inputTokens == 10)
}

private struct MismatchedPriorityKeysProvider: DecisionProvider {
    let keys: [String]

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: [:], continuationProbability: nil, fillerRanges: [], inputTokens: testInputTokens
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decision = try ContentPriorityDecision(priority: .primary, confidence: 0.9, probabilities: ["PRIMARY": 0.95, "LOW_PRIORITY": 0.05])
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: keys.map { ($0, decision) }),
            inputTokens: testInputTokens
        )
    }
}

@Test(arguments: [[], ["u0001"], ["u0001", "u0002", "u0003"]])
func mismatchedAnswerKeysFailTheWholeRequestBeforeSuccessAccounting(keys: [String]) async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(provider: MismatchedPriorityKeysProvider(keys: keys), identity: testDecisionIdentity, usageCounter: counter)

    let result = await coordinator.classifyPriorities(ClausePriorityBatch.targets(texts: ["一", "二"]))

    guard case .failed = result else {
        Issue.record("expected a failure")
        return
    }
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 1)
}

@Test
func boundaryAnswerMustCoverExactlyTheQuestionsSent() async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(provider: MismatchedPriorityKeysProvider(keys: []), identity: testDecisionIdentity, usageCounter: counter)
    let request = try ClauseBoundaryRequest(source: boundarySource("a", 1), text: "一。二", next: nil)

    guard case .failed = await coordinator.assessBoundaries(request) else {
        Issue.record("a response without the candidate must fail")
        return
    }
    #expect(await counter.snapshot().boundaryRequests.failureCount == 1)
}

@Test
func usageCounterSeparatesPurposesAndCountsTokensOfSuccessesOnly() async {
    let counter = DecisionUsageCounter()

    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: 42)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 0)
    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: 5)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordFailure(purpose: .priority)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 3)

    #expect(await counter.snapshot() == DecisionUsageSnapshot(
        sendCount: 5,
        inputTokens: 50,
        successCount: 4,
        failureCount: 1,
        pendingBoundarySegmentCount: 0,
        pendingPriorityClauseCount: 0,
        boundaryRequests: DecisionRequestUsageSnapshot(sendCount: 2, inputTokens: 47, successCount: 2, failureCount: 0),
        priorityRequests: DecisionRequestUsageSnapshot(sendCount: 3, inputTokens: 3, successCount: 2, failureCount: 1)
    ))
}

@Test
func pendingTargetsAreKeptPerSessionAndKindAndClearWithoutChangingRequests() async throws {
    let counter = DecisionUsageCounter()
    let first = UUID(), second = UUID()
    let segment = try boundarySource("a", 1)
    let clause = try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_0")

    await counter.recordDeferred(sessionID: first, targets: [.boundary(segment), .priority(clause)])
    await counter.recordDeferred(sessionID: second, targets: [.boundary(segment)])
    await counter.recordDeferred(sessionID: first, targets: [.boundary(segment)])
    var snapshot = await counter.snapshot()
    #expect(snapshot.pendingBoundarySegmentCount == 2)
    #expect(snapshot.pendingPriorityClauseCount == 1)

    await counter.clearDeferred(sessionID: first, targets: [.boundary(segment), .priority(clause)])
    snapshot = await counter.snapshot()
    #expect(snapshot.pendingBoundarySegmentCount == 1)
    #expect(snapshot.pendingPriorityClauseCount == 0)
    #expect(snapshot.sendCount == 0)
}
