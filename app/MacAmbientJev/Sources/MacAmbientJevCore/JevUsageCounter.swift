import Foundation

public enum JevRequestPurpose: String, Codable, Sendable {
    case boundary
    case priority
}

public struct JevRequestUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    /// Sum of the input token counts Jev reported for these requests.
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

public struct JevUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    /// Sum of the input token counts Jev reported.
    public let reportedInputTokens: Int
    public let successCount: Int
    public let unreportedTokenSuccessCount: Int
    public let failureCount: Int
    public let retryPendingCount: Int
    public let boundaryRequests: JevRequestUsageSnapshot
    public let priorityRequests: JevRequestUsageSnapshot

    public init(
        sendCount: Int,
        reportedInputTokens: Int,
        successCount: Int,
        unreportedTokenSuccessCount: Int,
        failureCount: Int,
        retryPendingCount: Int,
        boundaryRequests: JevRequestUsageSnapshot,
        priorityRequests: JevRequestUsageSnapshot
    ) {
        self.sendCount = sendCount
        self.reportedInputTokens = reportedInputTokens
        self.successCount = successCount
        self.unreportedTokenSuccessCount = unreportedTokenSuccessCount
        self.failureCount = failureCount
        self.retryPendingCount = retryPendingCount
        self.boundaryRequests = boundaryRequests
        self.priorityRequests = priorityRequests
    }
}

public actor JevUsageCounter {
    private struct RequestUsage {
        var sendCount = 0
        var reportedInputTokens = 0
        var successCount = 0
        var unreportedTokenSuccessCount = 0
        var failureCount = 0

        var snapshot: JevRequestUsageSnapshot {
            JevRequestUsageSnapshot(
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

    private struct PendingSegment: Hashable {
        let sessionID: UUID
        let segmentID: String
    }

    private var boundaryRequests = RequestUsage()
    private var priorityRequests = RequestUsage()
    private var pendingSegments: Set<PendingSegment> = []

    public init() {}

    public func recordAttempt(purpose: JevRequestPurpose) {
        switch purpose {
        case .boundary: boundaryRequests.sendCount += 1
        case .priority: priorityRequests.sendCount += 1
        }
    }

    public func recordSuccess(purpose: JevRequestPurpose, inputTokens: Int?) {
        guard !Task.isCancelled else { return }
        switch purpose {
        case .boundary: boundaryRequests.recordSuccess(inputTokens: inputTokens)
        case .priority: priorityRequests.recordSuccess(inputTokens: inputTokens)
        }
    }

    public func recordFailure(purpose: JevRequestPurpose) {
        guard !Task.isCancelled else { return }
        switch purpose {
        case .boundary: boundaryRequests.failureCount += 1
        case .priority: priorityRequests.failureCount += 1
        }
    }

    public func recordDeferred(sessionID: UUID, segmentID: String) {
        guard !Task.isCancelled else { return }
        pendingSegments.insert(PendingSegment(sessionID: sessionID, segmentID: segmentID))
    }

    public func clearDeferred(sessionID: UUID, segmentIDs: Set<String>) {
        for segmentID in segmentIDs {
            pendingSegments.remove(PendingSegment(sessionID: sessionID, segmentID: segmentID))
        }
    }

    public func snapshot() -> JevUsageSnapshot {
        JevUsageSnapshot(
            sendCount: boundaryRequests.sendCount + priorityRequests.sendCount,
            reportedInputTokens: boundaryRequests.reportedInputTokens + priorityRequests.reportedInputTokens,
            successCount: boundaryRequests.successCount + priorityRequests.successCount,
            unreportedTokenSuccessCount: boundaryRequests.unreportedTokenSuccessCount + priorityRequests.unreportedTokenSuccessCount,
            failureCount: boundaryRequests.failureCount + priorityRequests.failureCount,
            retryPendingCount: pendingSegments.count,
            boundaryRequests: boundaryRequests.snapshot,
            priorityRequests: priorityRequests.snapshot
        )
    }
}
