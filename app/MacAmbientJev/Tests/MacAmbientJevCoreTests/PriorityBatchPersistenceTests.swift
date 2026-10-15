import Foundation
import Testing
@testable import MacAmbientJevCore

@Test(arguments: [false, true])
func everyFailedPriorityBatchIsPendingOnItsOwnInBoundedBatches(retry: Bool) async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let raw = (1...81).map { "本文\($0)。" }.joined()
    _ = try publishLocal(root: root, events: try await writeTranscript([raw], root: root, sessionID: id))
    let scope: DecisionEnrichmentScope
    let boundaryRunID: String?
    if retry {
        let previous = try await buildAndPublish(
            root: root, sessionID: id,
            provider: ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
                throw DecisionResponseError.missingAnswer
            }),
            scope: .all
        )
        scope = .retry(boundarySegments: [], clauses: Set(previous.pendingPriorityClauses))
        boundaryRunID = previous.boundaryRunID
    } else {
        scope = .all
        boundaryRunID = nil
    }
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(
        root: root, sessionID: id, provider: provider, scope: scope,
        counter: counter, boundaryRunID: boundaryRunID
    )
    let assigned = try eventObjects(root).filter {
        $0["event_type"] as? String == ClauseEventType.priorityAssigned
            && $0["processing_run_id"] as? String == result.priorityRunID
    }
    let payloads = try assigned.map { try #require($0["payload"] as? [String: Any]) }
    let assignments = try payloads.map { try #require($0["assignments"] as? [[String: Any]]) }
    #expect(assignments.map(\.count) == [40, 40, 1])
    #expect(payloads.allSatisfy { $0["request"] is NSNull })
    #expect(await provider.priorityRequests.map(\.count) == [40, 40, 1])
    #expect(result.pendingPriorityClauses.count == 81)
    let recorded = result.events.compactMap { event -> ContentPriorityAssignedPayload? in
        guard event.processingRunID == result.priorityRunID,
              case .contentPriorityAssigned(let payload) = event.kind else { return nil }
        return payload
    }
    #expect(recorded.flatMap { $0.assignments.map(\.reference) } == result.pendingPriorityClauses)
    #expect(await provider.boundaryRequests.count == (retry ? 0 : 1))
    #expect(await counter.snapshot().priorityRequests.sendCount == 3)
    #expect(await counter.snapshot().priorityRequests.failureCount == 3)
    #expect(await counter.snapshot().pendingPriorityClauseCount == 81)
    #expect(assignments.flatMap { $0 }.allSatisfy {
        let decision = $0["decision"] as? [String: Any]
        return $0["needs_retry"] as? Bool == true
            && decision?["reason"] as? String == "request_failed"
    })
    let saved = try readPublished(root: root)
    #expect(saved == result.materializedSegments)
    #expect(saved[0].clauseState == .priorityPending)
    #expect(saved[0].displayText == raw)
    #expect(saved[0].clauseSlices.allSatisfy { $0.priority == nil && $0.needsRetry })
}

private actor PriorityAvailabilityGate {
    private var started = false
    private var onStart: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        onStart?.resume()
        onStart = nil
        await withCheckedContinuation { response = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { onStart = $0 }
    }

    func release() {
        response?.resume()
        response = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func cancellationDuringPriorityAvailabilityDoesNotSendOrConsumeTheBatch() async throws {
    let gate = PriorityAvailabilityGate()
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let reference = try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_0")
    let task = Task {
        var batches = try ClausePriorityBatches(targets: [(reference, "本文")])
        do {
            _ = try await batches.next {
                await gate.suspend()
                return .available(decisions)
            }
            return (cancelled: false, hasRemaining: batches.hasRemaining)
        } catch is CancellationError {
            return (cancelled: true, hasRemaining: batches.hasRemaining)
        }
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()
    let result = try await task.value
    #expect(result.cancelled)
    #expect(result.hasRemaining)
    #expect(await provider.priorityRequests.isEmpty)
    #expect(await counter.snapshot().sendCount == 0)
}

@Test
func failedBoundaryRequestLeavesOnlyItsSourcePendingAndPrioritiesContinue() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let raw = (1...81).map { "本文\($0)。" }.joined()
    _ = try publishLocal(root: root, events: try await writeTranscript([raw, "後続。失敗"], root: root, sessionID: id))
    let provider = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s02" { throw DecisionResponseError.missingAnswer }
        return try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)
    let result = try await buildAndPublish(root: root, sessionID: id, provider: provider, scope: .all)
    let payloads = result.events.compactMap { event -> ContentPriorityAssignedPayload? in
        guard event.processingRunID == result.priorityRunID,
              case .contentPriorityAssigned(let payload) = event.kind else { return nil }
        return payload
    }
    #expect(payloads.map { $0.assignments.count } == [40, 40, 1])
    #expect(payloads.allSatisfy { payload in
        payload.request != nil && payload.assignments.allSatisfy { $0.priority == .primary && !$0.needsRetry }
    })
    #expect(result.pendingBoundarySegments.map(\.segmentID) == ["s02"])
    #expect(result.pendingPriorityClauses.isEmpty)
    #expect(await provider.boundaryRequests.map(\.source.segmentID) == ["s01", "s02"])
    #expect(await provider.priorityRequests.map(\.count) == [40, 40, 1])
    #expect(try readPublished(root: root).map(\.clauseState) == [.classified, .boundaryPending])
}

@Test
func priorityBatchesResumeAfterAnUnsentAvailabilityBatch() async throws {
    let targets = try (1...41).map {
        (reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c\($0)_0"), text: "本文\($0)")
    }
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: lowForBackchannel)
    let counter = DecisionUsageCounter()
    let decisions = DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter)
    let failure = "判定エンジンを初期化できませんでした: モデルがありません"
    var batches = try ClausePriorityBatches(targets: targets)
    let pending = try await batches.next { .pending(.initializationFailed, failure) }
    #expect(pending.assignments.map(\.reference) == targets.prefix(40).map(\.reference))
    #expect(pending.request == nil)
    #expect(pending.assignments.allSatisfy {
        $0.priority == nil && $0.needsRetry
            && $0.decision == .retryPending(reason: .initializationFailed, message: failure)
    })
    #expect(await counter.snapshot().sendCount == 0)

    let answered = try await batches.next { .available(decisions) }
    #expect(answered.assignments.map(\.reference) == [targets[40].reference])
    #expect(answered.assignments.first?.priority == .primary)
    #expect(answered.assignments.first?.needsRetry == false)
    #expect(answered.request != nil)
    #expect(!batches.hasRemaining)
    #expect(await provider.priorityRequests.map { $0.map(\.text) } == [["本文41"]])
    #expect(await counter.snapshot().priorityRequests.successCount == 1)
}
