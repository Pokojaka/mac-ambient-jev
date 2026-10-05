import Foundation
import Testing
@testable import MacAmbientJevCore

private struct FixedPriorityProvider: DecisionProvider {
    let decision: ContentPriorityDecision

    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision {
        decision
    }
}

private struct ThrowingPriorityProvider: DecisionProvider {
    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision {
        throw URLError(.notConnectedToInternet)
    }
}

@Test
func jevEnrichmentDemotesConfidentLowPriorityUtterance() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-test",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: FixedPriorityProvider(
                decision: ContentPriorityDecision(
                    priority: .lowPriority,
                    confidence: 0.99,
                    model: "jev-test",
                    inputTokens: 12
                )
            ),
            usageCounter: JevUsageCounter()
        ),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )

    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1,
            segmentationRunID: "seg",
            segmentID: "seg-1",
            startFrame: 0,
            endFrame: 1_000
        ),
        .asrCompleted(
            seq: 2,
            runID: "asr",
            segmentationRunID: "seg",
            segmentID: "seg-1",
            text: "えー、RSAでは公開鍵を使います",
            detectedLanguage: nil
        )
    ]

    let result = try await coordinator.process(existingEvents: events, activeRuns: ActiveRuns(
        segmentation: "seg",
        asr: "asr"
    ), scope: .all, reusableDecisions: [:], completeRun: true, onAssignment: nil)

    #expect(result.retryPendingSegmentIDs.isEmpty)
    #expect(result.stopReason == nil)
    #expect(
        result.materializedSegments.first?.contentPriority
            == .lowPriority
    )
}

@Test
func jevFailureKeepsPrimaryAndRecordsRetryPending() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-test",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: ThrowingPriorityProvider(),
            usageCounter: JevUsageCounter()
        ),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )

    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1,
            segmentationRunID: "seg",
            segmentID: "seg-1",
            startFrame: 0,
            endFrame: 1_000
        ),
        .asrCompleted(
            seq: 2,
            runID: "asr",
            segmentationRunID: "seg",
            segmentID: "seg-1",
            text: "重要な発話",
            detectedLanguage: nil
        )
    ]

    let result = try await coordinator.process(existingEvents: events, activeRuns: ActiveRuns(
        segmentation: "seg",
        asr: "asr"
    ), scope: .all, reusableDecisions: [:], completeRun: true, onAssignment: nil)

    #expect(result.retryPendingSegmentIDs == ["seg-1"])
    #expect(
        result.materializedSegments.first?.contentPriority
            == .primary
    )
}


private actor CountingRetryProvider: DecisionProvider {
    private var priorityCalls: [String] = []

    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision {
        priorityCalls.append(text)
        return ContentPriorityDecision(
            priority: .primary,
            confidence: 1,
            model: "jev-test",
            inputTokens: 4
        )
    }


    func recordedPriorityCalls() -> [String] {
        priorityCalls
    }
}

