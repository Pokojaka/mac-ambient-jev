import Foundation

public struct ContentPriorityDecision: Sendable, Equatable {
    public let priority: ContentPriority
    public let confidence: Double
    public let model: String?
    public let inputTokens: Int?

    public init(
        priority: ContentPriority,
        confidence: Double,
        model: String? = nil,
        inputTokens: Int? = nil
    ) {
        self.priority = priority
        self.confidence = confidence
        self.model = model
        self.inputTokens = inputTokens
    }
}

public enum SemanticSceneCue: String, Codable, Sendable, Equatable {
    case discussionStart = "discussion_start"
    case discussionEnd = "discussion_end"
    case none
}

public struct SemanticSceneDecision: Sendable, Equatable {
    public let cue: SemanticSceneCue
    public let confidence: Double
    public let model: String?
    public let inputTokens: Int?

    public init(
        cue: SemanticSceneCue,
        confidence: Double,
        model: String? = nil,
        inputTokens: Int? = nil
    ) {
        self.cue = cue
        self.confidence = confidence
        self.model = model
        self.inputTokens = inputTokens
    }
}

public protocol DecisionProvider: Sendable {
    func classifyPriority(text: String) async throws -> ContentPriorityDecision

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision
}

public struct ProvisionalPriorityDecision: Sendable, Equatable {
    public let visiblePriority: ContentPriority
    public let needsRetry: Bool
    public let decision: ContentPriorityDecision?

    public init(
        visiblePriority: ContentPriority,
        needsRetry: Bool,
        decision: ContentPriorityDecision?
    ) {
        self.visiblePriority = visiblePriority
        self.needsRetry = needsRetry
        self.decision = decision
    }
}

public actor JevDecisionCoordinator {
    private let provider: any DecisionProvider

    public init(provider: any DecisionProvider) {
        self.provider = provider
    }

    public func classify(text: String) async -> ProvisionalPriorityDecision {
        do {
            let decision = try await provider.classifyPriority(text: text)
            return ProvisionalPriorityDecision(
                visiblePriority: decision.priority,
                needsRetry: false,
                decision: decision
            )
        } catch {
            return ProvisionalPriorityDecision(
                visiblePriority: .primary,
                needsRetry: true,
                decision: nil
            )
        }
    }
}
