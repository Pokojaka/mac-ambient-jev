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
            provenance: RunProvenance(engine: "test", model: "test", version: "test", configuration: [:])
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
            provenance: RunProvenance(engine: "test", model: "test", version: "test", configuration: [:])
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

private func eventLine(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

@Test
func eventLogTranscriptReaderRejectsAMalformedActiveRunEvent() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "segment.created",
            "segmentation_run_id": "seg", "segment_id": "s1",
            "source_start_frame": 0, "source_end_frame": 100,
        ]),
        try eventLine([
            "event_seq": 2, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["engine": "test", "model": "test", "outcome": "recognized"],
        ]),
    ]

    #expect(throws: EventLogTranscriptReaderError.malformedEvent(eventSeq: 2, eventType: "asr.completed")) {
        _ = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        )
    }
}

@Test
func eventLogTranscriptReaderSkipsOtherRunsAndUnknownEventTypes() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "segment.created",
            "segmentation_run_id": "seg", "segment_id": "s1",
            "source_start_frame": 0, "source_end_frame": 100,
        ]),
        try eventLine([
            "event_seq": 2, "event_type": "asr.completed",
            "processing_run_id": "asr-other", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["broken": true],
        ]),
        try eventLine(["event_seq": 3, "event_type": "future.event", "payload": 42]),
        try eventLine([
            "event_seq": 4, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["text": "発話", "engine": "test", "model": "test", "outcome": "recognized"],
        ]),
    ]

    let events = try EventLogTranscriptReader().events(
        lines: lines,
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )

    #expect(events.map(\.eventSeq) == [1, 4])
    #expect(events.last?.kind == .asrCompleted(ASRResult(text: "発話", detectedLanguage: nil)))
}

@Test
func eventLogTranscriptReaderRejectsAnOutcomeThatContradictsTheText() throws {
    let lines = [
        try eventLine([
            "event_seq": 1, "event_type": "asr.completed",
            "processing_run_id": "asr", "segmentation_run_id": "seg", "segment_id": "s1",
            "payload": ["text": "発話", "engine": "test", "model": "test", "outcome": "empty"],
        ]),
    ]

    #expect(throws: EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: 1)) {
        _ = try EventLogTranscriptReader().events(
            lines: lines,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        )
    }
}

@Test
func eventLogReadersRejectALineWithoutEnvelope() throws {
    let lines = [try eventLine(["event_type": "segment.created"])]

    #expect(throws: EventLogTranscriptReaderError.unreadableLine(index: 0)) {
        _ = try EventLogTranscriptReader().events(lines: lines, activeRuns: ActiveRuns(segmentation: "seg"))
    }
    #expect(throws: EventLogTranscriptReaderError.unreadableLine(index: 0)) {
        _ = try JevRetryAnalyzer().contentPriorityState(lines: lines)
    }
}

@Test
func jevRetryAnalyzerRejectsAnAssignmentWithoutRetryFlag() throws {
    let lines = [
        try eventLine([
            "event_seq": 7, "event_type": "content_priority.assigned",
            "processing_run_id": "priority", "segment_id": "s1",
            "payload": ["priority": "primary"],
        ]),
    ]

    #expect(throws: EventLogTranscriptReaderError.malformedEvent(eventSeq: 7, eventType: "content_priority.assigned")) {
        _ = try JevRetryAnalyzer().contentPriorityState(lines: lines)
    }
}

@Test
func liveDecisionReuseSelectsLatestClassifiedSourceAcrossSegmentationRuns() throws {
    func started(_ seq: Int, _ run: String, _ stage: String, _ mode: String) throws -> Data {
        try eventLine([
            "event_seq": seq, "event_type": "processing.run.started", "processing_run_id": run,
            "payload": ["stage": stage, "provenance": [
                "engine": "test", "version": "test", "configuration": ["mode": mode]
            ]]
        ])
    }
    func asr(_ seq: Int, _ run: String, _ segmentation: String, _ segment: String, _ text: String) throws -> Data {
        try eventLine([
            "event_seq": seq, "event_type": "asr.completed", "processing_run_id": run,
            "segmentation_run_id": segmentation, "segment_id": segment,
            "payload": ["text": text, "outcome": "recognized"]
        ])
    }
    func assigned(_ seq: Int, _ run: String, _ segmentation: String, _ segment: String, _ pending: Bool) throws -> Data {
        try eventLine([
            "event_seq": seq, "event_type": "content_priority.assigned", "processing_run_id": run,
            "segmentation_run_id": segmentation, "segment_id": segment,
            "payload": ["priority": pending ? "primary" : "lowPriority", "needs_retry": pending,
                        "decision": pending ? ["retry_pending": [:]] : ["classified": ["confidence": 0.99]]]
        ])
    }
    let lines = try [
        started(1, "live-asr", "asr", "live"), started(2, "live-priority", "contentPriority", "live"),
        started(3, "final-asr", "asr", "final"), started(4, "final-priority", "contentPriority", "final"),
        asr(5, "live-asr", "first-seg", "same-id", " \n同じ本文 "),
        assigned(6, "live-priority", "first-seg", "same-id", false),
        asr(7, "live-asr", "second-seg", "same-id", "同じ本文"),
        assigned(8, "live-priority", "second-seg", "same-id", false),
        asr(9, "live-asr", "second-seg", "pending", "未分類"),
        assigned(10, "live-priority", "second-seg", "pending", true),
        assigned(11, "live-priority", "second-seg", "same-id", true),
        asr(12, "final-asr", "final-seg", "same-id", "同じ本文"),
        assigned(13, "final-priority", "final-seg", "same-id", false)
    ]
    let reused = try EventLogTranscriptReader().liveContentPriorityDecisions(lines: Array(lines.reversed()))
    #expect(reused == ["同じ本文": .init(priority: .lowPriority, decision: .carriedOver(
        sourceRunID: "live-priority", sourceSegmentationRunID: "second-seg", sourceSegmentID: "same-id"
    ))])
}