@Test
func jevRetryCallsOnlyDeferredSegmentsAndCarriesForwardResolvedPriority() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = CountingRetryProvider()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-retry",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: provider,
            usageCounter: JevUsageCounter()
        ),
        materializer: TranscriptMaterializer(
            sampleRate: 1_000
        )
    )

    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1,
            segmentationRunID: "seg",
            segmentID: "seg-1",
            startFrame: 0,
            endFrame: 1_000
        ),
        .asrCompleted(
            seq: 2,
            runID: "asr",
            segmentationRunID: "seg",
            segmentID: "seg-1",
            text: "えー",
            detectedLanguage: nil
        ),
        .segmentCreated(
            seq: 3,
            segmentationRunID: "seg",
            segmentID: "seg-2",
            startFrame: 1_000,
            endFrame: 2_000
        ),
        .asrCompleted(
            seq: 4,
            runID: "asr",
            segmentationRunID: "seg",
            segmentID: "seg-2",
            text: "重要な発話",
            detectedLanguage: nil
        ),
        .segmentCreated(
            seq: 5,
            segmentationRunID: "seg",
            segmentID: "seg-empty",
            startFrame: 2_000,
            endFrame: 3_000
        ),
        .asrCompleted(
            seq: 6,
            runID: "asr",
            segmentationRunID: "seg",
            segmentID: "seg-empty",
            text: " \n",
            detectedLanguage: nil
        ),
        .contentPriority(
            seq: 7,
            runID: "priority-old",
            segmentID: "seg-1",
            priority: .lowPriority
        ),
        .contentPriority(
            seq: 8,
            runID: "priority-old",
            segmentID: "seg-2",
            priority: .primary
        )
    ]

    let result = try await coordinator.process(existingEvents: events, activeRuns: ActiveRuns(
        segmentation: "seg",
        asr: "asr",
        contentPriority: "priority-old"
    ), scope: .retry(["seg-2", "seg-empty"]), reusableDecisions: [:], completeRun: true, onAssignment: nil)

    #expect(
        await provider.recordedPriorityCalls()
            == ["重要な発話"]
    )

    let byID = Dictionary(
        uniqueKeysWithValues:
            result.materializedSegments.map {
                ($0.segmentID, $0.contentPriority)
            }
    )
    #expect(byID["seg-1"] == .some(.lowPriority))
    #expect(byID["seg-2"] == .some(.primary))
    #expect(!result.retryPendingSegmentIDs.contains("seg-empty"))

    let payloads = try persistedPriorityPayloads(root: root)
    #expect(payloads["seg-1"]?["decision"] as? [String: [String: String]]
        == ["carried_over": [
            "source_run_id": "priority-old",
            "source_segmentation_run_id": "seg",
            "source_segment_id": "seg-1"
        ]])
    #expect(payloads["seg-1"]?["priority"] as? String == "lowPriority")
    #expect(payloads["seg-1"]?["needs_retry"] as? Bool == false)
    let classified = try #require(
        (payloads["seg-2"]?["decision"] as? [String: Any])?["classified"] as? [String: Any]
    )
    #expect(classified["model"] as? String == "jev-test")
    #expect(classified["input_tokens"] as? Int == 4)
}

private func persistedPriorityPayloads(root: URL) throws -> [String: [String: Any]] {
    let lines = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    ).lines
    var payloads: [String: [String: Any]] = [:]
    for line in lines {
        let event = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        guard event["event_type"] as? String == "content_priority.assigned",
              let segmentID = event["segment_id"] as? String else { continue }
        payloads[segmentID] = try #require(event["payload"] as? [String: Any])
    }
    return payloads
}

@Test
func retryRunWithoutAPriorityToCarryOverFailsBeforeSendingAnything() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = CountingRetryProvider()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-retry",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: JevUsageCounter()),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "a", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "a", text: "一つ目", detectedLanguage: nil),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "b", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg", segmentID: "b", text: "二つ目", detectedLanguage: nil)
    ]

    await #expect(throws: JevEnrichmentError.noPriorityToCarryOver(segmentID: "b")) {
        try await coordinator.process(existingEvents: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"), scope: .retry(["a"]), reusableDecisions: [:], completeRun: true, onAssignment: nil)
    }
    #expect(await provider.recordedPriorityCalls().isEmpty)
}

@Test
func contentPriorityPayloadRejectsNeedsRetryThatContradictsTheDecision() throws {
    let json = Data("""
    {"priority":"primary","needs_retry":false,"decision":{"retry_pending":{}}}
    """.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    #expect(throws: DecodingError.self) {
        try decoder.decode(ContentPriorityEventPayload.self, from: json)
    }
}

@Test
func jevEnrichmentSkipsEmptyTextButClassifiesEverythingSpoken() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = CountingRetryProvider()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(),
        runID: "priority-empty-filter",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: JevUsageCounter()),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "blank", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "blank", text: " \n  ", detectedLanguage: nil),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "spoken", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg", segmentID: "spoken", text: "聞き取れませんでした。", detectedLanguage: nil)
    ]

    let result = try await coordinator.process(existingEvents: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"), scope: .retry(["blank", "spoken"]), reusableDecisions: [:], completeRun: true, onAssignment: nil)

    #expect(await provider.recordedPriorityCalls() == ["聞き取れませんでした。"])
    #expect(result.retryPendingSegmentIDs.isEmpty)
}

