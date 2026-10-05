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
    let coordinator = JevDecisionCoordinator(
        provider: FailingDecisionProvider(),
        usageCounter: JevUsageCounter()
    )

    let result = await coordinator.classify(text: "えー", segmentID: "seg-1", sessionID: UUID())

    #expect(result == .failed(stopsBatch: .providerUnavailable))
}

@Test(arguments: [
    (401, JevBatchStopReason.authorizationRejected),
    (403, .authorizationRejected),
    (429, .providerUnavailable),
    (500, .providerUnavailable),
    (503, .providerUnavailable)
] as [(Int, JevBatchStopReason)])
func httpStatusSelectsTheBatchStopReason(status: Int, reason: JevBatchStopReason) {
    #expect(JevBatchStopReason(error: JevClientError.httpStatus(status)) == reason)
}

@Test
func requestSpecificFailuresDoNotStopTheBatch() {
    #expect(JevBatchStopReason(error: JevClientError.httpStatus(400)) == nil)
    #expect(JevBatchStopReason(error: JevClientError.missingAnswer) == nil)
    #expect(JevBatchStopReason(error: JevClientError.invalidChoice) == nil)
    #expect(JevBatchStopReason(error: JevClientError.unexpectedAnswers) == nil)
}

private func lowPriority(confidence: Double) throws -> ContentPriorityDecision {
    try ContentPriorityDecision(
        priority: .lowPriority,
        confidence: confidence,
        probabilities: ["PRIMARY": 0.05, "LOW_PRIORITY": 0.95]
    )
}

@Test
func confidentLowPriorityDemotesAnyUtterance() throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(confidence: 0.90)) == .lowPriority)
}

@Test
func lowPriorityBelowThresholdStaysPrimary() throws {
    #expect(ContentPriorityPolicy.visiblePriority(for: try lowPriority(confidence: 0.89)) == .primary)
}

@Test
func confidentPrimaryStaysPrimary() throws {
    let decision = try ContentPriorityDecision(
        priority: .primary,
        confidence: 0.99,
        probabilities: ["PRIMARY": 0.99, "LOW_PRIORITY": 0.01]
    )
    #expect(ContentPriorityPolicy.visiblePriority(for: decision) == .primary)
}

private struct LowPriorityDecisionProvider: DecisionProvider {
    let confidence: Double
    let inputTokens: Int

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw JevClientError.invalidResponse
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decision = try lowPriority(confidence: confidence)
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            metadata: try JevResponseMetadata(model: "jev-test", inputTokens: inputTokens, outputTokens: nil)
        )
    }

}

@Test
func coordinatorDemotesConfidentNonFillerUtterance() async {
    let coordinator = JevDecisionCoordinator(
        provider: LowPriorityDecisionProvider(confidence: 0.90, inputTokens: 23),
        usageCounter: JevUsageCounter()
    )

    let result = await coordinator.classify(
        text: "えー、RSAでは公開鍵を使います",
        segmentID: "seg-1",
        sessionID: UUID()
    )

    guard case .classified(let decision, let metadata, let visiblePriority) = result else {
        Issue.record("expected a classification, got \(result)")
        return
    }
    #expect(visiblePriority == .lowPriority)
    #expect(decision.priority == .lowPriority)
    #expect(metadata.inputTokens == 23)
}

@Test
func usageCounterSeparatesPurposesAndUnreportedTokensFromZero() async {
    let counter = JevUsageCounter()
    let sessionID = UUID()

    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: 42)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 0)
    await counter.recordAttempt(purpose: .boundary)
    await counter.recordSuccess(purpose: .boundary, inputTokens: nil)
    await counter.recordAttempt(purpose: .priority)
    await counter.recordFailure(purpose: .priority)
    #expect(await counter.snapshot().retryPendingCount == 0)
    await counter.recordDeferred(sessionID: sessionID, segmentID: "d")
    await counter.recordAttempt(purpose: .priority)
    await counter.recordSuccess(purpose: .priority, inputTokens: 3)
    #expect(await counter.snapshot().retryPendingCount == 1)
    await counter.clearDeferred(sessionID: sessionID, segmentIDs: ["d"])

    #expect(await counter.snapshot() == JevUsageSnapshot(
        sendCount: 5,
        reportedInputTokens: 45,
        successCount: 4,
        unreportedTokenSuccessCount: 1,
        failureCount: 1,
        retryPendingCount: 0,
        boundaryRequests: JevRequestUsageSnapshot(
            sendCount: 2, reportedInputTokens: 42, successCount: 2,
            unreportedTokenSuccessCount: 1, failureCount: 0
        ),
        priorityRequests: JevRequestUsageSnapshot(
            sendCount: 3, reportedInputTokens: 3, successCount: 2,
            unreportedTokenSuccessCount: 0, failureCount: 1
        )
    ))
}

