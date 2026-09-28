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
    public let providerUnavailable: Bool

    public init(
        visiblePriority: ContentPriority,
        needsRetry: Bool,
        decision: ContentPriorityDecision?,
        providerUnavailable: Bool = false
    ) {
        self.visiblePriority = visiblePriority
        self.needsRetry = needsRetry
        self.decision = decision
        self.providerUnavailable = providerUnavailable
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
    private enum PendingRequest: Hashable {
        case priority(String)
        case sceneCue(String)
    }

    private let provider: any DecisionProvider
    private let policy: ContentPriorityPolicy
    private let usageCounter: JevUsageCounter?
    private var pendingRetries: Set<PendingRequest> = []

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
            await recordSuccess(.priority(text), inputTokens: decision.inputTokens)

            return ProvisionalPriorityDecision(
                visiblePriority: policy.apply(
                    providerDecision: decision,
                    text: text
                ),
                needsRetry: false,
                decision: decision
            )
        } catch {
            await recordFailure(.priority(text))

            return ProvisionalPriorityDecision(
                visiblePriority: .primary,
                needsRetry: true,
                decision: nil,
                providerUnavailable: Self.isProviderUnavailable(error)
            )
        }
    }

    public func deferClassification(text: String) async -> ProvisionalPriorityDecision {
        if pendingRetries.insert(.priority(text)).inserted {
            await usageCounter?.recordRetryPending()
        }

        return ProvisionalPriorityDecision(
            visiblePriority: .primary,
            needsRetry: true,
            decision: nil,
            providerUnavailable: true
        )
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
            await recordSuccess(.sceneCue(currentText), inputTokens: decision.inputTokens)

            return ProvisionalSceneDecision(
                cue: decision.cue,
                needsRetry: false,
                decision: decision
            )
        } catch {
            await recordFailure(.sceneCue(currentText))

            return ProvisionalSceneDecision(
                cue: .none,
                needsRetry: true,
                decision: nil
            )
        }
    }

    private func recordSuccess(_ request: PendingRequest, inputTokens: Int?) async {
        let wasPending = pendingRetries.remove(request) != nil
        guard let usageCounter else { return }
        await usageCounter.recordSuccess(inputTokens: inputTokens)
        if wasPending {
            await usageCounter.resolveRetry()
        }
    }

    private func recordFailure(_ request: PendingRequest) async {
        let isNewPending = pendingRetries.insert(request).inserted
        await usageCounter?.recordFailure(retryPending: isNewPending)
    }

    private static func isProviderUnavailable(_ error: any Error) -> Bool {
        switch error {
        case JevClientError.httpStatus(let status):
            return status == 429 || status >= 500
        case JevClientError.invalidResponse, is URLError:
            return true
        default:
            return false
        }
    }
}
