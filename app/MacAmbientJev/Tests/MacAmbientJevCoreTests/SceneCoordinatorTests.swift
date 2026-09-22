import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func sceneCoordinatorPersistsInitialAndDetectedSceneStates() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let writer = try SessionWriter(sessionURL: root)
    let sessionID = UUID()
    let sampleRate = 10.0

    let speakerIDs = ["a", "b", "c"]
    let spans = stride(from: 0, to: 200, by: 5).enumerated().map {
        index,
        startFrame in
        SpeakerSpan(
            speakerID: speakerIDs[index % speakerIDs.count],
            startFrame: Int64(startFrame),
            endFrame: Int64(min(startFrame + 5, 200)),
            confidence: 1
        )
    }

    let coordinator = SceneCoordinator(
        sessionID: sessionID,
        runID: "scene-test",
        writer: writer,
        materializer: TranscriptMaterializer(sampleRate: sampleRate),
        config: .test,
        windowSeconds: 2,
        hopSeconds: 1
    )

    let result = try await coordinator.process(
        speakerSpans: spans,
        totalFrames: 200,
        sampleRate: sampleRate,
        existingEvents: [],
        activeRuns: ActiveRuns()
    )

    let sceneEvents = result.events.compactMap { event -> SceneState? in
        guard case .sceneChanged(let scene) = event.kind else {
            return nil
        }
        return scene
    }

    #expect(sceneEvents.first == .lecture)
    #expect(sceneEvents.contains(.discussionCandidate))
    #expect(sceneEvents.contains(.discussion))
}