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

public struct ProvisionalSceneDecision: Sendable, Equatable {
    public let cue: SemanticSceneCue
    public let needsRetry: Bool
    public let decision: SemanticSceneDecision?

    public init(
        cue: SemanticSceneCue,
        needsRetry: Bool,
        decision: SemanticSceneDecision?
    ) {
        self.cue = cue
        self.needsRetry = needsRetry
        self.decision = decision
    }
}

public struct ContentPriorityPolicy: Sendable {
    public let minimumDemotionConfidence: Double

    private static let fillerOnlyTokens: Set<String> = [
        "えー",
        "ええ",
        "あー",
        "ああ",
        "えっと",
        "えーと",
        "ええと",
        "うーん",
        "んー"
    ]

    public init(minimumDemotionConfidence: Double = 0.90) {
        precondition((0...1).contains(minimumDemotionConfidence))
        self.minimumDemotionConfidence = minimumDemotionConfidence
    }

    public func apply(
        providerDecision: ContentPriorityDecision,
        text: String
    ) -> ContentPriority {
        guard providerDecision.priority == .lowPriority,
              providerDecision.confidence >= minimumDemotionConfidence,
              isFillerOnly(text) else {
            return .primary
        }

        return .lowPriority
    }

    private func isFillerOnly(_ text: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
        let tokens = text
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        return !tokens.isEmpty
            && tokens.allSatisfy(Self.fillerOnlyTokens.contains)
    }
}

public actor JevDecisionCoordinator {
    private let provider: any DecisionProvider
    private let policy: ContentPriorityPolicy
    private let usageCounter: JevUsageCounter?

    public init(
        provider: any DecisionProvider,
        policy: ContentPriorityPolicy = ContentPriorityPolicy(),
        usageCounter: JevUsageCounter? = nil
    ) {
        self.provider = provider
        self.policy = policy
        self.usageCounter = usageCounter
    }

    public func classify(text: String) async -> ProvisionalPriorityDecision {
        if let usageCounter {
            await usageCounter.recordAttempt()
        }

        do {
            let decision = try await provider.classifyPriority(text: text)
            if let usageCounter {
                await usageCounter.recordSuccess(inputTokens: decision.inputTokens)
            }

            return ProvisionalPriorityDecision(
                visiblePriority: policy.apply(
                    providerDecision: decision,
                    text: text
                ),
                needsRetry: false,
                decision: decision
            )
        } catch {
            if let usageCounter {
                await usageCounter.recordFailure(retryPending: true)
            }

            return ProvisionalPriorityDecision(
                visiblePriority: .primary,
                needsRetry: true,
                decision: nil
            )
        }
    }

    public func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async -> ProvisionalSceneDecision {
        if let usageCounter {
            await usageCounter.recordAttempt()
        }

        do {
            let decision = try await provider.classifySceneCue(
                currentText: currentText,
                previousTexts: previousTexts,
                currentScene: currentScene
            )

            if let usageCounter {
                await usageCounter.recordSuccess(inputTokens: decision.inputTokens)
            }

            return ProvisionalSceneDecision(
                cue: decision.cue,
                needsRetry: false,
                decision: decision
            )
        } catch {
            if let usageCounter {
                await usageCounter.recordFailure(retryPending: true)
            }

            return ProvisionalSceneDecision(
                cue: .none,
                needsRetry: true,
                decision: nil
            )
        }
    }
}
