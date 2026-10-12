import Foundation

public enum DecisionResponseError: LocalizedError, Sendable {
    case invalidResponse
    case unexpectedAnswers
    case missingAnswer

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "判定応答が不正です"
        case .unexpectedAnswers: "判定対象と応答が一致しません"
        case .missingAnswer: "必要な判定結果がありません"
        }
    }
}

/// Why a batch stops sending the remaining requests.
public enum DecisionBatchStopReason: Sendable, Equatable {
    case providerUnavailable
    case authorizationRejected

    /// Returns nil for failures that affect only the request that raised them.
    init?(error: any Error) {
        switch error {
        case JevClientError.httpStatus(let status) where status == 401 || status == 403:
            self = .authorizationRejected
        case JevClientError.httpStatus(let status) where status == 429 || status >= 500:
            self = .providerUnavailable
        case DecisionResponseError.invalidResponse, JevClientError.invalidResponse, is URLError:
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

/// The outcome of one decision request.
public enum DecisionRequestOutcome<Response: Sendable>: Sendable {
    case answered(Response, DecisionRequestRecord)
    /// The request failed. A non-nil reason means the remaining requests must not be sent.
    case failed(stopsBatch: DecisionBatchStopReason?, message: String)
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
/// questions or targets it carries.
public actor DecisionCoordinator {
    private let provider: any DecisionProvider
    private let usageCounter: DecisionUsageCounter
    private nonisolated let identity: DecisionModelIdentity

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
        switch identity.provider {
        case .jev:
            DecisionRunProvenance.boundary(mode: mode)
        case .localModel:
            DecisionRunProvenance.localBoundary(
                mode: mode, modelID: identity.model, modelRevision: identity.modelRevision
            )
        }
    }

    public nonisolated func priorityProvenance(mode: String) -> RunProvenance {
        switch identity.provider {
        case .jev:
            DecisionRunProvenance.priority(mode: mode)
        case .localModel:
            DecisionRunProvenance.localPriority(
                mode: mode, modelID: identity.model, modelRevision: identity.modelRevision
            )
        }
    }

    public func assessBoundaries(
        _ request: ClauseBoundaryRequest
    ) async -> DecisionRequestOutcome<ClauseBoundaryResponse> {
        await send(purpose: .boundary) {
            let response = try await self.provider.assessBoundaries(request)
            guard response.probabilities.values.allSatisfy(isValidProbability),
                  response.continuationProbability.map(isValidProbability) ?? true else {
                throw DecisionResponseError.invalidResponse
            }
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
            return (response, response.metadata)
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
            return (response, response.metadata)
        }
    }

    private func validateMetadata(_ metadata: DecisionResponseMetadata) throws {
        guard metadata.identity.provider == identity.provider else {
            throw DecisionResponseError.invalidResponse
        }
        if identity.provider == .localModel, metadata.identity != identity {
            throw DecisionResponseError.invalidResponse
        }
    }

    private func send<Response: Sendable>(
        purpose: DecisionRequestPurpose,
        _ request: @Sendable () async throws -> (Response, DecisionResponseMetadata)
    ) async -> DecisionRequestOutcome<Response> {
        await usageCounter.recordAttempt(purpose: purpose)
        do {
            let (response, metadata) = try await request()
            try validateMetadata(metadata)
            try Task.checkCancellation()
            await usageCounter.recordSuccess(purpose: purpose, inputTokens: metadata.inputTokens)
            return .answered(response, try DecisionRequestRecord(
                requestID: "decisionreq_\(UUID().uuidString.lowercased())", metadata: metadata
            ))
        } catch {
            if Task.isCancelled || error is CancellationError {
                return .cancelled
            }
            await usageCounter.recordFailure(purpose: purpose)
            return .failed(stopsBatch: DecisionBatchStopReason(error: error), message: error.localizedDescription)
        }
    }
}
