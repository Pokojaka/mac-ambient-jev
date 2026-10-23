import Foundation

/// Thrown when the test is cancelled, by its `.timeLimit` among others, while it waits for a condition.
public struct WaitCancelled: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Lets a test wait for a condition on state that a test double owns, without a wall-clock deadline.
///
/// The double calls `signal()` after every change to that state; `wait` re-checks its condition after each
/// signal. The test's `.timeLimit` is the only hang guard: cancellation ends the wait with `WaitCancelled`.
public final class ChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: CheckedContinuation<Void, Error>] = [:]

    public init() {}

    public func signal() {
        lock.lock()
        generation &+= 1
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in ready.values { continuation.resume() }
    }

    /// Returns once `condition` holds. `condition` runs in the caller's isolation.
    public func wait(
        _ what: String,
        isolation: isolated (any Actor)? = #isolation,
        until condition: () throws -> Bool
    ) async throws {
        while true {
            let seen = currentGeneration
            if try condition() { return }
            try await changed(after: seen, what)
        }
    }

    private var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func makeWaiterID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextWaiterID += 1
        return nextWaiterID
    }

    private func changed(after seen: UInt64, _ what: String) async throws {
        let id = makeWaiterID()
        let cancelled = WaitCancelled(description: "cancelled while waiting for \(what)")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if generation != seen {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: cancelled)
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: cancelled)
        }
    }
}
