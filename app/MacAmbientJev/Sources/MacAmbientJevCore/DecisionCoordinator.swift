import Foundation

public enum DecisionResponseError: LocalizedError, Sendable {
    case unexpectedAnswers
    case missingAnswer

    public var errorDescription: String? {
        switch self {
        case .unexpectedAnswers: "判定対象と応答が一致しません"
        case .missingAnswer: "必要な判定結果がありません"
        }
    }
}

/// The outcome of one decision request. A failure leaves only this request's targets pending.
public enum DecisionRequestOutcome<Response: Sendable>: Sendable {
    case answered(Response, DecisionRequestRecord)
    case failed(message: String)
    case cancelled
}

public enum ContentPriorityPolicy {
    public static let minimumDemotionConfidence = 0.90

    public static func visiblePriority(
        for decision: ContentPriorityDecision
    ) -> ContentPriority {
        decision.priority == .lowPriority
            && decision.confidence >= minimumDemotionConfidence
            ? .lowPriority
            : .primary
    }
}

/// Sends one decision request at a time and counts each provider call once, whatever the number of
/// candidates or targets it carries.
public actor DecisionCoordinator {
    private let provider: any DecisionProvider
    private let usageCounter: DecisionUsageCounter
    public nonisolated let identity: DecisionModelIdentity

    public init(
        provider: any DecisionProvider,
        identity: DecisionModelIdentity,
        usageCounter: DecisionUsageCounter
    ) {
        self.provider = provider
        self.identity = identity
        self.usageCounter = usageCounter
    }

    public nonisolated func boundaryProvenance(mode: String) -> RunProvenance {
        DecisionRunProvenance.boundary(mode: mode, identity: identity)
    }

    public nonisolated func priorityProvenance(mode: String) -> RunProvenance {
        DecisionRunProvenance.priority(mode: mode, identity: identity)
    }

    public func assessBoundaries(
        _ request: ClauseBoundaryRequest
    ) async -> DecisionRequestOutcome<ClauseBoundaryResponse> {
        await send(purpose: .boundary) {
            let response = try await self.provider.assessBoundaries(request)
            let requestedIDs = Set(request.candidates.map(\.id))
            let answeredIDs = Set(response.probabilities.keys)
            guard answeredIDs == requestedIDs else {
                throw DecisionResponseError.unexpectedAnswers
            }
            if request.next != nil, response.continuationProbability == nil {
                throw DecisionResponseError.unexpectedAnswers
            }
            if request.next == nil, response.continuationProbability != nil {
                throw DecisionResponseError.unexpectedAnswers
            }
            return (response, response.inputTokens)
        }
    }

    /// `targets` must use the request-local keys `u0001`…; every key must be answered.
    public func classifyPriorities(
        _ targets: [PriorityTextTarget]
    ) async -> DecisionRequestOutcome<PriorityBatchResponse> {
        await send(purpose: .priority) {
            let response = try await self.provider.classifyPriorities(targets)
            let requestedKeys = Set(targets.map(\.key))
            let answeredKeys = Set(response.decisions.keys)
            guard answeredKeys == requestedKeys else {
                throw DecisionResponseError.unexpectedAnswers
            }
            return (response, response.inputTokens)
        }
    }

    private func send<Response: Sendable>(
        purpose: DecisionRequestPurpose,
        _ request: @Sendable () async throws -> (Response, inputTokens: Int)
    ) async -> DecisionRequestOutcome<Response> {
        await usageCounter.recordAttempt(purpose: purpose)
        do {
            let (response, inputTokens) = try await request()
            try Task.checkCancellation()
            let record = try DecisionRequestRecord(
                requestID: "decisionreq_\(UUID().uuidString.lowercased())", inputTokens: inputTokens
            )
            await usageCounter.recordSuccess(purpose: purpose, inputTokens: inputTokens)
            return .answered(response, record)
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .cancelled
            }
            await usageCounter.recordFailure(purpose: purpose)
            return .failed(message: error.localizedDescription)
        }
    }
}
