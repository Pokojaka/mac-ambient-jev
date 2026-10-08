import Foundation

/// Why a batch stops sending the remaining requests to Jev.
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

    /// The pending reason recorded for targets a stopped batch leaves unsent.
    public var pendingReason: ClausePendingReason {
        switch self {
        case .authorizationRejected: .authorizationRejected
        case .providerUnavailable: .requestFailed
        }
    }
}

/// The outcome of one Jev request.
public enum JevRequestOutcome<Response: Sendable>: Sendable {
    case answered(Response, JevRequestRecord)
    /// The request failed. A non-nil reason means the remaining requests must not be sent.
    case failed(stopsBatch: JevBatchStopReason?, message: String)
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

/// Sends one Jev request at a time and counts each HTTP request once, whatever the number of
/// questions or targets it carries.
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

    public func assessBoundaries(
        _ request: ClauseBoundaryRequest
    ) async -> JevRequestOutcome<ClauseBoundaryResponse> {
        await send(purpose: .boundary) {
            let response = try await self.provider.assessBoundaries(request)
            guard response.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  response.continuationProbability.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                throw JevClientError.invalidResponse
            }
            guard Set(response.probabilities.keys) == Set(request.candidates.map(\.id)),
                  (response.continuationProbability == nil) == (request.next == nil) else {
                throw JevClientError.unexpectedAnswers
            }
            return (response, response.metadata)
        }
    }

    /// `targets` must use the request-local keys `u0001`…; every key must be answered.
    public func classifyPriorities(
        _ targets: [PriorityTextTarget]
    ) async -> JevRequestOutcome<PriorityBatchResponse> {
        await send(purpose: .priority) {
            let response = try await self.provider.classifyPriorities(targets)
            guard Set(response.decisions.keys) == Set(targets.map(\.key)) else {
                throw JevClientError.unexpectedAnswers
            }
            return (response, response.metadata)
        }
    }

    private func send<Response: Sendable>(
        purpose: JevRequestPurpose,
        _ request: @Sendable () async throws -> (Response, JevResponseMetadata)
    ) async -> JevRequestOutcome<Response> {
        await usageCounter.recordAttempt(purpose: purpose)
        do {
            let (response, metadata) = try await request()
            try Task.checkCancellation()
            await usageCounter.recordSuccess(purpose: purpose, inputTokens: metadata.inputTokens)
            return .answered(response, try JevRequestRecord(
                requestID: "jevreq_\(UUID().uuidString.lowercased())", metadata: metadata
            ))
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .cancelled
            }
            await usageCounter.recordFailure(purpose: purpose)
            return .failed(stopsBatch: JevBatchStopReason(error: error), message: error.localizedDescription)
        }
    }
}
