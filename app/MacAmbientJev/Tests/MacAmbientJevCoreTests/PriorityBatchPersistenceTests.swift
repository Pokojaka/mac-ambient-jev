import Foundation
import Testing
@testable import MacAmbientJevCore

private struct PriorityRetryFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

@Test
func everyFailedFinalPriorityBatchIsPendingOnItsOwnInBoundedBatches() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let raw = (1...81).map { "本文\($0)。" }.joined()
    _ = try publishLocal(root: root, events: try await writeTranscript([raw], root: root, sessionID: id))
    let provider = ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]), priority: { _ in
        throw DecisionResponseError.missingAnswer
    })
    let counter = DecisionUsageCounter()
    let result = try await buildAndPublish(
        root: root, sessionID: id, provider: provider, scope: .all, counter: counter
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
    #expect(await provider.boundaryRequests.count == 1)
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

@Test
func failedPriorityRetryStopsAfterFirstBatchAndKeepsPublishedSnapshot() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let raw = (1...81).map { "本文\($0)。" }.joined()
    _ = try publishLocal(root: root, events: try await writeTranscript([raw], root: root, sessionID: sessionID))
    let initialProvider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: { _ in throw DecisionResponseError.missingAnswer }
    )
    let initial = try await buildAndPublish(root: root, sessionID: sessionID, provider: initialProvider, scope: .all)
    #expect(initial.pendingPriorityClauses.count == 81)
    let publishedMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    let publishedTranscript = try readPublished(root: root)

    let failureMessage = "priority retry failed deterministically"
    let retryRunID = "priority_retry_failed"
    let retryProvider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: { _ in throw PriorityRetryFailure(message: failureMessage) }
    )
    await #expect(throws: DecisionEnrichmentError.retryFailedDurably(failureMessage)) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: retryProvider,
            scope: .retry(boundarySegments: [], clauses: Set(initial.pendingPriorityClauses)),
            boundaryRunID: initial.boundaryRunID, priorityRunID: retryRunID
        )
    }

    #expect(await retryProvider.priorityRequests.map(\.count) == [40])
    #expect(await retryProvider.boundaryRequests.isEmpty)
    let afterFailureMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    #expect(afterFailureMetadata == publishedMetadata)
    #expect(try readPublished(root: root) == publishedTranscript)
    let retryEvents = try eventObjects(root).filter { $0["processing_run_id"] as? String == retryRunID }
    #expect(retryEvents.filter { $0["event_type"] as? String == "processing.run.started" }.count == 1)
    #expect(!retryEvents.contains { $0["event_type"] as? String == ClauseEventType.priorityAssigned })
    let completions = retryEvents.filter { $0["event_type"] as? String == "processing.run.completed" }
    #expect(completions.count == 1)
    let completion = try #require(completions.first?["payload"] as? [String: Any])
    #expect(completion["stage"] as? String == ProcessingStage.contentPriority.rawValue)
    #expect(completion["succeeded"] as? Bool == false)
    #expect(completion["completed_count"] as? Int == 0)
    #expect(completion["failed_count"] as? Int == 40)
}

@Test
func failedBoundaryRetryStopsAtTheFirstRequestedFailureAndKeepsPublishedSnapshot() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["前。続く", "後。"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let initialProvider = ScriptedDecisionProvider(boundary: { request in
        if request.source.segmentID == "s01" {
            throw DecisionResponseError.missingAnswer
        }
        return try punctuationBoundaries(continuing: [], fillerRangesBySegment: [:])(request)
    }, priority: lowForBackchannel)
    let initial = try await buildAndPublish(root: root, sessionID: sessionID, provider: initialProvider, scope: .all)
    #expect(initial.pendingBoundarySegments == [try source("s01", in: events)])
    #expect(try source("s02", in: events).segmentID == "s02")
    let publishedMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    let publishedTranscript = try readPublished(root: root)

    let failureMessage = "boundary retry failed deterministically"
    let retryRunID = "boundary_retry_failed"
    let retryProvider = ScriptedDecisionProvider(
        boundary: { _ in throw PriorityRetryFailure(message: failureMessage) },
        priority: lowForBackchannel
    )
    await #expect(throws: DecisionEnrichmentError.retryFailedDurably(failureMessage)) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: retryProvider,
            scope: .retry(boundarySegments: Set(initial.pendingBoundarySegments), clauses: []),
            boundaryRunID: retryRunID
        )
    }

    #expect(await retryProvider.boundaryRequests.count == 1)
    #expect(await retryProvider.priorityRequests.isEmpty)
    let afterFailureMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    #expect(afterFailureMetadata == publishedMetadata)
    #expect(try readPublished(root: root) == publishedTranscript)
    let retryEvents = try eventObjects(root).filter { $0["processing_run_id"] as? String == retryRunID }
    #expect(retryEvents.filter { $0["event_type"] as? String == "processing.run.started" }.count == 1)
    #expect(!retryEvents.contains { $0["event_type"] as? String == ClauseEventType.priorityAssigned })
    let completions = retryEvents.filter { $0["event_type"] as? String == "processing.run.completed" }
    #expect(completions.count == 1)
    let completion = try #require(completions.first?["payload"] as? [String: Any])
    #expect(completion["stage"] as? String == ProcessingStage.clauseBoundary.rawValue)
    #expect(completion["succeeded"] as? Bool == false)
    #expect(completion["completed_count"] as? Int == 0)
    #expect(completion["failed_count"] as? Int == 1)
}

