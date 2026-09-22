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

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        SemanticSceneDecision(
            cue: .none,
            confidence: 1
        )
    }
}

private struct ThrowingPriorityProvider: DecisionProvider {
    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision {
        throw URLError(.notConnectedToInternet)
    }

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        throw URLError(.notConnectedToInternet)
    }
}

@Test
func jevEnrichmentAppliesConservativePriorityPolicy() async throws {
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
            )
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
    #expect(
        result.materializedSegments.first?.contentPriority
            == .primary
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
            provider: ThrowingPriorityProvider()
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