private actor RecoveringDecisionProvider: DecisionProvider {
    private var offline = true

    func reconnect() { offline = false }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw JevClientError.invalidResponse
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        if offline { throw URLError(.notConnectedToInternet) }
        let decision = try ContentPriorityDecision(
            priority: .primary, confidence: 1,
            probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            metadata: try JevResponseMetadata(model: "jev-test", inputTokens: nil, outputTokens: nil)
        )
    }

}

@Test
func identicalTextFailuresStayPendingBySegmentAcrossCoordinators() async {
    let counter = JevUsageCounter()
    let failing = JevDecisionCoordinator(
        provider: FailingDecisionProvider(),
        usageCounter: counter
    )
    let text = "同じ重要な発話"
    let sessionID = UUID()

    _ = await failing.classify(text: text, segmentID: "seg-1", sessionID: sessionID)
    _ = await failing.classify(text: text, segmentID: "seg-2", sessionID: sessionID)
    _ = await failing.classify(text: text, segmentID: "seg-1", sessionID: sessionID)
    #expect(await counter.snapshot().retryPendingCount == 2)

    let recovered = JevDecisionCoordinator(
        provider: LowPriorityDecisionProvider(confidence: 0.99, inputTokens: 23),
        usageCounter: counter
    )
    _ = await recovered.classify(text: text, segmentID: "seg-1", sessionID: sessionID)
    #expect(await counter.snapshot().retryPendingCount == 1)
    _ = await recovered.classify(text: text, segmentID: "seg-2", sessionID: sessionID)
    let snapshot = await counter.snapshot()
    #expect(snapshot.retryPendingCount == 0)
    #expect(snapshot.failureCount == 3)
    #expect(snapshot.successCount == 2)
}

private func retryEvents(segmentIDs: [String]) -> [TranscriptEvent] {
    segmentIDs.enumerated().flatMap { index, segmentID -> [TranscriptEvent] in
        [
            .segmentCreated(
                seq: UInt64(index * 2 + 1),
                segmentationRunID: "seg",
                segmentID: segmentID,
                startFrame: Int64(index) * 1_000,
                endFrame: Int64(index + 1) * 1_000
            ),
            .asrCompleted(
                seq: UInt64(index * 2 + 2),
                runID: "asr",
                segmentationRunID: "seg",
                segmentID: segmentID,
                text: "同じ重要な発話",
                detectedLanguage: nil
            )
        ]
    }
}

@Test
func successfulRetryWithFreshCoordinatorClearsPendingUsageCount() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = RecoveringDecisionProvider()
    let counter = JevUsageCounter()
    let writer = try SessionWriter(sessionURL: root)
    let sessionID = UUID()
    let events = retryEvents(segmentIDs: ["seg-1"])
    let runs = ActiveRuns(segmentation: "seg", asr: "asr")

    let initial = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-initial",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(existingEvents: events, activeRuns: runs, scope: .all, reusableDecisions: [:], completeRun: true, onAssignment: nil)
    #expect(initial.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 1)

    let stillOffline = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-still-offline",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(existingEvents: events, activeRuns: runs, scope: .retry(["seg-1"]), reusableDecisions: [:], completeRun: true, onAssignment: nil)
    #expect(stillOffline.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 1)

    await provider.reconnect()
    let retry = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-retry",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(existingEvents: events, activeRuns: runs, scope: .retry(["seg-1"]), reusableDecisions: [:], completeRun: true, onAssignment: nil)
    #expect(retry.retryPendingSegmentIDs.isEmpty)
    #expect(await counter.snapshot().retryPendingCount == 0)

    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 3)
    #expect(snapshot.failureCount == 2)
    #expect(snapshot.successCount == 1)
}

