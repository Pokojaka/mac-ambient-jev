import Foundation

public struct JevUsageSnapshot: Sendable, Equatable {
    public let sendCount: Int
    public let estimatedInputTokens: Int
    public let successCount: Int
    public let failureCount: Int
    public let retryPendingCount: Int

    public init(
        sendCount: Int,
        estimatedInputTokens: Int,
        successCount: Int,
        failureCount: Int,
        retryPendingCount: Int
    ) {
        self.sendCount = sendCount
        self.estimatedInputTokens = estimatedInputTokens
        self.successCount = successCount
        self.failureCount = failureCount
        self.retryPendingCount = retryPendingCount
    }
}

public actor JevUsageCounter {
    private var sendCount = 0
    private var estimatedInputTokens = 0
    private var successCount = 0
    private var failureCount = 0
    private var retryPendingCount = 0

    public init() {}

    public func recordAttempt() {
        sendCount += 1
    }

    public func recordSuccess(inputTokens: Int?) {
        successCount += 1
        estimatedInputTokens += max(0, inputTokens ?? 0)
    }

    public func recordFailure(retryPending: Bool) {
        failureCount += 1
        if retryPending {
            retryPendingCount += 1
        }
    }

    public func recordRetryPending() {
        retryPendingCount += 1
    }

    public func resolveRetry() {
        retryPendingCount = max(0, retryPendingCount - 1)
    }

    public func snapshot() -> JevUsageSnapshot {
        JevUsageSnapshot(
            sendCount: sendCount,
            estimatedInputTokens: estimatedInputTokens,
            successCount: successCount,
            failureCount: failureCount,
            retryPendingCount: retryPendingCount
        )
    }
}
