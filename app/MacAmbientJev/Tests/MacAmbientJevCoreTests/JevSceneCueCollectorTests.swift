import Foundation
import Testing
@testable import MacAmbientJevCore

private struct SceneCueProvider: DecisionProvider {
    func classifyPriority(
        text: String
    ) async throws -> ContentPriorityDecision {
        ContentPriorityDecision(
            priority: .primary,
            confidence: 1
        )
    }

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        if currentText.contains("話し合って") {
            return SemanticSceneDecision(
                cue: .discussionStart,
                confidence: 0.95,
                model: "jev-test",
                inputTokens: 9
            )
        }

        return SemanticSceneDecision(
            cue: .none,
            confidence: 0.9,
            model: "jev-test",
            inputTokens: 5
        )
    }
}

private actor RecordingSceneCueProvider: DecisionProvider {
    private var currentTexts: [String] = []

    func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        ContentPriorityDecision(priority: .primary, confidence: 1)
    }

    func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        currentTexts.append(currentText)
        return SemanticSceneDecision(cue: .none, confidence: 1)
    }

    func recordedTexts() -> [String] { currentTexts }
}

@Test
func jevSceneCueCollectorMapsTranscriptTimeToCanonicalFrame() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let collector = JevSceneCueCollector(
        sessionID: UUID(),
        runID: "jev-scene-test",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(
            provider: SceneCueProvider()
        ),
        sampleRate: 48_000
    )

    let segments = [
        MaterializedTranscriptSegment(
            segmentID: "seg-1",
            startMilliseconds: 1_500,
            endMilliseconds: 2_000,
            text: "では隣の人と話し合ってください",
            scene: .lecture,
            speakers: [],
            scopeSpans: [],
            contentPriority: nil
        )
    ]

    let result = try await collector.collect(segments: segments)

    #expect(result.retryPendingSegmentIDs.isEmpty)
    #expect(result.cues.count == 1)
    #expect(result.cues[0].frame == 72_000)
    #expect(result.cues[0].cue == .discussionStart)
}

@Test
func jevSceneCueCollectorSkipsEmptyTextButClassifiesEverythingSpoken() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = RecordingSceneCueProvider()
    let collector = JevSceneCueCollector(
        sessionID: UUID(),
        runID: "jev-scene-empty-filter",
        writer: try SessionWriter(sessionURL: root),
        decisions: JevDecisionCoordinator(provider: provider),
        sampleRate: 48_000
    )
    let segments = [
        "blank": " \n",
        "spoken": "聞き取れませんでした。"
    ].map { id, text in
        MaterializedTranscriptSegment(
            segmentID: id,
            startMilliseconds: 0,
            endMilliseconds: 500,
            text: text,
            scene: .lecture,
            speakers: [],
            scopeSpans: [],
            contentPriority: nil
        )
    }

    let result = try await collector.collect(segments: segments)

    #expect(await provider.recordedTexts() == ["聞き取れませんでした。"])
    #expect(result.retryPendingSegmentIDs.isEmpty)
}
