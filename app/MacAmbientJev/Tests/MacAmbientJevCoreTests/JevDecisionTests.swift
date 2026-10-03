import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MacAmbientJevCore

private struct FailingDecisionProvider: DecisionProvider {
    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
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
    #expect(JevBatchStopReason(error: JevClientError.missingAnswer("content_priority")) == nil)
    #expect(JevBatchStopReason(error: JevClientError.invalidChoice("content_priority")) == nil)
}

private actor MockJevTransport: JevHTTPTransport {
    private var request: URLRequest?
    private let data: Data
    private let statusCode: Int

    init(json: String, statusCode: Int = 200) {
        self.data = Data(json.utf8)
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: try #require(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func capturedRequest() -> URLRequest? {
        request
    }
}

@Test
func jevPriorityClientSendsOnlyCurrentUtteranceAndChoiceQuestion() async throws {
    let transport = MockJevTransport(json: """
    {
      "model": "jev-1.13.0",
      "answers": {
        "content_priority": {
          "type": "choice",
          "choice": "PRIMARY",
          "confidence": 0.91,
          "probabilities": {"PRIMARY": 0.91, "LOW_PRIORITY": 0.09}
        }
      },
      "usage": {"input_tokens": 42, "output_tokens": 5}
    }
    """)

    let client = JevClient(apiKey: "test-key", transport: transport)
    let decision = try await client.classifyPriority(text: "公開鍵暗号を説明します")

    #expect(decision.priority == .primary)
    #expect(decision.model == "jev-1.13.0")
    #expect(decision.inputTokens == 42)

    let request = try #require(await transport.capturedRequest())
    #expect(request.url == JevClient.endpoint)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

    let body = try #require(request.httpBody)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["state"] as? String == "公開鍵暗号を説明します")
    #expect(object["audio"] == nil)
    #expect(object["speaker_embedding"] == nil)

    let questions = try #require(object["questions"] as? [String: Any])
    let priority = try #require(
        questions["content_priority"] as? [String: Any]
    )
    #expect(priority["type"] as? String == "choice")
}

private func lowPriority(confidence: Double) -> ContentPriorityDecision {
    ContentPriorityDecision(priority: .lowPriority, confidence: confidence, model: "jev-test", inputTokens: 1)
}

@Test
func confidentLowPriorityDemotesAnyUtterance() {
    #expect(ContentPriorityPolicy.visiblePriority(for: lowPriority(confidence: 0.90)) == .lowPriority)
}

@Test
func lowPriorityBelowThresholdStaysPrimary() {
    #expect(ContentPriorityPolicy.visiblePriority(for: lowPriority(confidence: 0.89)) == .primary)
}

@Test
func confidentPrimaryStaysPrimary() {
    let decision = ContentPriorityDecision(priority: .primary, confidence: 0.99, model: "jev-test", inputTokens: 1)
    #expect(ContentPriorityPolicy.visiblePriority(for: decision) == .primary)
}

private struct LowPriorityDecisionProvider: DecisionProvider {
    let confidence: Double
    let inputTokens: Int

    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        ContentPriorityDecision(
            priority: .lowPriority,
            confidence: confidence,
            model: "jev-test",
            inputTokens: inputTokens
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

    guard case .classified(let decision, let visiblePriority) = result else {
        Issue.record("expected a classification, got \(result)")
        return
    }
    #expect(visiblePriority == .lowPriority)
    #expect(decision.inputTokens == 23)
}

@Test
func usageCounterSeparatesUnreportedTokenUsageFromZeroTokens() async {
    let counter = JevUsageCounter()
    let sessionID = UUID()

    await counter.recordAttempt()
    await counter.recordSuccess(sessionID: sessionID, segmentID: "a", inputTokens: 42)
    await counter.recordAttempt()
    await counter.recordSuccess(sessionID: sessionID, segmentID: "b", inputTokens: 0)
    await counter.recordAttempt()
    await counter.recordSuccess(sessionID: sessionID, segmentID: "c", inputTokens: nil)
    await counter.recordAttempt()
    await counter.recordFailure(sessionID: sessionID, segmentID: "d")

    #expect(await counter.snapshot() == JevUsageSnapshot(
        sendCount: 4,
        reportedInputTokens: 42,
        successCount: 3,
        unreportedTokenSuccessCount: 1,
        failureCount: 1,
        retryPendingCount: 1
    ))
}

private actor RecoveringDecisionProvider: DecisionProvider {
    private var offline = true

    func reconnect() { offline = false }

    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        if offline { throw URLError(.notConnectedToInternet) }
        return ContentPriorityDecision(priority: .primary, confidence: 1, model: "jev-test", inputTokens: nil)
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
                text: "同じ重要な発話"
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
    ).process(existingEvents: events, activeRuns: runs, scope: .all)
    #expect(initial.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 1)

    let stillOffline = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-still-offline",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(
        existingEvents: events,
        activeRuns: runs,
        scope: .retry(["seg-1"])
    )
    #expect(stillOffline.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 1)

    await provider.reconnect()
    let retry = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-retry",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(
        existingEvents: events,
        activeRuns: runs,
        scope: .retry(["seg-1"])
    )
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
        ).process(
            existingEvents: previous?.result.events ?? retryEvents(segmentIDs: ["seg-1", "seg-2"]),
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", contentPriority: previous?.runID),
            scope: scope
        )
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
