import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func eventLogTranscriptReaderReconstructsOnlyActiveRuns() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)

    _ = try await writer.append(EventDraft(
        eventType: "segment.created",
        sessionID: sessionID,
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        sourceStartFrame: 0,
        sourceEndFrame: 1_000,
        payload: EmptyPayload()
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr-stale",
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        payload: ASRCompletedEventPayload(
            text: "古い結果",
            detectedLanguage: "ja",
            engine: "test",
            model: "test"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: "asr-active",
        segmentationRunID: "seg-active",
        segmentID: "seg-1",
        payload: ASRCompletedEventPayload(
            text: "現在の結果",
            detectedLanguage: "ja",
            engine: "test",
            model: "test"
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "speaker.span",
        sessionID: sessionID,
        processingRunID: "diar-active",
        sourceStartFrame: 0,
        sourceEndFrame: 1_000,
        payload: SpeakerSpan(
            speakerID: "speaker-1",
            startFrame: 0,
            endFrame: 1_000,
            confidence: 0.9
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "scene.changed",
        sessionID: sessionID,
        processingRunID: "scene-active",
        sourceStartFrame: 0,
        payload: SceneState.discussion
    ))
    _ = try await writer.append(EventDraft(
        eventType: "scope.span",
        sessionID: sessionID,
        processingRunID: "scope-active",
        segmentID: "seg-1",
        sourceStartFrame: 0,
        sourceEndFrame: 1_000,
        payload: ScopeSpan(
            startFrame: 0,
            endFrame: 1_000,
            scope: .near,
            confidence: 0.95
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: "priority-active",
        segmentID: "seg-1",
        payload: ContentPriorityEventPayload(
            priority: .lowPriority,
            decision: .classified(confidence: 0.99, model: "jev-test", inputTokens: 4)
        )
    ))

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let activeRuns = ActiveRuns(
        segmentation: "seg-active",
        asr: "asr-active",
        diarization: "diar-active",
        scene: "scene-active",
        scope: "scope-active",
        contentPriority: "priority-active"
    )
    let events = try EventLogTranscriptReader().events(
        lines: recovered.lines,
        activeRuns: activeRuns
    )

    let materialized = TranscriptMaterializer(
        sampleRate: 1_000
    ).materialize(
        events: events,
        activeRuns: activeRuns
    )

    #expect(materialized.count == 1)
    #expect(materialized[0].text == "現在の結果")
    #expect(materialized[0].scene == .discussion)
    #expect(materialized[0].speakers.first?.id == "speaker-1")
    #expect(materialized[0].scopeSpans.first?.scope == .near)
    #expect(materialized[0].contentPriority == .lowPriority)
}

@Test
func jevRetryAnalyzerUsesLatestAssignmentPerSegment() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionID = UUID()
    let writer = try SessionWriter(sessionURL: root)

    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: "priority-1",
        segmentID: "seg-1",
        payload: ContentPriorityEventPayload(
            priority: .primary,
            decision: .retryPending
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: "priority-1",
        segmentID: "seg-2",
        payload: ContentPriorityEventPayload(
            priority: .primary,
            decision: .retryPending
        )
    ))
    _ = try await writer.append(EventDraft(
        eventType: "content_priority.assigned",
        sessionID: sessionID,
        processingRunID: "priority-2",
        segmentID: "seg-1",
        payload: ContentPriorityEventPayload(
            priority: .lowPriority,
            decision: .classified(confidence: 0.99, model: "jev-test", inputTokens: 3)
        )
    ))

    let recovered = try SessionRecovery.recoverJSONL(
        Data(contentsOf: root.appending(path: "events.jsonl"))
    )
    let state = try JevRetryAnalyzer().contentPriorityState(
        lines: recovered.lines
    )

    #expect(state.hasAssignments)
    #expect(state.latestRunID == "priority-2")
    #expect(state.pendingSegmentIDs == ["seg-2"])
}
