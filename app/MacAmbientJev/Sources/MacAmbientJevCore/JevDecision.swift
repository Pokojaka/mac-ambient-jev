import Foundation

public struct ContentPriorityDecision: Sendable, Equatable {
    public let priority: ContentPriority
    public let confidence: Double
    public let model: String?
    public let inputTokens: Int?

    public init(
        priority: ContentPriority,
        confidence: Double,
        model: String?,
        inputTokens: Int?
    ) {
        self.priority = priority
        self.confidence = confidence
        self.model = model
        self.inputTokens = inputTokens
    }
}

public protocol DecisionProvider: Sendable {
    func classifyPriority(text: String) async throws -> ContentPriorityDecision
}

/// Why a batch stops sending the remaining segments to Jev.
public enum JevBatchStopReason: Sendable, Equatable {
    case providerUnavailable
    case authorizationRejected

    /// Returns nil for failures that affect only the request that raised them.
    init?(error: any Error) {
        switch error {
        case JevClientError.httpStatus(let status) where status == 401 || status == 403:
            self = .authorizationRejected
        case JevClientError.httpStatus(let status) where status == 429 || status >= 500:
            self = .providerUnavailable
        case JevClientError.invalidResponse, is URLError:
            self = .providerUnavailable
        default:
            return nil
        }
    }
}

public enum PriorityClassification: Sendable, Equatable {
    case classified(ContentPriorityDecision, visiblePriority: ContentPriority)
    /// The segment stays primary and pending. A non-nil reason means the
    /// remaining segments of the batch must not be sent.
    case failed(stopsBatch: JevBatchStopReason?)
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

public actor JevDecisionCoordinator {
    private let provider: any DecisionProvider
    private let usageCounter: JevUsageCounter

    public init(
        provider: any DecisionProvider,
        usageCounter: JevUsageCounter
    ) {
        self.provider = provider
        self.usageCounter = usageCounter
    }

    public func classify(
        text: String,
        segmentID: String,
        sessionID: UUID
    ) async -> PriorityClassification {
        await usageCounter.recordAttempt()

        do {
            let decision = try await provider.classifyPriority(text: text)
            try Task.checkCancellation()
            await usageCounter.recordSuccess(
                sessionID: sessionID,
                segmentID: segmentID,
                inputTokens: decision.inputTokens
            )
            return .classified(
                decision,
                visiblePriority: ContentPriorityPolicy.visiblePriority(for: decision)
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .cancelled
            }
            await usageCounter.recordFailure(
                sessionID: sessionID,
                segmentID: segmentID
            )
            return .failed(stopsBatch: JevBatchStopReason(error: error))
        }
    }

    /// Records a segment that was not sent because its batch stopped.
    public func deferClassification(
        segmentID: String,
        sessionID: UUID
    ) async {
        await usageCounter.recordDeferred(
            sessionID: sessionID,
            segmentID: segmentID
        )
    }
}

extension JevDecisionCoordinator {
    public func clearDeferred(sessionID: UUID, segmentIDs: Set<String>) async {
        await usageCounter.clearDeferred(sessionID: sessionID, segmentIDs: segmentIDs)
    }
}
