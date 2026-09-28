import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FailingDecisionProvider: DecisionProvider {
    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        throw URLError(.notConnectedToInternet)
    }

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        throw URLError(.notConnectedToInternet)
    }
}

@Test
func jevFailureLeavesSegmentPrimaryAndRetryable() async {
    let coordinator = JevDecisionCoordinator(
        provider: FailingDecisionProvider()
    )

    let result = await coordinator.classify(text: "えー")

    #expect(result.visiblePriority == .primary)
    #expect(result.needsRetry)
    #expect(result.decision == nil)
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

@Test
func jevSceneClientLimitsContextToPreviousThreeUtterances() async throws {
    let transport = MockJevTransport(json: """
    {
      "model": "jev-1.13.0",
      "answers": {
        "scene_cue": {
          "type": "choice",
          "choice": "discussion_start",
          "confidence": 0.84,
          "probabilities": {
            "discussion_start": 0.84,
            "discussion_end": 0.02,
            "none": 0.14
          }
        }
      },
      "usage": {"input_tokens": 55, "output_tokens": 7}
    }
    """)

    let client = JevClient(apiKey: "test-key", transport: transport)
    let decision = try await client.classifySceneCue(
        currentText: "では質問を受けます",
        previousTexts: ["a", "b", "c", "d"],
        currentScene: .lecture
    )
    #expect(decision.cue == .discussionStart)

    let request = try #require(await transport.capturedRequest())
    let body = try #require(request.httpBody)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let state = try #require(object["state"] as? [String: Any])
    let previous = try #require(state["previous_texts"] as? [String])
    #expect(previous == ["b", "c", "d"])
    #expect(state["current_scene"] as? String == "lecture")
}

@Test
func mixedContentCannotBeDemotedByPolicy() {
    let policy = ContentPriorityPolicy()
    let result = policy.apply(
        providerDecision: ContentPriorityDecision(
            priority: .lowPriority,
            confidence: 0.91
        ),
        text: "えー、RSAでは公開鍵を使います"
    )

    #expect(result == .primary)
}

@Test
func confidentFillerOnlyUtteranceCanBeDemotedByPolicy() {
    let policy = ContentPriorityPolicy()
    let result = policy.apply(
        providerDecision: ContentPriorityDecision(
            priority: .lowPriority,
            confidence: 0.96
        ),
        text: "えー"
    )

    #expect(result == .lowPriority)
}

@Test
func lowConfidenceDemotionFallsBackToPrimary() {
    let policy = ContentPriorityPolicy(minimumDemotionConfidence: 0.90)
    let result = policy.apply(
        providerDecision: ContentPriorityDecision(
            priority: .lowPriority,
            confidence: 0.89
        ),
        text: "えー"
    )

    #expect(result == .primary)
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

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        SemanticSceneDecision(
            cue: .none,
            confidence: 1,
            model: "jev-test",
            inputTokens: 1
        )
    }
}

@Test
func coordinatorAppliesMixedContentGuardBeforeVisibleDemotion() async {
    let coordinator = JevDecisionCoordinator(
        provider: LowPriorityDecisionProvider(
            confidence: 0.99,
            inputTokens: 23
        )
    )

    let result = await coordinator.classify(
        text: "えー、RSAでは公開鍵を使います"
    )

    #expect(result.visiblePriority == .primary)
    #expect(result.decision?.priority == .lowPriority)
    #expect(!result.needsRetry)
}

@Test
func usageCounterTracksSuccessFailureAndRetryBacklog() async {
    let counter = JevUsageCounter()

    await counter.recordAttempt()
    await counter.recordSuccess(inputTokens: 42)
    await counter.recordAttempt()
    await counter.recordFailure(retryPending: true)

    let snapshot = await counter.snapshot()

    #expect(snapshot.sendCount == 2)
    #expect(snapshot.estimatedInputTokens == 42)
    #expect(snapshot.successCount == 1)
    #expect(snapshot.failureCount == 1)
    #expect(snapshot.retryPendingCount == 1)
}

private actor RecoveringDecisionProvider: DecisionProvider {
    private var offline = true

    func reconnect() { offline = false }

    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        if offline { throw URLError(.notConnectedToInternet) }
        return ContentPriorityDecision(priority: .primary, confidence: 1)
    }

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        SemanticSceneDecision(cue: .none, confidence: 1)
    }
}

@Test
func directClassificationStillResolvesItsRetry() async {
    let provider = RecoveringDecisionProvider()
    let counter = JevUsageCounter()
    let coordinator = JevDecisionCoordinator(provider: provider, usageCounter: counter)

    let failed = await coordinator.classify(text: "重要な発話")
    #expect(failed.needsRetry)
    #expect(await counter.snapshot().retryPendingCount == 1)

    await provider.reconnect()
    let recovered = await coordinator.classify(text: "重要な発話")
    #expect(!recovered.needsRetry)
    #expect(await counter.snapshot().retryPendingCount == 0)
}

@Test
func identicalTextFailuresStayPendingBySegmentAcrossCoordinators() async {
    let counter = JevUsageCounter()
    let failing = JevDecisionCoordinator(
        provider: FailingDecisionProvider(),
        usageCounter: counter
    )
    let text = "同じ重要な発話"

    #expect(await failing.classify(text: text, segmentID: "seg-1").needsRetry)
    #expect(await failing.classify(text: text, segmentID: "seg-2").needsRetry)
    #expect(await failing.classify(text: text, segmentID: "seg-1").needsRetry)
    #expect(await counter.snapshot().retryPendingCount == 2)

    let recovered = JevDecisionCoordinator(
        provider: LowPriorityDecisionProvider(confidence: 0.99, inputTokens: 23),
        usageCounter: counter
    )
    #expect(!(await recovered.classify(text: text, segmentID: "seg-1")).needsRetry)
    #expect(await counter.snapshot().retryPendingCount == 1)
    #expect(!(await recovered.classify(text: text, segmentID: "seg-2")).needsRetry)
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
    ).process(existingEvents: events, activeRuns: runs)
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
        retryOnlySegmentIDs: ["seg-1"]
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
        retryOnlySegmentIDs: ["seg-1"]
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
    let events = retryEvents(segmentIDs: ["seg-1", "seg-2"])
    let runs = ActiveRuns(segmentation: "seg", asr: "asr")

    let initial = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-initial",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(existingEvents: events, activeRuns: runs)
    #expect(Set(initial.retryPendingSegmentIDs) == ["seg-1", "seg-2"])
    #expect(await counter.snapshot().retryPendingCount == 2)

    let stillOffline = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-still-offline",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(
        existingEvents: events,
        activeRuns: runs,
        retryOnlySegmentIDs: ["seg-1"]
    )
    #expect(stillOffline.retryPendingSegmentIDs == ["seg-1"])
    #expect(await counter.snapshot().retryPendingCount == 2)

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
        retryOnlySegmentIDs: ["seg-1"]
    )
    #expect(retry.retryPendingSegmentIDs.isEmpty)
    #expect(await counter.snapshot().retryPendingCount == 1)

    let final = try await JevEnrichmentCoordinator(
        sessionID: sessionID,
        runID: "priority-final",
        writer: writer,
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    ).process(
        existingEvents: events,
        activeRuns: runs,
        retryOnlySegmentIDs: ["seg-2"]
    )
    #expect(final.retryPendingSegmentIDs.isEmpty)
    let snapshot = await counter.snapshot()
    #expect(snapshot.retryPendingCount == 0)
    #expect(snapshot.sendCount == 4)
    #expect(snapshot.failureCount == 2)
    #expect(snapshot.successCount == 2)
}
