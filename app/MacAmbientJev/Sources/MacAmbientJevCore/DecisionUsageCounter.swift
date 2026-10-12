import Foundation

public enum DecisionRequestPurpose: String, Codable, Sendable {
    case boundary
    case priority
}

public struct DecisionRequestUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    /// Sum of the input token counts the provider reported for these requests.
    public let reportedInputTokens: Int
    public let successCount: Int
    /// Successful requests whose response carried no input token count.
    public let unreportedTokenSuccessCount: Int
    public let failureCount: Int

    public init(
        sendCount: Int,
        reportedInputTokens: Int,
        successCount: Int,
        unreportedTokenSuccessCount: Int,
        failureCount: Int
    ) {
        self.sendCount = sendCount
        self.reportedInputTokens = reportedInputTokens
        self.successCount = successCount
        self.unreportedTokenSuccessCount = unreportedTokenSuccessCount
        self.failureCount = failureCount
    }
}

public struct DecisionUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    /// Sum of the input token counts the provider reported.
    public let reportedInputTokens: Int
    public let successCount: Int
    public let unreportedTokenSuccessCount: Int
    public let failureCount: Int
    /// Segments whose boundary request is pending.
    public let pendingBoundarySegmentCount: Int
    /// Clauses whose priority is pending.
    public let pendingPriorityClauseCount: Int
    public let boundaryRequests: DecisionRequestUsageSnapshot
    public let priorityRequests: DecisionRequestUsageSnapshot

    public init(
        sendCount: Int,
        reportedInputTokens: Int,
        successCount: Int,
        unreportedTokenSuccessCount: Int,
        failureCount: Int,
        pendingBoundarySegmentCount: Int,
        pendingPriorityClauseCount: Int,
        boundaryRequests: DecisionRequestUsageSnapshot,
        priorityRequests: DecisionRequestUsageSnapshot
    ) {
        self.sendCount = sendCount
        self.reportedInputTokens = reportedInputTokens
        self.successCount = successCount
        self.unreportedTokenSuccessCount = unreportedTokenSuccessCount
        self.failureCount = failureCount
        self.pendingBoundarySegmentCount = pendingBoundarySegmentCount
        self.pendingPriorityClauseCount = pendingPriorityClauseCount
        self.boundaryRequests = boundaryRequests
        self.priorityRequests = priorityRequests
    }
}

public actor DecisionUsageCounter {
    private struct RequestUsage {
        var sendCount = 0
        var reportedInputTokens = 0
        var successCount = 0
        var unreportedTokenSuccessCount = 0
        var failureCount = 0

        var snapshot: DecisionRequestUsageSnapshot {
            DecisionRequestUsageSnapshot(
                sendCount: sendCount,
                reportedInputTokens: reportedInputTokens,
                successCount: successCount,
                unreportedTokenSuccessCount: unreportedTokenSuccessCount,
                failureCount: failureCount
            )
        }

        mutating func recordSuccess(inputTokens: Int?) {
            successCount += 1
            if let inputTokens {
                reportedInputTokens += inputTokens
            } else {
                unreportedTokenSuccessCount += 1
            }
        }
    }

    private struct PendingKey: Hashable {
        let sessionID: UUID
        let target: DecisionPendingTarget
    }

    private var boundaryRequests = RequestUsage()
    private var priorityRequests = RequestUsage()
    private var pending: Set<PendingKey> = []

    public init() {}

    public func recordAttempt(purpose: DecisionRequestPurpose) {
        switch purpose {
        case .boundary: boundaryRequests.sendCount += 1
        case .priority: priorityRequests.sendCount += 1
        }
    }

    public func recordSuccess(purpose: DecisionRequestPurpose, inputTokens: Int?) {
        guard !Task.isCancelled else { return }
        switch purpose {
        case .boundary: boundaryRequests.recordSuccess(inputTokens: inputTokens)
        case .priority: priorityRequests.recordSuccess(inputTokens: inputTokens)
        }
    }

    public func recordFailure(purpose: DecisionRequestPurpose) {
        guard !Task.isCancelled else { return }
        switch purpose {
        case .boundary: boundaryRequests.failureCount += 1
        case .priority: priorityRequests.failureCount += 1
        }
    }

    /// Records targets whose pending state is durable. Request counts are not changed.
    public func recordDeferred(sessionID: UUID, targets: Set<DecisionPendingTarget>) {
        for target in targets {
            pending.insert(PendingKey(sessionID: sessionID, target: target))
        }
    }

    /// Clears targets a published snapshot resolved or replaced. Request counts are kept.
    public func clearDeferred(sessionID: UUID, targets: Set<DecisionPendingTarget>) {
        for target in targets {
            pending.remove(PendingKey(sessionID: sessionID, target: target))
        }
    }

    public func snapshot() -> DecisionUsageSnapshot {
        DecisionUsageSnapshot(
            sendCount: boundaryRequests.sendCount + priorityRequests.sendCount,
            reportedInputTokens: boundaryRequests.reportedInputTokens + priorityRequests.reportedInputTokens,
            successCount: boundaryRequests.successCount + priorityRequests.successCount,
            unreportedTokenSuccessCount: boundaryRequests.unreportedTokenSuccessCount + priorityRequests.unreportedTokenSuccessCount,
            failureCount: boundaryRequests.failureCount + priorityRequests.failureCount,
            pendingBoundarySegmentCount: pending.filter {
                if case .boundary = $0.target { true } else { false }
            }.count,
            pendingPriorityClauseCount: pending.filter {
                if case .priority = $0.target { true } else { false }
            }.count,
            boundaryRequests: boundaryRequests.snapshot,
            priorityRequests: priorityRequests.snapshot
        )
    }
}