private func liveReuseEvents(_ texts: [(String, String)]) -> [TranscriptEvent] {
    texts.enumerated().flatMap { (index: Int, entry: (String, String)) -> [TranscriptEvent] in
        let created = TranscriptEvent.segmentCreated(
            seq: UInt64(index * 2 + 1), segmentationRunID: "seg", segmentID: entry.0,
            startFrame: Int64(index * 1_000), endFrame: Int64((index + 1) * 1_000))
        let completed = TranscriptEvent.asrCompleted(
            seq: UInt64(index * 2 + 2), runID: "asr", segmentationRunID: "seg",
            segmentID: entry.0, text: entry.1, detectedLanguage: nil)
        return [created, completed]
    }
}

@Test
func normalizedLiveReuseDoesNotReuseChangedOrPendingText() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = CountingRetryProvider()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(), runID: "final", writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: JevUsageCounter()),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let carried = ContentPriorityEventPayload(priority: .lowPriority, decision: .carriedOver(
        sourceRunID: "live-priority", sourceSegmentationRunID: "live-seg", sourceSegmentID: "original"
    ))
    _ = try await coordinator.process(
        existingEvents: liveReuseEvents([("same", " \n話題\n "), ("changed", "話題です"), ("pending", "未分類")]),
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"), scope: .all,
        reusableDecisions: ["話題": carried, "未分類": .init(priority: .primary, decision: .retryPending)],
        completeRun: true, onAssignment: nil
    )
    #expect(await provider.recordedPriorityCalls() == ["話題です", "未分類"])
    let payloads = try persistedPriorityPayloads(root: root)
    #expect(payloads["same"]?["decision"] as? [String: [String: String]] == [
        "carried_over": ["source_run_id": "live-priority", "source_segmentation_run_id": "live-seg", "source_segment_id": "original"]
    ])
}

private struct StatusFailurePriorityProvider: DecisionProvider {
    let status: Int
    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        throw JevClientError.httpStatus(status)
    }
}

@Test(arguments: [401, 503])
func incrementalUnavailableRunStopsLaterRequestsAndCountsAllAssignments(status: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let counter = JevUsageCounter()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(), runID: "live", writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: StatusFailurePriorityProvider(status: status), usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let runs = ActiveRuns(segmentation: "seg", asr: "asr")
    let first = try await coordinator.process(
        existingEvents: liveReuseEvents([("a", "一")]), activeRuns: runs, scope: .all,
        reusableDecisions: [:], completeRun: false, onAssignment: nil
    )
    let second = try await coordinator.process(
        existingEvents: liveReuseEvents([("a", "一"), ("b", "二")]), activeRuns: runs, scope: .all,
        reusableDecisions: [:], completeRun: true, onAssignment: nil
    )
    #expect(await counter.snapshot().sendCount == 1)
    let expectedReason: JevBatchStopReason = status == 401 ? .authorizationRejected : .providerUnavailable
    #expect(first.stopReason == expectedReason)
    #expect(second.stopReason == expectedReason)
    #expect(second.retryPendingSegmentIDs == ["b"])
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: root.appending(path: "events.jsonl"))).lines
    let events = try lines.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    #expect(events.filter { $0["event_type"] as? String == "content_priority.assigned" }.count == 2)
    let completed = try #require(events.last?["payload"] as? [String: Any])
    #expect(completed["completed_count"] as? Int == 2)
    #expect(completed["failed_count"] as? Int == 2)
}

private actor SuspendedPriorityProvider: DecisionProvider {
    private var response: CheckedContinuation<ContentPriorityDecision, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        await withCheckedContinuation { continuation in
            response = continuation
            hasEntered = true
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func respond() {
        response?.resume(returning: .init(priority: .lowPriority, confidence: 1, model: nil, inputTokens: nil))
        response = nil
    }
}

@Test
func cancellationDoesNotSaveReturnedClassification() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = SuspendedPriorityProvider()
    let counter = JevUsageCounter()
    let coordinator = JevEnrichmentCoordinator(
        sessionID: UUID(), runID: "live", writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: provider, usageCounter: counter),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let task = Task {
        try await coordinator.process(
            existingEvents: liveReuseEvents([("a", "一")]),
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"), scope: .all,
            reusableDecisions: [:], completeRun: false, onAssignment: nil
        )
    }
    await provider.waitUntilEntered()
    task.cancel()
    await provider.respond()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try persistedPriorityPayloads(root: root).isEmpty)
    #expect(await counter.snapshot().successCount == 0)
}
