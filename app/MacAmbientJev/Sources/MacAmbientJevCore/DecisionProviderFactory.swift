import Foundation

/// A decision provider paired with the identity of its loaded model.
public struct LoadedDecisionProvider: Sendable {
    public let provider: any DecisionProvider
    public let identity: ClauseTaggerModelIdentity

    public init(provider: any DecisionProvider, identity: ClauseTaggerModelIdentity) {
        self.provider = provider
        self.identity = identity
    }
}

/// Loads a decision provider once and builds decision coordinators on it.
public final class DecisionProviderFactory: @unchecked Sendable {
    private let usageCounter: DecisionUsageCounter
    private let loadProvider: @Sendable () throws -> LoadedDecisionProvider

    private let state = NSLock()
    private var cachedProvider: Result<LoadedDecisionProvider, any Error>?
    private var pendingLoad: PendingProviderLoad?

    var pendingLoadWaiterCount: Int {
        let load = state.withLock { pendingLoad }
        return load?.waiterCount ?? 0
    }

    func waitForPendingLoadWaiters(_ count: Int) async {
        precondition(count > 0, "Pending load waiter count must be positive.")
        let load = state.withLock { pendingLoad }
        guard let load else {
            preconditionFailure("Cannot wait for waiters because there is no pending provider load.")
        }
        await load.waitForWaiters(count)
    }

    public init(
        usageCounter: DecisionUsageCounter,
        loadProvider: @escaping @Sendable () throws -> LoadedDecisionProvider
    ) {
        self.usageCounter = usageCounter
        self.loadProvider = loadProvider
    }

    public func makeCoordinator() throws -> DecisionCoordinator {
        let loaded = try loadedProvider()
        return DecisionCoordinator(
            provider: loaded.provider,
            identity: loaded.identity.decisionIdentity,
            usageCounter: usageCounter
        )
    }

    /// Validates the model through the same cached provider load as the coordinator, without a request or usage.
    public func localModelIdentity() throws -> ClauseTaggerModelIdentity {
        try loadedProvider().identity
    }

    /// Loads a decision provider outside `state`. Concurrent callers share one provider load, and its
    /// result, success or failure, stays cached for the lifetime of the factory.
    private func loadedProvider() throws -> LoadedDecisionProvider {
        state.lock()
        if let cachedProvider {
            state.unlock()
            return try cachedProvider.get()
        }
        if let pendingLoad {
            state.unlock()
            return try pendingLoad.wait().get()
        }
        let load = PendingProviderLoad()
        pendingLoad = load
        state.unlock()

        let result: Result<LoadedDecisionProvider, any Error>
        do {
            result = .success(try loadProvider())
        } catch {
            result = .failure(error)
        }

        state.lock()
        pendingLoad = nil
        cachedProvider = result
        state.unlock()
        load.complete(result)
        return try result.get()
    }
}

private final class PendingProviderLoad: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<LoadedDecisionProvider, any Error>?
    private var parkedWaiters = 0
    private var waiterThresholdObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var waiterCount: Int {
        condition.withLock { parkedWaiters }
    }

    func waitForWaiters(_ count: Int) async {
        precondition(count > 0, "Pending load waiter count must be positive.")
        await withCheckedContinuation { continuation in
            condition.withLock {
                if parkedWaiters >= count {
                    continuation.resume()
                } else {
                    waiterThresholdObservers.append((count: count, continuation: continuation))
                }
            }
        }
    }

    func wait() -> Result<LoadedDecisionProvider, any Error> {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result { return result }
            parkedWaiters += 1
            resumeSatisfiedWaiterObservers()
            condition.wait()
            parkedWaiters -= 1
        }
    }

    func complete(_ result: Result<LoadedDecisionProvider, any Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    private func resumeSatisfiedWaiterObservers() {
        var unsatisfiedObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in waiterThresholdObservers {
            if parkedWaiters >= observer.count {
                observer.continuation.resume()
            } else {
                unsatisfiedObservers.append(observer)
            }
        }
        waiterThresholdObservers = unsatisfiedObservers
    }
}
