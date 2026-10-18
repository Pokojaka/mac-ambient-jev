import Combine
import Foundation

struct LivePollWaitFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class LivePollSleep {
    private struct PendingSleep {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var pendingSleep: PendingSleep?
    private var suspensionWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: LivePollWaitFailure(message: "Live poll sleep was cancelled before suspension."))
                    return
                }
                guard pendingSleep == nil else {
                    continuation.resume(throwing: LivePollWaitFailure(message: "Live poll sleep cannot overlap an existing pending suspension."))
                    return
                }

                pendingSleep = PendingSleep(id: id, continuation: continuation)
                resumeSuspensionWaiters()
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingSleep(id: id)
            }
        }
    }

    func advance() async throws {
        try await waitUntilSuspended()
        guard let pendingSleep else {
            throw LivePollWaitFailure(message: "Live poll sleep could not be advanced because no suspension is pending.")
        }

        self.pendingSleep = nil
        pendingSleep.continuation.resume()
    }

    func waitUntilSuspended() async throws {
        if pendingSleep != nil {
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: LivePollWaitFailure(message: "Waiting for a live poll suspension was cancelled before registration."))
                    return
                }
                if pendingSleep != nil {
                    continuation.resume()
                    return
                }

                suspensionWaiters[id] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelSuspensionWaiter(id: id)
            }
        }
    }

    private func resumeSuspensionWaiters() {
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll(keepingCapacity: true)
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func cancelPendingSleep(id: UUID) {
        guard let pendingSleep, pendingSleep.id == id else {
            return
        }

        self.pendingSleep = nil
        pendingSleep.continuation.resume(
            throwing: LivePollWaitFailure(message: "Live poll sleep was cancelled while suspended.")
        )
    }

    private func cancelSuspensionWaiter(id: UUID) {
        guard let continuation = suspensionWaiters.removeValue(forKey: id) else {
            return
        }

        continuation.resume(
            throwing: LivePollWaitFailure(message: "Waiting for a live poll suspension was cancelled.")
        )
    }
}

@MainActor
@discardableResult
func waitForPublishedValue<P: Publisher>(
    _ publisher: P,
    description: String,
    matching predicate: @escaping @MainActor (P.Output) -> Bool
) async throws -> P.Output where P.Failure == Never, P.Output: Sendable {
    let (stream, continuation) = AsyncStream<P.Output>.makeStream()
    let subscription = publisher.sink(
        receiveCompletion: { _ in continuation.finish() },
        receiveValue: { value in continuation.yield(value) }
    )
    defer {
        subscription.cancel()
        continuation.finish()
    }

    do {
        for await value in stream {
            try Task.checkCancellation()
            if predicate(value) {
                return value
            }
        }
        if Task.isCancelled {
            throw LivePollWaitFailure(message: "Waiting for \(description) was cancelled.")
        }
        throw LivePollWaitFailure(message: "Publisher for \(description) finished before a matching value was published.")
    } catch is CancellationError {
        throw LivePollWaitFailure(message: "Waiting for \(description) was cancelled.")
    }
}
