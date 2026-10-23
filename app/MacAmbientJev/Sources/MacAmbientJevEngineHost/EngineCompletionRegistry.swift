import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

/// Lets a request wait for the queued processing it started: `session.reprocess` and `session.retry_decisions`
/// complete only after their work reaches a terminal result.
@MainActor
final class EngineCompletionRegistry {
    enum Kind: Equatable {
        case finalization
        case decisionRetry
    }

    enum Outcome {
        case completed
        case failed(String)
        /// Finalization stopped before finishing and stays recoverable.
        case paused
    }

    private struct Waiter {
        let sessionID: UUID
        let kind: Kind
        let continuation: CheckedContinuation<Outcome, any Error>
    }

    private var waiters: [UInt64: Waiter] = [:]
    private var nextToken: UInt64 = 0

    static func kind(of request: PendingProcessing) -> Kind {
        request.finalizesTranscript ? .finalization : .decisionRetry
    }

    func wait(sessionID: UUID, kind: Kind) async throws -> Outcome {
        nextToken += 1
        let token = nextToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[token] = Waiter(sessionID: sessionID, kind: kind, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [self] in cancel(token) }
        }
    }

    func finished(_ request: PendingProcessing, result: SessionProcessingResult?) {
        let kind = Self.kind(of: request)
        let outcome: Outcome
        switch result?.disposition {
        case nil, .completed?:
            outcome = .completed
        case .failed?:
            outcome = .failed(result?.message ?? "処理に失敗しました")
        case .paused?:
            outcome = .paused
        }
        for (token, waiter) in waiters where waiter.sessionID == request.sessionID && waiter.kind == kind {
            waiters.removeValue(forKey: token)
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func cancel(_ token: UInt64) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
