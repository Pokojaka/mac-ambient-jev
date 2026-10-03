import Foundation
import Testing
@testable import MacAmbientJevCore

private struct DistantEvidenceProvider: ProximityEvidenceProvider {
    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        [
            ProximityEvidenceSpan(
                startFrame: startFrame,
                endFrame: endFrame,
                evidence: ProximityEvidence(
                    distanceHint: .distant,
                    levelConfidence: 0.9,
                    spectralConfidence: 0.9
                )
            )
        ]
    }
}

private struct UnknownEvidenceProvider: ProximityEvidenceProvider {
    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        [ProximityEvidenceSpan(startFrame: startFrame, endFrame: endFrame, evidence: .unknown)]
    }
}

private struct UnreadableAudioError: Error, Equatable {}

private struct UnreadableEvidenceProvider: ProximityEvidenceProvider {
    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        throw UnreadableAudioError()
    }
}

private struct MixedEvidenceProvider: ProximityEvidenceProvider {
    func evidenceSpans(
        startFrame: Int64,
        endFrame: Int64,
        speakerSpans: [SpeakerSpan]
    ) async throws -> [ProximityEvidenceSpan] {
        let middle = startFrame + (endFrame - startFrame) / 2
        return [
            ProximityEvidenceSpan(
                startFrame: startFrame,
                endFrame: middle,
                evidence: .near
            ),
            ProximityEvidenceSpan(
                startFrame: middle,
                endFrame: endFrame,
                evidence: ProximityEvidence(
                    distanceHint: .distant,
                    levelConfidence: 0.9,
                    spectralConfidence: 0.9
                )
            )
        ]
    }
}

@Test
func unknownScopeProviderNeverCreatesBackground() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try SessionWriter(sessionURL: root)
    let coordinator = ScopeCoordinator(
        sessionID: UUID(),
        runID: "scope-test",
        writer: writer,
        provider: UnknownEvidenceProvider(),
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
        ),
        .sceneChanged(
            seq: 3,
            runID: "scene",
            atFrame: 0,
            scene: .discussion
        )
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        speakerSpans: [],
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr",
            scene: "scene"
        )
    )

    #expect(result.scopeSpans.count == 1)
    #expect(result.scopeSpans[0].scope == .unknown)
}

@Test
func mixedScopeEvidenceRemainsSplitWithinOneSegment() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = try SessionWriter(sessionURL: root)
    let coordinator = ScopeCoordinator(
        sessionID: UUID(),
        runID: "scope-test",
        writer: writer,
        provider: MixedEvidenceProvider(),
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
            text: "近距離と背景が混在する発話",
            detectedLanguage: nil
        ),
        .sceneChanged(
            seq: 3,
            runID: "scene",
            atFrame: 0,
            scene: .discussion
        )
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        speakerSpans: [],
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr",
            scene: "scene"
        )
    )

    #expect(result.scopeSpans.count == 2)
    #expect(result.scopeSpans[0].scope == .near)
    #expect(result.scopeSpans[1].scope == .background)
}


@Test
func scopeClassificationSplitsAtSceneTransitionInsideSegment() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = ScopeCoordinator(
        sessionID: UUID(),
        runID: "scope-test",
        writer: try SessionWriter(sessionURL: root),
        provider: DistantEvidenceProvider(),
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
            text: "討論終了から講義へ戻る区間",
            detectedLanguage: nil
        ),
        .sceneChanged(
            seq: 3,
            runID: "scene",
            atFrame: 0,
            scene: .discussion
        ),
        .sceneChanged(
            seq: 4,
            runID: "scene",
            atFrame: 500,
            scene: .lecture
        )
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        speakerSpans: [],
        activeRuns: ActiveRuns(
            segmentation: "seg",
            asr: "asr",
            scene: "scene"
        )
    )

    #expect(result.scopeSpans.count == 2)
    #expect(result.scopeSpans[0].startFrame == 0)
    #expect(result.scopeSpans[0].endFrame == 500)
    #expect(result.scopeSpans[0].scope == .background)
    #expect(result.scopeSpans[1].startFrame == 500)
    #expect(result.scopeSpans[1].endFrame == 1_000)
    #expect(result.scopeSpans[1].scope == .unknown)
}

@Test
func scopeAndDisplayAgreeOnOutOfOrderSceneTransitions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = ScopeCoordinator(
        sessionID: UUID(),
        runID: "scope-test",
        writer: try SessionWriter(sessionURL: root),
        provider: DistantEvidenceProvider(),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "utterance", startFrame: 800, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "utterance", text: "遠くの会話", detectedLanguage: nil),
        .sceneChanged(seq: 3, runID: "scene", atFrame: 700, scene: .discussion),
        .sceneChanged(seq: 4, runID: "scene", atFrame: 0, scene: .lecture)
    ]

    let result = try await coordinator.process(
        existingEvents: events,
        speakerSpans: [],
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", scene: "scene")
    )
    let segment = try #require(result.materializedSegments.first)
    #expect(segment.scene == .discussion)
    #expect(result.scopeSpans.map(\.scope) == [.background])
    #expect(segment.scopeSpans.map(\.scope) == [.background])
    #expect(LiveTranscriptProjection().rows(for: result.materializedSegments).isEmpty)
}

@Test
func unreadableProximityAudioFailsTheScopeRun() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = ScopeCoordinator(
        sessionID: UUID(),
        runID: "scope-unreadable",
        writer: try SessionWriter(sessionURL: root),
        provider: UnreadableEvidenceProvider(),
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "seg-1", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "seg-1", text: "重要な発話", detectedLanguage: nil)
    ]

    await #expect(throws: UnreadableAudioError()) {
        try await coordinator.process(
            existingEvents: events,
            speakerSpans: [],
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        )
    }
    let eventsURL = root.appending(path: "events.jsonl")
    if FileManager.default.fileExists(atPath: eventsURL.path) {
        let log = try String(contentsOf: eventsURL, encoding: .utf8)
        #expect(!log.contains("processing.run.completed"))
    }
}
