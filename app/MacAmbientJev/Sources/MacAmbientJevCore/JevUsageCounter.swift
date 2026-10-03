import Foundation

public struct JevUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    /// Sum of the input token counts Jev reported.
    public let reportedInputTokens: Int
    public let successCount: Int
    /// Successful requests whose response carried no input token count.
    public let unreportedTokenSuccessCount: Int
    public let failureCount: Int
    public let retryPendingCount: Int

    public init(
        sendCount: Int,
        reportedInputTokens: Int,
        successCount: Int,
        unreportedTokenSuccessCount: Int,
        failureCount: Int,
        retryPendingCount: Int
    ) {
        self.sendCount = sendCount
        self.reportedInputTokens = reportedInputTokens
        self.successCount = successCount
        self.unreportedTokenSuccessCount = unreportedTokenSuccessCount
        self.failureCount = failureCount
        self.retryPendingCount = retryPendingCount
    }
}

public actor JevUsageCounter {
    private struct PendingSegment: Hashable {
        let sessionID: UUID
        let segmentID: String
    }

    private var sendCount = 0
    private var reportedInputTokens = 0
    private var successCount = 0
    private var unreportedTokenSuccessCount = 0
    private var failureCount = 0
    private var pendingSegments: Set<PendingSegment> = []

    public init() {}

    func recordAttempt() {
        sendCount += 1
    }

    func recordSuccess(sessionID: UUID, segmentID: String, inputTokens: Int?) {
        successCount += 1
        if let inputTokens {
            reportedInputTokens += inputTokens
        } else {
            unreportedTokenSuccessCount += 1
        }
        pendingSegments.remove(PendingSegment(sessionID: sessionID, segmentID: segmentID))
    }

    func recordFailure(sessionID: UUID, segmentID: String) {
        failureCount += 1
        recordDeferred(sessionID: sessionID, segmentID: segmentID)
    }

    func recordDeferred(sessionID: UUID, segmentID: String) {
        pendingSegments.insert(PendingSegment(sessionID: sessionID, segmentID: segmentID))
    }

    public func snapshot() -> JevUsageSnapshot {
        JevUsageSnapshot(
            sendCount: sendCount,
            reportedInputTokens: reportedInputTokens,
            successCount: successCount,
            unreportedTokenSuccessCount: unreportedTokenSuccessCount,
            failureCount: failureCount,
            retryPendingCount: pendingSegments.count
        )
    }
}
