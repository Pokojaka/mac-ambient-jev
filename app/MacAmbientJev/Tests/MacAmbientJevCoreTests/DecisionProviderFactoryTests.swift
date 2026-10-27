import Foundation
import Testing
@testable import MacAmbientJevCore

private final class ProviderLoadFailure: Error, @unchecked Sendable {}

private final class LockedLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func recordLoad() {
        lock.lock()
        loads += 1
        lock.unlock()
    }
}

private final class SequentialFailureLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [ProviderLoadFailure]
    private var attempts = 0

    init(failures: [ProviderLoadFailure]) {
        self.failures = failures
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func load() throws -> LoadedDecisionProvider {
        lock.lock()
        let attempt = attempts
        attempts += 1
        lock.unlock()
        guard failures.indices.contains(attempt) else {
            throw ProviderLoadFailure()
        }
        throw failures[attempt]
    }
}

private struct SyntheticDecisionProvider: DecisionProvider {
    let boundaryInputTokens: Int
    let priorityInputTokens: Int

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        try Task.checkCancellation()
        return ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.75) }),
            continuationProbability: request.next == nil ? nil : 0.5,
            fillerRanges: [],
            inputTokens: boundaryInputTokens
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        try Task.checkCancellation()
        let decision = try ContentPriorityDecision(
            priority: .primary,
            confidence: 1,
            probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: priorityInputTokens
        )
    }
}

private final class OneShotCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didCancel = false
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        guard !didCancel else { return false }
        didCancel = true
        return true
    }
}

private struct CancelFirstDecisionProvider: DecisionProvider {
    let state: OneShotCancellationState
    let successfulProvider: SyntheticDecisionProvider

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        try Task.checkCancellation()
        if state.shouldCancel() { throw CancellationError() }
        return try await successfulProvider.assessBoundaries(request)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        try Task.checkCancellation()
        if state.shouldCancel() { throw CancellationError() }
        return try await successfulProvider.classifyPriorities(targets)
    }
}

private func makeIdentity() throws -> ClauseTaggerModelIdentity {
    try ClauseTaggerModelIdentity(
        backend: "test-backend",
        modelID: "synthetic-local-model",
        revision: String(repeating: "b", count: 64),
        tokenizerSHA256: String(repeating: "c", count: 64)
    )
}

private func makeCoordinatorOnThread(
    _ factory: DecisionProviderFactory,
    failure: ProviderLoadFailure
) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        Thread {
            do {
                _ = try factory.makeCoordinator()
                continuation.resume(returning: false)
            } catch {
                continuation.resume(returning: (error as? ProviderLoadFailure) === failure)
            }
        }.start()
    }
}

private func identityOnThread(_ factory: DecisionProviderFactory) async -> ClauseTaggerModelIdentity? {
    await withCheckedContinuation { (continuation: CheckedContinuation<ClauseTaggerModelIdentity?, Never>) in
        Thread {
            do {
                continuation.resume(returning: try factory.localModelIdentity())
            } catch {
                continuation.resume(returning: nil)
            }
        }.start()
    }
}

private func coordinatorIdentityOnThread(_ factory: DecisionProviderFactory) async -> DecisionModelIdentity? {
    await withCheckedContinuation { (continuation: CheckedContinuation<DecisionModelIdentity?, Never>) in
        Thread {
            do {
                continuation.resume(returning: try factory.makeCoordinator().identity)
            } catch {
                continuation.resume(returning: nil)
            }
        }.start()
    }
}

@Suite
struct DecisionProviderFactoryTests {
    @Test
    func firstLoadFailureIsCachedAcrossFactoryAPIs() async throws {
        let firstFailure = ProviderLoadFailure()
        let secondFailure = ProviderLoadFailure()
        let loader = SequentialFailureLoader(failures: [firstFailure, secondFailure])
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) { try loader.load() }

