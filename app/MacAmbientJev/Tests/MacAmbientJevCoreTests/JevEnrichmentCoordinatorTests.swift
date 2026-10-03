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
            text: "えー、RSAでは公開鍵を使います"
        )
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr"
        )
    )

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
            text: "重要な発話"
        )
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr"
        )
    )

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
            text: "えー"
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
            text: "重要な発話"
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
            text: " \n"
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

    let result = try await coordinator.process(
        existingEvents: events,
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr",
            contentPriority: "priority-old"
        ),
        retryOnlySegmentIDs: ["seg-2", "seg-empty"]
    )

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
        == ["carried_over": ["source_run_id": "priority-old"]])
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
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "a", text: "一つ目"),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "b", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg", segmentID: "b", text: "二つ目")
    ]

    await #expect(throws: JevEnrichmentError.noPriorityToCarryOver(segmentID: "b")) {
        try await coordinator.process(
            existingEvents: events,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"),
            retryOnlySegmentIDs: ["a"]
        )
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
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "blank", text: " \n  "),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "spoken", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg", segmentID: "spoken", text: "聞き取れませんでした。")
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr"),
        retryOnlySegmentIDs: ["blank", "spoken"]
    )

    #expect(await provider.recordedPriorityCalls() == ["聞き取れませんでした。"])
    #expect(result.retryPendingSegmentIDs.isEmpty)
}