@Test
func failedBoundaryRebuildThenPriorityFailureEndsBothRunsAndPreservesSnapshot() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["本文。"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let initialProvider = ScriptedDecisionProvider(
        boundary: { _ in throw DecisionResponseError.missingAnswer },
        priority: lowForBackchannel
    )
    let initial = try await buildAndPublish(root: root, sessionID: sessionID, provider: initialProvider, scope: .all)
    #expect(initial.pendingBoundarySegments.count == 1)
    #expect(initial.pendingPriorityClauses.isEmpty)
    let publishedMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    let publishedTranscript = try readPublished(root: root)

    let failureMessage = "priority retry after boundary rebuild failed deterministically"
    let boundaryRetryRunID = "boundary_retry_before_priority_failure"
    let priorityRetryRunID = "priority_retry_after_boundary_rebuild_failed"
    let retryProvider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: { _ in throw PriorityRetryFailure(message: failureMessage) }
    )
    await #expect(throws: DecisionEnrichmentError.retryFailedDurably(failureMessage)) {
        try await buildAndPublish(
            root: root, sessionID: sessionID, provider: retryProvider,
            scope: .retry(
                boundarySegments: Set(initial.pendingBoundarySegments),
                clauses: Set(initial.pendingPriorityClauses)
            ),
            boundaryRunID: boundaryRetryRunID, priorityRunID: priorityRetryRunID
        )
    }

    #expect(await retryProvider.boundaryRequests.count == 1)
    #expect(await retryProvider.priorityRequests.map(\.count) == [1])
    #expect(try #require(try ProcessingMetadataStore(sessionURL: root).load()) == publishedMetadata)
    #expect(try readPublished(root: root) == publishedTranscript)
    let retryEvents = try eventObjects(root).filter {
        let runID = $0["processing_run_id"] as? String
        return runID == boundaryRetryRunID || runID == priorityRetryRunID
    }
    let boundaryEvents = retryEvents.filter { $0["processing_run_id"] as? String == boundaryRetryRunID }
    let priorityEvents = retryEvents.filter { $0["processing_run_id"] as? String == priorityRetryRunID }
    #expect(boundaryEvents.filter { $0["event_type"] as? String == "processing.run.started" }.count == 1)
    #expect(priorityEvents.filter { $0["event_type"] as? String == "processing.run.started" }.count == 1)
    #expect(!priorityEvents.contains { $0["event_type"] as? String == ClauseEventType.priorityAssigned })

    let boundaryCompletions = boundaryEvents.filter { $0["event_type"] as? String == "processing.run.completed" }
    #expect(boundaryCompletions.count == 1)
    let boundaryCompletion = try #require(boundaryCompletions.first?["payload"] as? [String: Any])
    #expect(boundaryCompletion["stage"] as? String == ProcessingStage.clauseBoundary.rawValue)
    #expect(boundaryCompletion["succeeded"] as? Bool == false)
    #expect(boundaryCompletion["completed_count"] as? Int == 1)
    #expect(boundaryCompletion["failed_count"] as? Int == 0)

    let priorityCompletions = priorityEvents.filter { $0["event_type"] as? String == "processing.run.completed" }
    #expect(priorityCompletions.count == 1)
    let priorityCompletion = try #require(priorityCompletions.first?["payload"] as? [String: Any])
    #expect(priorityCompletion["stage"] as? String == ProcessingStage.contentPriority.rawValue)
    #expect(priorityCompletion["succeeded"] as? Bool == false)
    #expect(priorityCompletion["completed_count"] as? Int == 0)
    #expect(priorityCompletion["failed_count"] as? Int == 1)
}

private actor FailedCompletionWriteGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseAfterDurableAppend() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        enteredContinuation?.resume()
        enteredContinuation = nil
    }
}

private actor GatedDecisionEventWriter: DecisionEventWriting {
    private let writer: SessionWriter
    private let gate: FailedCompletionWriteGate
    nonisolated let eventsURL: URL
    private var pausedAfterFirstFailedCompletion = false

    init(writer: SessionWriter, eventsURL: URL, gate: FailedCompletionWriteGate) {
        self.writer = writer
        self.gate = gate
        self.eventsURL = eventsURL
    }

    func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) async throws -> EventEnvelope<Payload> {
        try await writer.append(draft)
    }

    func appendFailedRetryCompletion(
        _ draft: EventDraft<ProcessingRunCompletedPayload>
    ) async throws -> EventEnvelope<ProcessingRunCompletedPayload> {
        let envelope = try await writer.appendFailedRetryCompletion(draft)
        if !pausedAfterFirstFailedCompletion {
            pausedAfterFirstFailedCompletion = true
            await gate.pauseAfterDurableAppend()
        }
        return envelope
    }
}

