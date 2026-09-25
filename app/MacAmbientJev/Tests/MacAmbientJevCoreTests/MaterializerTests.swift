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
func materializerKeepsEmptyFinalTurnAndShortRecognizedSpeech() {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "full",
                        startFrame: 0, endFrame: 672_000),
        .segmentCreated(seq: 2, segmentationRunID: "seg", segmentID: "tail",
                        startFrame: 672_000, endFrame: 672_192),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "short",
                        startFrame: 800_000, endFrame: 800_192),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg",
                      segmentID: "full", text: "前の発話"),
        .asrCompleted(seq: 5, runID: "asr", segmentationRunID: "seg",
                      segmentID: "tail", text: ""),
        .asrCompleted(seq: 6, runID: "asr", segmentationRunID: "seg",
                      segmentID: "short", text: "短い発話")
    ]
    let segments = TranscriptMaterializer(sampleRate: 48_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    #expect(segments.map(\.segmentID) == ["full", "tail", "short"])
    #expect(segments.first(where: { $0.segmentID == "tail" })?.text == "")
    let rows = LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.segmentID) == ["full", "short"])
    #expect(rows.last?.text == "短い発話")
}

@Test
func liveProjectionHidesWhitespaceOnlyButKeepsShortAcknowledgements() {
    let segments = ["", " \n\t", "聞き取れませんでした", "うん"].enumerated().map { index, text in
        MaterializedTranscriptSegment(
            segmentID: "s\(index)", startMilliseconds: Int64(index * 1000),
            endMilliseconds: Int64((index + 1) * 1000), text: text,
            scene: .unknown, speakers: [], scopeSpans: [], contentPriority: nil
        )
    }

    #expect(LiveTranscriptProjection().rows(for: segments).map(\.text) == ["うん"])
}

@Test
func liveProjectionSuppressesPunctuatedNonSpeechPlaceholder() {
    let texts = [
        "聞き取れませんでした",
        "「聞き取れませんでした。」",
        "(聞き取れませんでした!)",
        "『聞き取れませんでした』",
        "えー",
        "うん"
    ]
    let segments = texts.enumerated().map { index, text in
        MaterializedTranscriptSegment(
            segmentID: "placeholder-\(index)", startMilliseconds: Int64(index * 1000),
            endMilliseconds: Int64((index + 1) * 1000), text: text,
            scene: .unknown, speakers: [], scopeSpans: [], contentPriority: nil
        )
    }

    #expect(LiveTranscriptProjection().rows(for: segments).map(\.text) == ["えー", "うん"])
}

@Test
func liveProjectionUsesDominantSpeakerWhenItCoversAtLeastEightyPercent() throws {
    let segment = MaterializedTranscriptSegment(
        segmentID: "dominant", startMilliseconds: 1_000, endMilliseconds: 2_000,
        text: "発話", scene: .unknown,
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 1_800, confidence: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 1_800, endMilliseconds: 2_100, confidence: nil)
        ], scopeSpans: [], contentPriority: nil
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["話者1"])
    #expect(row.speakers.map(\.id) == ["A", "B"])
}

@Test
func liveProjectionUsesMultipleSpeakerWhenNoSpeakerReachesEightyPercent() throws {
    let segment = MaterializedTranscriptSegment(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "会話", scene: .unknown,
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 600, confidence: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 400, endMilliseconds: 1_000, confidence: nil)
        ], scopeSpans: [], contentPriority: nil
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["複数話者"])
    #expect(row.speakers.map(\.id) == ["A", "B"])
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
func liveProjectionRanksSpeakersUsingRawSpansOutsideVADTurns() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "turn", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "turn", text: "発話"),
        .speakerSpan(seq: 3, runID: "diar", speakerID: "in-turn", startFrame: 1_000, endFrame: 2_000, confidence: 0.9),
        .speakerSpan(seq: 4, runID: "diar", speakerID: "outside-turn", startFrame: 5_000, endFrame: 15_000, confidence: 0.8)
    ]
    let activeRuns = ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")
    let materialized = TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events,
        activeRuns: activeRuns
    )

    let row = try #require(LiveTranscriptProjection().rows(for: materialized).first)

    #expect(row.speakers.map(\.id) == ["in-turn"])
    #expect(row.displaySpeakerLabels == ["話者2"])
}

@Test
func materializedSpeakerDisplayLabelDoesNotChangeSerializedShape() throws {
    let span = MaterializedSpeakerSpan(
        id: "S1", startMilliseconds: 10, endMilliseconds: 20,
        confidence: 0.5, displayLabel: "話者1"
    )
    let encoded = try JSONEncoder().encode(span)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(Set(object.keys) == ["id", "start_ms", "end_ms", "confidence"])

    let oldData = Data(#"{"id":"S2","start_ms":30,"end_ms":40,"confidence":null}"#.utf8)
    let decoded = try JSONDecoder().decode(MaterializedSpeakerSpan.self, from: oldData)
    #expect(decoded.displayLabel == nil)
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
