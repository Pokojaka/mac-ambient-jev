import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FailingDecisionProvider: DecisionProvider {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw URLError(.notConnectedToInternet)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        throw URLError(.notConnectedToInternet)
    }
}

@Test
func networkFailureStopsTheBatchAsProviderUnavailable() async {
    let coordinator = DecisionCoordinator(
        provider: FailingDecisionProvider(),
        identity: .jev,
        usageCounter: DecisionUsageCounter()
    )

    let result = await coordinator.classifyPriorities([PriorityTextTarget(key: "u0001", text: "えー")])

    guard case .failed(let stop, _) = result else {
        Issue.record("expected a failure, got \(result)")
        return
    }
    #expect(stop == .providerUnavailable)
}

@Test(arguments: [
    (401, DecisionBatchStopReason.authorizationRejected),
    (403, .authorizationRejected),
    (429, .providerUnavailable),
    (500, .providerUnavailable),
    (503, .providerUnavailable)
] as [(Int, DecisionBatchStopReason)])
func httpStatusSelectsTheBatchStopReason(status: Int, reason: DecisionBatchStopReason) {
    #expect(DecisionBatchStopReason(error: JevClientError.httpStatus(status)) == reason)
}

@Test
func requestSpecificFailuresDoNotStopTheBatch() {
    #expect(DecisionBatchStopReason(error: JevClientError.httpStatus(400)) == nil)
    #expect(DecisionBatchStopReason(error: JevClientError.missingAnswer) == nil)
    #expect(DecisionBatchStopReason(error: JevClientError.invalidChoice) == nil)
    #expect(DecisionBatchStopReason(error: JevClientError.unexpectedAnswers) == nil)
}

private func lowPriority(confidence: Double) throws -> ContentPriorityDecision {
    try ContentPriorityDecision(
        priority: .lowPriority,
        confidence: confidence,
        probabilities: ["PRIMARY": (1 - confidence) / 2, "LOW_PRIORITY": (1 + confidence) / 2]
    )
}

@Test
func confidentLowPriorityDemotesAnyUtterance() throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(confidence: 0.90)) == .lowPriority)
}

@Test(arguments: [Double(0.90).nextDown, 0.89])
func lowPriorityBelowThresholdStaysPrimary(_ confidence: Double) throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(confidence: confidence)) == .primary)
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
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: ["a"]), priority: lowForBackchannel)
    let coordinator = DecisionCoordinator(provider: provider, identity: .jev, usageCounter: counter)
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
    #expect(record.metadata == testMetadata)
    #expect(await provider.boundaryRequests.count == 1)
    let snapshot = await counter.snapshot()
    #expect(snapshot.boundaryRequests.sendCount == 1)
    #expect(snapshot.boundaryRequests.successCount == 1)
    #expect(snapshot.boundaryRequests.reportedInputTokens == 10)
    #expect(snapshot.priorityRequests.sendCount == 0)
}

@Test
func fortyPriorityTargetsAreOneRequestWithOneTokenReport() async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(
        provider: ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: []), priority: lowForBackchannel),
        identity: .jev,
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
    #expect(snapshot.reportedInputTokens == 10)
}

private struct MismatchedPriorityKeysProvider: DecisionProvider {
    let keys: [String]

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(probabilities: [:], continuationProbability: nil, metadata: testMetadata)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decision = try ContentPriorityDecision(priority: .primary, confidence: 0.9, probabilities: ["PRIMARY": 0.95, "LOW_PRIORITY": 0.05])
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: keys.map { ($0, decision) }),
            metadata: testMetadata
        )
    }
}

@Test(arguments: [[], ["u0001"], ["u0001", "u0002", "u0003"]])
func mismatchedAnswerKeysFailTheWholeRequestBeforeSuccessAccounting(keys: [String]) async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(provider: MismatchedPriorityKeysProvider(keys: keys), identity: .jev, usageCounter: counter)

    let result = await coordinator.classifyPriorities(ClausePriorityBatch.targets(texts: ["一", "二"]))

    guard case .failed(let stop, _) = result else {
        Issue.record("expected a failure")
        return
    }
    #expect(stop == nil)
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 1)
}

@Test
func boundaryAnswerMustCoverExactlyTheQuestionsSent() async throws {
    let counter = DecisionUsageCounter()
    let coordinator = DecisionCoordinator(provider: MismatchedPriorityKeysProvider(keys: []), identity: .jev, usageCounter: counter)
    let request = try ClauseBoundaryRequest(source: boundarySource("a", 1), text: "一。二", next: nil)

    guard case .failed(nil, _) = await coordinator.assessBoundaries(request) else {
        Issue.record("a response without the candidate must fail")
        return
    }
    #expect(await counter.snapshot().boundaryRequests.failureCount == 1)
}

@Test
func usageCounterSeparatesPurposesAndUnreportedTokensFromZero() async {
    let counter = DecisionUsageCounter()

    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: 42)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 0)
    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: nil)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordFailure(purpose: .priority)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 3)

    #expect(await counter.snapshot() == DecisionUsageSnapshot(
        sendCount: 5,
        reportedInputTokens: 45,
        successCount: 4,
        unreportedTokenSuccessCount: 1,
        failureCount: 1,
        pendingBoundarySegmentCount: 0,
        pendingPriorityClauseCount: 0,
        boundaryRequests: DecisionRequestUsageSnapshot(
            sendCount: 2, reportedInputTokens: 42, successCount: 2,
            unreportedTokenSuccessCount: 1, failureCount: 0
        ),
        priorityRequests: DecisionRequestUsageSnapshot(
            sendCount: 3, reportedInputTokens: 3, successCount: 2,
            unreportedTokenSuccessCount: 0, failureCount: 1
        )
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
