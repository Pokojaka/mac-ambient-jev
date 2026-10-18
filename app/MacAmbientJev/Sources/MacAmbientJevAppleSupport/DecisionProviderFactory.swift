import Foundation
import MacAmbientJevCore

/// Loads the local clause tagger once and builds decision coordinators on it.
public final class DecisionProviderFactory: @unchecked Sendable {
    private let usageCounter: DecisionUsageCounter
    private let loadLocalTagger: @Sendable () throws -> LocalClauseTagger

    private let state = NSLock()
    private var cachedLocalTagger: Result<LocalClauseTagger, any Error>?
    private var pendingLoad: PendingLocalTaggerLoad?

    var pendingLoadWaiterCount: Int {
        let load = state.withLock { pendingLoad }
        return load?.waiterCount ?? 0
    }

    func waitForPendingLoadWaiters(_ count: Int) async {
        precondition(count > 0, "Pending load waiter count must be positive.")
        let load = state.withLock { pendingLoad }
        guard let load else {
            preconditionFailure("Cannot wait for waiters because there is no pending local tagger load.")
        }
        await load.waitForWaiters(count)
    }

    public init(
        usageCounter: DecisionUsageCounter,
        loadLocalTagger: @escaping @Sendable () throws -> LocalClauseTagger
    ) {
        self.usageCounter = usageCounter
        self.loadLocalTagger = loadLocalTagger
    }

    public func makeCoordinator() throws -> DecisionCoordinator {
        let tagger = try localTagger()
        return DecisionCoordinator(
            provider: tagger,
            identity: tagger.identity.decisionIdentity,
            usageCounter: usageCounter
        )
    }

    /// Validates the model through the same cached load as the coordinator, without a request or usage.
    public func localModelIdentity() throws -> ClauseTaggerModelIdentity {
        try localTagger().identity
    }

    /// Compiles and loads the model outside `state`. Concurrent callers share one load, and its
    /// result, success or failure, stays cached for the lifetime of the factory.
    private func localTagger() throws -> LocalClauseTagger {
        state.lock()
        if let cachedLocalTagger {
            state.unlock()
            return try cachedLocalTagger.get()
        }
        if let pendingLoad {
            state.unlock()
            return try pendingLoad.wait().get()
        }
        let load = PendingLocalTaggerLoad()
        pendingLoad = load
        state.unlock()

        let result: Result<LocalClauseTagger, any Error>
        do {
            result = .success(try loadLocalTagger())
        } catch {
            result = .failure(error)
        }

        state.lock()
        pendingLoad = nil
        cachedLocalTagger = result
        state.unlock()
        load.complete(result)
        return try result.get()
    }
}

private final class PendingLocalTaggerLoad: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<LocalClauseTagger, any Error>?
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

    func wait() -> Result<LocalClauseTagger, any Error> {
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

    func complete(_ result: Result<LocalClauseTagger, any Error>) {
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
