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