@Test(.timeLimit(.minutes(10)))
func cancelledFailureCleanupClosesBoundaryAndPriorityRuns() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID()
    let events = try await writeTranscript(["本文。"], root: root, sessionID: sessionID)
    _ = try publishLocal(root: root, events: events)
    let initialProvider = ScriptedDecisionProvider(
        boundary: { _ in throw DecisionResponseError.missingAnswer },
        priority: lowForBackchannel
    )
    let initial = try await buildAndPublish(root: root, sessionID: sessionID, provider: initialProvider, scope: .all)
    #expect(initial.pendingBoundarySegments.count == 1)
    #expect(initial.pendingPriorityClauses.isEmpty)
    let publishedMetadata = try #require(try ProcessingMetadataStore(sessionURL: root).load())
    let publishedTranscript = try readPublished(root: root)
    let activeRuns = try requireValue(publishedMetadata.activeRuns)
    let existingEvents = try EventLogTranscriptReader().events(lines: eventLines(root), activeRuns: activeRuns)

    let failureMessage = "priority retry after boundary rebuild failed deterministically"
    let boundaryRetryRunID = "boundary_retry_cancelled_cleanup"
    let priorityRetryRunID = "priority_retry_cancelled_cleanup"
    let retryProvider = ScriptedDecisionProvider(
        boundary: punctuationBoundaries(continuing: [], fillerRangesBySegment: [:]),
        priority: { _ in throw PriorityRetryFailure(message: failureMessage) }
    )
    let gate = FailedCompletionWriteGate()
    defer { Task { await gate.release() } }
    let writer = try SessionWriter(sessionURL: root)
    let gatedWriter = GatedDecisionEventWriter(writer: writer, eventsURL: await writer.eventsURL, gate: gate)
    let counter = DecisionUsageCounter()
    let coordinator = DecisionEnrichmentCoordinator(
        sessionID: sessionID,
        boundaryRunID: boundaryRetryRunID,
        priorityRunID: priorityRetryRunID,
        writer: gatedWriter,
        decisions: DecisionCoordinator(provider: retryProvider, identity: testDecisionIdentity, usageCounter: counter),
        usageCounter: counter,
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let task = Task {
        try await coordinator.process(
            existingEvents: existingEvents,
            activeRuns: activeRuns,
            scope: .retry(
                boundarySegments: Set(initial.pendingBoundarySegments),
                clauses: Set(initial.pendingPriorityClauses)
            ),
            reusableDecisions: [:],
            onEvent: nil
        )
    }

    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()
    let result = await task.result

    switch result {
    case .success:
        #expect(Bool(false), "A failed retry must not return a publishable result")
    case .failure(let error):
        #expect((error as? DecisionEnrichmentError) == .retryFailedDurably(failureMessage))
    }

    let retryEvents = try eventObjects(root).filter {
        let runID = $0["processing_run_id"] as? String
        return runID == boundaryRetryRunID || runID == priorityRetryRunID
    }
    let failedCompletions = retryEvents.filter {
        $0["event_type"] as? String == "processing.run.completed"
    }
    #expect(failedCompletions.count == 2)
    #expect(Set(failedCompletions.compactMap { $0["processing_run_id"] as? String }) == Set([
        boundaryRetryRunID, priorityRetryRunID
    ]))
    #expect(failedCompletions.allSatisfy {
        ($0["payload"] as? [String: Any])?["succeeded"] as? Bool == false
    })
    let completionStages = Dictionary(uniqueKeysWithValues: failedCompletions.compactMap { event -> (String, String)? in
        guard let runID = event["processing_run_id"] as? String,
              let payload = event["payload"] as? [String: Any],
              let stage = payload["stage"] as? String else { return nil }
        return (runID, stage)
    })
    #expect(completionStages == [
        boundaryRetryRunID: ProcessingStage.clauseBoundary.rawValue,
        priorityRetryRunID: ProcessingStage.contentPriority.rawValue,
    ])
    #expect(try #require(try ProcessingMetadataStore(sessionURL: root).load()) == publishedMetadata)
    let displayedAfterRetry = try readPublished(root: root)
    #expect(displayedAfterRetry.map(\.displayText) == publishedTranscript.map(\.displayText))
    #expect(try DecisionRetryAnalyzer().hasUnpublishedDecisionRun(lines: eventLines(root), activeRuns: activeRuns) == false)
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

@Test(.timeLimit(.minutes(10)))
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
