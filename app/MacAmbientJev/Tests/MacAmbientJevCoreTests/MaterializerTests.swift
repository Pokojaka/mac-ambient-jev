import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func materializerUsesOnlySelectedASRRun() {
    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1, segmentationRunID: "seg_run_01", segmentID: "seg_1",
            startFrame: 0, endFrame: 48_000
        ),
        .asrCompleted(
            seq: 2, runID: "asr_old", segmentationRunID: "seg_run_01",
            segmentID: "seg_1", text: "古い文字列"
        ),
        .asrCompleted(
            seq: 3, runID: "asr_new", segmentationRunID: "seg_run_01",
            segmentID: "seg_1", text: "新しい文字列"
        )
    ]
    let runs = ActiveRuns(segmentation: "seg_run_01", asr: "asr_new")
    let result = TranscriptMaterializer(sampleRate: 48_000)
        .materialize(events: events, activeRuns: runs)

    #expect(result.first?.text == "新しい文字列")
}

@Test
func materializerKeepsMultipleSpeakerAndScopeSpans() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1, segmentationRunID: "seg", segmentID: "s1",
            startFrame: 0, endFrame: 1000
        ),
        .asrCompleted(
            seq: 2, runID: "asr", segmentationRunID: "seg",
            segmentID: "s1", text: "発話"
        ),
        .speakerSpan(
            seq: 3, runID: "diar", speakerID: "speaker_1",
            startFrame: 0, endFrame: 400, confidence: 0.8
        ),
        .speakerSpan(
            seq: 4, runID: "diar", speakerID: "speaker_2",
            startFrame: 400, endFrame: 1000, confidence: 0.7
        ),
        .scopeSpan(
            seq: 5, runID: "scope", startFrame: 0, endFrame: 500,
            scope: .near, confidence: 0.9
        ),
        .scopeSpan(
            seq: 6, runID: "scope", startFrame: 500, endFrame: 1000,
            scope: .unknown, confidence: 0.5
        )
    ]
    let runs = ActiveRuns(
        segmentation: "seg", asr: "asr",
        diarization: "diar", scope: "scope"
    )
    let segment = try #require(
        TranscriptMaterializer(sampleRate: 1000)
            .materialize(events: events, activeRuns: runs)
            .first
    )

    #expect(segment.speakers.count == 2)
    #expect(segment.scopeSpans.count == 2)
}

@Test
func materializerShowsASRBeforeEnrichment() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(
            seq: 1, segmentationRunID: "seg", segmentID: "s1",
            startFrame: 0, endFrame: 100
        ),
        .asrCompleted(
            seq: 2, runID: "asr", segmentationRunID: "seg",
            segmentID: "s1", text: "公開鍵暗号です"
        )
    ]
    let segment = try #require(
        TranscriptMaterializer(sampleRate: 1000).materialize(
            events: events,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        ).first
    )

    #expect(segment.text == "公開鍵暗号です")
    #expect(segment.contentPriority == nil)
}

@Test
func materializedSegmentEncodesStableAgentFields() throws {
    let segment = MaterializedTranscriptSegment(
        segmentID: "s1",
        startMilliseconds: 0,
        endMilliseconds: 1000,
        text: "text",
        scene: .lecture,
        speakers: [],
        scopeSpans: [],
        contentPriority: nil
    )

    let data = try JSONEncoder().encode(segment)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["segment_id"] != nil)
    #expect(object["scope_spans"] != nil)
    #expect(object["text"] as? String == "text")
}

@Test
func liveProjectionHidesOnlyBackgroundOnlyDiscussionSegments() {
    let backgroundOnly = MaterializedTranscriptSegment(
        segmentID: "bg",
        startMilliseconds: 0,
        endMilliseconds: 1000,
        text: "遠くの会話",
        scene: .discussion,
        speakers: [],
        scopeSpans: [
            MaterializedScopeSpan(
                startMilliseconds: 0, endMilliseconds: 1000,
                scope: .background, confidence: 0.9
            )
        ],
        contentPriority: .primary
    )

    let mixed = MaterializedTranscriptSegment(
        segmentID: "mixed",
        startMilliseconds: 1000,
        endMilliseconds: 2000,
        text: "近くも含む",
        scene: .discussion,
        speakers: [],
        scopeSpans: [
            MaterializedScopeSpan(
                startMilliseconds: 1000, endMilliseconds: 1500,
                scope: .background, confidence: 0.8
            ),
            MaterializedScopeSpan(
                startMilliseconds: 1500, endMilliseconds: 2000,
                scope: .near, confidence: 0.7
            )
        ],
        contentPriority: nil
    )

    let rows = LiveTranscriptProjection().rows(for: [backgroundOnly, mixed])
    #expect(rows.map(\.segmentID) == ["mixed"])
}
