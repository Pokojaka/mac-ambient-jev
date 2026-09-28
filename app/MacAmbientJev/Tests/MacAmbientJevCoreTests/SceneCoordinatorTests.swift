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

@Test
func semanticCueOnlySeedsCandidateUntilAcousticsConfirm() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let writer = try SessionWriter(sessionURL: root)
    let coordinator = SceneCoordinator(
        sessionID: UUID(),
        runID: "scene-semantic-test",
        writer: writer,
        materializer: TranscriptMaterializer(sampleRate: 10),
        config: .test,
        windowSeconds: 2,
        hopSeconds: 1
    )

    let result = try await coordinator.process(
        speakerSpans: [
            SpeakerSpan(
                speakerID: "lecturer",
                startFrame: 0,
                endFrame: 100,
                confidence: 1
            )
        ],
        totalFrames: 100,
        sampleRate: 10,
        existingEvents: [],
        activeRuns: ActiveRuns(),
        semanticCues: [
            TimedSemanticSceneCue(
                frame: 10,
                cue: .discussionStart
            )
        ]
    )

    let states = result.events.compactMap { event -> SceneState? in
        guard case .sceneChanged(let scene) = event.kind else {
            return nil
        }
        return scene
    }

    #expect(states.contains(.discussionCandidate))
    #expect(!states.contains(.discussion))
}

@Test
func cueAtHopEndUsesPostCueAcousticsForConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sampleRate = 10.0
    let speakers = ["a", "b", "c"]
    let discussionSpans = stride(from: 200, to: 230, by: 3).enumerated().map { index, start in
        SpeakerSpan(
            speakerID: speakers[index % speakers.count],
            startFrame: Int64(start),
            endFrame: Int64(min(start + 3, 230)),
            confidence: 1
        )
    }
    let coordinator = SceneCoordinator(
        sessionID: UUID(),
        runID: "scene-cue-boundary",
        writer: try SessionWriter(sessionURL: root),
        materializer: TranscriptMaterializer(sampleRate: sampleRate),
        config: .test
    )

    let result = try await coordinator.process(
        speakerSpans: [
            SpeakerSpan(speakerID: "lecturer", startFrame: 0, endFrame: 200, confidence: 1)
        ] + discussionSpans,
        totalFrames: 230,
        sampleRate: sampleRate,
        existingEvents: [],
        activeRuns: ActiveRuns(),
        semanticCues: [TimedSemanticSceneCue(frame: 200, cue: .discussionStart)]
    )
    let scenes = result.events.compactMap { event -> (Int64, SceneState)? in
        guard case .sceneChanged(let scene) = event.kind,
              let frame = event.sourceStartFrame else { return nil }
        return (frame, scene)
    }

    #expect(result.transitions == [
        SceneTransition(from: .lecture, to: .discussionCandidate),
        SceneTransition(from: .discussionCandidate, to: .discussion)
    ])
    #expect(scenes.map { $0.0 } == [0, 200, 230])
    #expect(scenes.map { $0.1 } == [.lecture, .discussionCandidate, .discussion])
}

@Test
func shortQuestionDuringLectureStaysLectureWithProductionConfig() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sampleRate = 10.0
    let coordinator = SceneCoordinator(
        sessionID: UUID(),
        runID: "scene-short-question",
        writer: try SessionWriter(sessionURL: root),
        materializer: TranscriptMaterializer(sampleRate: sampleRate)
    )
    let result = try await coordinator.process(
        speakerSpans: [
            SpeakerSpan(speakerID: "lecturer", startFrame: 0, endFrame: 300, confidence: 1),
            SpeakerSpan(speakerID: "student", startFrame: 300, endFrame: 310, confidence: 1),
            SpeakerSpan(speakerID: "guest", startFrame: 310, endFrame: 320, confidence: 1),
            SpeakerSpan(speakerID: "student", startFrame: 320, endFrame: 330, confidence: 1),
            SpeakerSpan(speakerID: "lecturer", startFrame: 330, endFrame: 340, confidence: 1),
            SpeakerSpan(speakerID: "student", startFrame: 340, endFrame: 350, confidence: 1),
            SpeakerSpan(speakerID: "guest", startFrame: 350, endFrame: 360, confidence: 1),
            SpeakerSpan(speakerID: "lecturer", startFrame: 360, endFrame: 380, confidence: 1),
            SpeakerSpan(speakerID: "guest", startFrame: 380, endFrame: 390, confidence: 1),
            SpeakerSpan(speakerID: "student", startFrame: 390, endFrame: 400, confidence: 1),
            SpeakerSpan(speakerID: "lecturer", startFrame: 400, endFrame: 680, confidence: 1)
        ],
        totalFrames: 680,
        sampleRate: sampleRate,
        existingEvents: [],
        activeRuns: ActiveRuns()
    )
    let scenes = result.events.compactMap { event -> (Int64, SceneState)? in
        guard case .sceneChanged(let scene) = event.kind,
              let frame = event.sourceStartFrame else { return nil }
        return (frame, scene)
    }

    #expect(scenes.map { $0.0 } == [0, 470, 510])
    #expect(scenes.map { $0.1 } == [.lecture, .discussionCandidate, .lecture])
}
