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
