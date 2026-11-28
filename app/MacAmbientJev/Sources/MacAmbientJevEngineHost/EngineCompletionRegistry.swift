import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

/// Keeps an RPC attached to the exact processing request it admitted.
@MainActor
final class EngineCompletionRegistry {
    enum Kind: Equatable {
        case finalization
        case decisionRetry
    }

    enum Outcome {
        case completed
        case failed(String)
        case commandFailure(EngineCommandError)
        case paused
    }

    private enum State {
        case registered
        case waiting(CheckedContinuation<Outcome, any Error>)
        case completed(Outcome)
    }

    private struct Request {
        let terminalReplyClaim: @MainActor @Sendable () -> Void
        var state: State
    }

    private var requests: [UUID: Request] = [:]

    func register(
        requestID: UUID,
        terminalReplyClaim: @escaping @MainActor @Sendable () -> Void
    ) {
        if requests[requestID] != nil {
            preconditionFailure("processing request identity must be unique")
        }
        requests[requestID] = Request(terminalReplyClaim: terminalReplyClaim, state: .registered)
    }

    func wait(requestID: UUID) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                guard var request = requests[requestID] else {
                    continuation.resume(throwing: EngineCompletionError.requestNotRegistered)
                    return
                }
                switch request.state {
                case .registered:
                    if Task.isCancelled {
                        requests.removeValue(forKey: requestID)
                        continuation.resume(throwing: CancellationError())
                    } else {
                        request.state = .waiting(continuation)
                        requests[requestID] = request
                    }
                case .completed(let outcome):
                    requests.removeValue(forKey: requestID)
                    continuation.resume(returning: outcome)
                case .waiting:
                    preconditionFailure("one RPC waiter is allowed per processing request")
                }
            }
        } onCancel: {
            Task { @MainActor [self] in cancel(requestID: requestID) }
        }
    }

    func finished(
        _ item: ProcessingQueueItemSummary,
        result: SessionProcessingResult?,
        isShutdownCancellation: Bool
    ) {
        let requestID = item.requestID
        guard let request = requests[requestID] else { return }
        if result?.disposition == .paused,
           item.holdReason?.resumesInProcess == true,
           !isShutdownCancellation {
            return
        }
        let outcome: Outcome
        switch result?.disposition {
        case nil, .completed?:
            outcome = .completed
        case .failed?:
            outcome = .failed(result?.message ?? "処理に失敗しました")
        case .paused?:
            outcome = .paused
        }
        complete(requestID: requestID, request: request, with: outcome)
    }

    func finish(requestID: UUID, with error: EngineCommandError) {
        finish(requestID: requestID, with: .commandFailure(error))
    }

    func finish(requestID: UUID, with outcome: Outcome) {
        guard let request = requests[requestID] else { return }
        complete(requestID: requestID, request: request, with: outcome)
    }

    func finishPendingAndHeldForShutdown(summaries: [ProcessingQueueItemSummary]) {
        for item in summaries where item.holdReason != nil {
            let requestID = item.requestID
            guard let request = requests[requestID] else { continue }
            complete(requestID: requestID, request: request, with: .paused)
        }
    }

    func finishRemainingForShutdown() {
        for (requestID, request) in Array(requests) {
            complete(requestID: requestID, request: request, with: .paused)
        }
    }

    private func complete(requestID: UUID, request: Request, with outcome: Outcome) {
        switch request.state {
        case .registered:
            request.terminalReplyClaim()
            var updated = request
            updated.state = .completed(outcome)
            requests[requestID] = updated
        case .waiting(let continuation):
            request.terminalReplyClaim()
            requests.removeValue(forKey: requestID)
            continuation.resume(returning: outcome)
        case .completed:
            break
        }
    }

    private func cancel(requestID: UUID) {
        guard let request = requests.removeValue(forKey: requestID) else { return }
        if case .waiting(let continuation) = request.state {
            continuation.resume(throwing: CancellationError())
        }
    }
}

enum EngineCompletionError: Error {
    case requestNotRegistered
}