        Self.expectFailure({ _ = try factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectFailure({ _ = try factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectFailure({ _ = try factory.localModelIdentity() }, identicalTo: firstFailure)
        #expect(loader.attemptCount == 1)
        Self.expectZeroUsage(await usageCounter.snapshot())
    }

    @Test(.timeLimit(.minutes(10)))
    func simultaneousFailingRequestsShareOneLoad() async throws {
        let failure = ProviderLoadFailure()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let release = DispatchSemaphore(value: 0)
        let loadCounter = LockedLoadCounter()
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) {
            loadCounter.recordLoad()
            startedContinuation.yield(())
            startedContinuation.finish()
            release.wait()
            throw failure
        }
        defer { release.signal() }

        async let firstRequest = makeCoordinatorOnThread(factory, failure: failure)
        async let secondRequest = makeCoordinatorOnThread(factory, failure: failure)
        async let thirdRequest = makeCoordinatorOnThread(factory, failure: failure)

        var startedIterator = started.makeAsyncIterator()
        let loadDidStart: Void? = await startedIterator.next()
        try #require(loadDidStart != nil)
        await factory.waitForPendingLoadWaiters(2)
        #expect(factory.pendingLoadWaiterCount == 2)
        #expect(loadCounter.count == 1)

        release.signal()
        let results = await (firstRequest, secondRequest, thirdRequest)
        #expect(results.0)
        #expect(results.1)
        #expect(results.2)
        #expect(loadCounter.count == 1)
        Self.expectZeroUsage(await usageCounter.snapshot())
    }

    @Test(.timeLimit(.minutes(10)))
    func simultaneousIdentityAndCoordinatorRequestsShareOneLoad() async throws {
        let identity = try makeIdentity()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let release = DispatchSemaphore(value: 0)
        let loadCounter = LockedLoadCounter()
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) {
            loadCounter.recordLoad()
            startedContinuation.yield(())
            startedContinuation.finish()
            release.wait()
            return LoadedDecisionProvider(
                provider: SyntheticDecisionProvider(boundaryInputTokens: 7, priorityInputTokens: 11),
                identity: identity
            )
        }
        defer { release.signal() }

        async let identityRequest = identityOnThread(factory)
        async let firstCoordinatorRequest = coordinatorIdentityOnThread(factory)
        async let secondCoordinatorRequest = coordinatorIdentityOnThread(factory)

        var startedIterator = started.makeAsyncIterator()
        let loadDidStart: Void? = await startedIterator.next()
        try #require(loadDidStart != nil)
        await factory.waitForPendingLoadWaiters(2)
        #expect(factory.pendingLoadWaiterCount == 2)
        #expect(loadCounter.count == 1)

        release.signal()
        let results = await (identityRequest, firstCoordinatorRequest, secondCoordinatorRequest)
        #expect(results.0 == identity)
        #expect(results.1 == identity.decisionIdentity)
        #expect(results.2 == identity.decisionIdentity)
        #expect(try factory.localModelIdentity() == identity)
        #expect(try factory.makeCoordinator().identity == identity.decisionIdentity)
        #expect(loadCounter.count == 1)
        Self.expectZeroUsage(await usageCounter.snapshot())
    }

    @Test
    func cachedIdentityProvidesProvenanceAndCountsOnlyRequests() async throws {
        let identity = try makeIdentity()
        let usageCounter = DecisionUsageCounter()
        let loadCounter = LockedLoadCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) {
            loadCounter.recordLoad()
            return LoadedDecisionProvider(
                provider: SyntheticDecisionProvider(boundaryInputTokens: 7, priorityInputTokens: 11),
                identity: identity
            )
        }

        let initialUsage = await usageCounter.snapshot()
        let firstIdentity = try factory.localModelIdentity()
        let secondIdentity = try factory.localModelIdentity()
        let coordinator = try factory.makeCoordinator()
        let cachedCoordinator = try factory.makeCoordinator()
        #expect(firstIdentity == identity)
        #expect(secondIdentity == identity)
        #expect(coordinator.identity == identity.decisionIdentity)
        #expect(cachedCoordinator.identity == identity.decisionIdentity)
        #expect(loadCounter.count == 1)
        #expect(await usageCounter.snapshot() == initialUsage)

        let boundaryProvenance = coordinator.boundaryProvenance(mode: "live")
        let priorityProvenance = coordinator.priorityProvenance(mode: "live")
        for provenance in [boundaryProvenance, priorityProvenance] {
            #expect(provenance.engine == "test-backend")
            #expect(provenance.model == identity.modelID)
            #expect(provenance.version == identity.revision)
            #expect(provenance.configuration["model_id"] == identity.modelID)
            #expect(provenance.configuration["model_revision"] == identity.revision)
            #expect(provenance.configuration["unit_policy"] == "btsj-utterance-sentence")
            #expect(provenance.configuration["compute_units"] == "cpu-only")
        }

        let source = try SegmentTextReference(
            segmentationRunID: "factory-test-run",
            segmentID: "factory-test-segment-1",
            asrRunID: "factory-test-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "factory-test-run",
            segmentID: "factory-test-segment-2",
            asrRunID: "factory-test-asr",
            asrEventSeq: 2
        )
        let next = try NextSegmentHead(source: nextSource, text: "明日は雨です。")
        let boundaryRequest = try ClauseBoundaryRequest(
            source: source,
            text: "今日は晴れです。明日は雨です",
            next: next
        )
        let boundaryRecord: DecisionRequestRecord
        switch await coordinator.assessBoundaries(boundaryRequest) {
        case .answered(let response, let record):
            boundaryRecord = record
            #expect(response.probabilities.count == boundaryRequest.candidates.count)
            #expect(response.probabilities.values.allSatisfy { $0 == 0.75 })
            #expect(response.continuationProbability == 0.5)
            #expect(response.fillerRanges.isEmpty)
            #expect(response.inputTokens == 7)
            #expect(record.inputTokens == 7)
        case .failed(let message):
            Issue.record("The synthetic boundary request failed: \(message)")
            return
        case .cancelled:
            Issue.record("The synthetic boundary request was unexpectedly cancelled.")
            return
        }

        let priorityRecord: DecisionRequestRecord
        switch await coordinator.classifyPriorities([
            PriorityTextTarget(key: "u0001", text: "今日は晴れです")
        ]) {
        case .answered(let response, let record):
            priorityRecord = record
            #expect(response.decisions["u0001"]?.priority == .primary)
            #expect(response.decisions["u0001"]?.confidence == 1)
            #expect(response.inputTokens == 11)
            #expect(record.inputTokens == 11)
        case .failed(let message):
            Issue.record("The synthetic priority request failed: \(message)")
            return
        case .cancelled:
            Issue.record("The synthetic priority request was unexpectedly cancelled.")
            return
        }

        #expect(boundaryRecord.requestID.hasPrefix("decisionreq_"))
        #expect(priorityRecord.requestID.hasPrefix("decisionreq_"))
        let usage = await usageCounter.snapshot()
        #expect(usage.sendCount == 2)
        #expect(usage.successCount == 2)
        #expect(usage.failureCount == 0)
        #expect(usage.inputTokens == 18)
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.boundaryRequests.successCount == 1)
        #expect(usage.boundaryRequests.failureCount == 0)
        #expect(usage.boundaryRequests.inputTokens == 7)
        #expect(usage.priorityRequests.sendCount == 1)
        #expect(usage.priorityRequests.successCount == 1)
        #expect(usage.priorityRequests.failureCount == 0)
        #expect(usage.priorityRequests.inputTokens == 11)
        #expect(loadCounter.count == 1)
    }

    @Test
    func cancellationDuringProviderLoadIsCachedWithoutUsage() async throws {
        let loadCounter = LockedLoadCounter()
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) {
            loadCounter.recordLoad()
            throw CancellationError()
        }

        do {
            _ = try factory.makeCoordinator()
            Issue.record("The cancelled provider load unexpectedly succeeded.")
        } catch {
            #expect(error is CancellationError)
        }
        do {
            _ = try factory.localModelIdentity()
            Issue.record("The cached cancelled provider load unexpectedly succeeded.")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(loadCounter.count == 1)
        Self.expectZeroUsage(await usageCounter.snapshot())
    }

    @Test
    func providerCancellationCountsAttemptOnlyAndUsesCachedProviderAgain() async throws {
        let identity = try makeIdentity()
        let state = OneShotCancellationState()
        let provider = CancelFirstDecisionProvider(
            state: state,
            successfulProvider: SyntheticDecisionProvider(boundaryInputTokens: 7, priorityInputTokens: 11)
        )
        let loadCounter = LockedLoadCounter()
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) {
            loadCounter.recordLoad()
            return LoadedDecisionProvider(provider: provider, identity: identity)
        }
        let firstCoordinator = try factory.makeCoordinator()
        let source = try SegmentTextReference(
            segmentationRunID: "factory-cancel-run",
            segmentID: "factory-cancel-segment-1",
            asrRunID: "factory-cancel-asr",
            asrEventSeq: 1
        )
        let request = try ClauseBoundaryRequest(source: source, text: "今日は晴れです。明日は雨です", next: nil)

        switch await firstCoordinator.assessBoundaries(request) {
        case .answered:
            Issue.record("The one-shot cancelled boundary request unexpectedly succeeded.")
        case .failed(let message):
            Issue.record("The one-shot cancelled boundary request failed instead of cancelling: \(message)")
        case .cancelled:
            break
        }
        let afterCancellation = await usageCounter.snapshot()
        #expect(afterCancellation.sendCount == 1)
        #expect(afterCancellation.successCount == 0)
        #expect(afterCancellation.failureCount == 0)
        #expect(afterCancellation.inputTokens == 0)
        #expect(afterCancellation.boundaryRequests.sendCount == 1)
        #expect(afterCancellation.boundaryRequests.successCount == 0)
        #expect(afterCancellation.boundaryRequests.failureCount == 0)
        #expect(afterCancellation.boundaryRequests.inputTokens == 0)
        #expect(loadCounter.count == 1)

        let cachedCoordinator = try factory.makeCoordinator()
        switch await cachedCoordinator.assessBoundaries(request) {
        case .answered(let response, let record):
            #expect(response.inputTokens == 7)
            #expect(record.inputTokens == 7)
        case .failed(let message):
            Issue.record("The cached provider's second boundary request failed: \(message)")
        case .cancelled:
            Issue.record("The cached provider's second boundary request was unexpectedly cancelled.")
        }
        let finalUsage = await usageCounter.snapshot()
        #expect(finalUsage.sendCount == 2)
        #expect(finalUsage.successCount == 1)
        #expect(finalUsage.failureCount == 0)
        #expect(finalUsage.inputTokens == 7)
        #expect(finalUsage.boundaryRequests.sendCount == 2)
        #expect(finalUsage.boundaryRequests.successCount == 1)
        #expect(finalUsage.boundaryRequests.failureCount == 0)
        #expect(finalUsage.boundaryRequests.inputTokens == 7)
        #expect(state.callCount == 2)
        #expect(loadCounter.count == 1)
    }

    private static func expectFailure(
        _ operation: () throws -> Void,
        identicalTo expected: ProviderLoadFailure
    ) {
        do {
            try operation()
            Issue.record("The provider loader unexpectedly succeeded.")
        } catch {
            guard let actual = error as? ProviderLoadFailure else {
                Issue.record("The provider loader returned an unexpected error: \(error)")
                return
            }
            #expect(actual === expected)
        }
    }

    private static func expectZeroUsage(_ usage: DecisionUsageSnapshot) {
        #expect(usage.sendCount == 0)
        #expect(usage.inputTokens == 0)
        #expect(usage.successCount == 0)
        #expect(usage.failureCount == 0)
        #expect(usage.pendingBoundarySegmentCount == 0)
        #expect(usage.pendingPriorityClauseCount == 0)
        #expect(usage.boundaryRequests.sendCount == 0)
        #expect(usage.boundaryRequests.inputTokens == 0)
        #expect(usage.boundaryRequests.successCount == 0)
        #expect(usage.boundaryRequests.failureCount == 0)
        #expect(usage.priorityRequests.sendCount == 0)
        #expect(usage.priorityRequests.inputTokens == 0)
        #expect(usage.priorityRequests.successCount == 0)
        #expect(usage.priorityRequests.failureCount == 0)
    }
}