@Test
func identicalTextSegmentsHaveIndependentRetryBacklogs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = RecoveringDecisionProvider()
    let counter = JevUsageCounter()
    let writer = try SessionWriter(sessionURL: root)
    let sessionID = UUID()

    func run(
        _ runID: String,
        after previous: (runID: String, result: JevEnrichmentBatchResult)?,
        scope: JevEnrichmentScope
    ) async throws -> (runID: String, result: JevEnrichmentBatchResult) {
        let result = try await JevEnrichmentCoordinator(
            sessionID: sessionID,
            runID: runID,
            writer: writer,
            decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
            materializer: TranscriptMaterializer(sampleRate: 1_000)
        ).process(existingEvents: previous?.result.events ?? retryEvents(segmentIDs: ["seg-1", "seg-2"]), activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", contentPriority: previous?.runID), scope: scope, reusableDecisions: [:], completeRun: true, onAssignment: nil)
        return (runID, result)
    }

    let initial = try await run("priority-initial", after: nil, scope: .all)
    #expect(Set(initial.result.retryPendingSegmentIDs) == ["seg-1", "seg-2"])
    #expect(await counter.snapshot().retryPendingCount == 2)

    let stillOffline = try await run("priority-still-offline", after: initial, scope: .retry(["seg-1"]))
    #expect(stillOffline.result.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 2)

    await provider.reconnect()
    let retry = try await run("priority-retry", after: stillOffline, scope: .retry(["seg-1"]))
    #expect(retry.result.retryPendingSegmentIDs.isEmpty)
    #expect(await counter.snapshot().retryPendingCount == 1)

    let final = try await run("priority-final", after: retry, scope: .retry(["seg-2"]))
    #expect(final.result.retryPendingSegmentIDs.isEmpty)
    let snapshot = await counter.snapshot()
    #expect(snapshot.retryPendingCount == 0)
    #expect(snapshot.sendCount == 4)
    #expect(snapshot.failureCount == 2)
    #expect(snapshot.successCount == 2)
}

@Test
func lowConfidenceClassificationRetainsTheActualDecisionAndMetadata() async throws {
    let coordinator = JevDecisionCoordinator(
        provider: LowPriorityDecisionProvider(confidence: 0.89, inputTokens: 7),
        usageCounter: JevUsageCounter()
    )
    let result = await coordinator.classify(
        text: "本文", segmentID: "segment", sessionID: UUID()
    )
    guard case .classified(let decision, let metadata, let visiblePriority) = result else {
        Issue.record("expected a classification, got \(result)")
        return
    }
    #expect(decision.priority == .lowPriority)
    #expect(decision.confidence == 0.89)
    #expect(decision.probabilities == ["PRIMARY": 0.05, "LOW_PRIORITY": 0.95])
    #expect(visiblePriority == .primary)
    #expect(metadata == (try JevResponseMetadata(model: "jev-test", inputTokens: 7, outputTokens: nil)))
}

private struct MismatchedPriorityKeysProvider: DecisionProvider {
    let keys: [String]

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        throw JevClientError.invalidResponse
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decision = try lowPriority(confidence: 0.99)
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: keys.map { ($0, decision) }),
            metadata: try JevResponseMetadata(model: "jev-test", inputTokens: 99, outputTokens: nil)
        )
    }
}

@Test(arguments: [[], ["u0002"], ["u0001", "u0002"]] as [[String]])
func mismatchedProviderKeysFailTheWholeRequestBeforeSuccessAccounting(keys: [String]) async {
    let counter = JevUsageCounter()
    let coordinator = JevDecisionCoordinator(
        provider: MismatchedPriorityKeysProvider(keys: keys), usageCounter: counter
    )
    let result = await coordinator.classify(
        text: "本文", segmentID: "segment", sessionID: UUID()
    )
    #expect(result == .failed(stopsBatch: nil))
    let snapshot = await counter.snapshot()
    #expect(snapshot.sendCount == 1)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 1)
    #expect(snapshot.reportedInputTokens == 0)
    #expect(snapshot.unreportedTokenSuccessCount == 0)
    #expect(snapshot.retryPendingCount == 1)
    #expect(snapshot.priorityRequests.failureCount == 1)
    #expect(snapshot.boundaryRequests.sendCount == 0)
}

@Test
func deferredSegmentsRemainIndependentAcrossSessionsAndClearWithoutRequests() async {
    let counter = JevUsageCounter()
    let firstSession = UUID()
    let secondSession = UUID()
    await counter.recordDeferred(sessionID: firstSession, segmentID: "same")
    await counter.recordDeferred(sessionID: firstSession, segmentID: "same")
    await counter.recordDeferred(sessionID: secondSession, segmentID: "same")
    #expect(await counter.snapshot().retryPendingCount == 2)
    await counter.clearDeferred(sessionID: firstSession, segmentIDs: ["same"])
    #expect(await counter.snapshot().retryPendingCount == 1)
    await counter.clearDeferred(sessionID: secondSession, segmentIDs: ["same"])
    let snapshot = await counter.snapshot()
    #expect(snapshot.retryPendingCount == 0)
    #expect(snapshot.sendCount == 0)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 0)
    #expect(snapshot.reportedInputTokens == 0)
}
