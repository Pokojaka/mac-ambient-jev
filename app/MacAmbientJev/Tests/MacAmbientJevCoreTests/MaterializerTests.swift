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
            segmentID: "seg_1", text: "古い文字列",
            detectedLanguage: nil
        ),
        .asrCompleted(
            seq: 3, runID: "asr_new", segmentationRunID: "seg_run_01",
            segmentID: "seg_1", text: "新しい文字列",
            detectedLanguage: nil
        )
    ]
    let runs = ActiveRuns(segmentation: "seg_run_01", asr: "asr_new")
    let result = TranscriptMaterializer(sampleRate: 48_000)
        .materialize(events: events, activeRuns: runs)

    #expect(result.first?.text == "新しい文字列")
}

@Test
func materializerKeepsEmptyFinalTurnAndShortRecognizedSpeech() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "full",
                        startFrame: 0, endFrame: 672_000),
        .segmentCreated(seq: 2, segmentationRunID: "seg", segmentID: "tail",
                        startFrame: 672_000, endFrame: 672_192),
        .segmentCreated(seq: 3, segmentationRunID: "seg", segmentID: "short",
                        startFrame: 800_000, endFrame: 800_192),
        .asrCompleted(seq: 4, runID: "asr", segmentationRunID: "seg",
                      segmentID: "full", text: "前の発話", detectedLanguage: nil),
        .asrCompleted(seq: 5, runID: "asr", segmentationRunID: "seg",
                      segmentID: "tail", text: "", detectedLanguage: nil),
        .asrCompleted(seq: 6, runID: "asr", segmentationRunID: "seg",
                      segmentID: "short", text: "短い発話", detectedLanguage: nil)
    ]
    let segments = TranscriptMaterializer(sampleRate: 48_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    #expect(segments.map(\.segmentID) == ["full", "tail", "short"])
    #expect(segments.first(where: { $0.segmentID == "tail" })?.text == "")
    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.segmentID) == ["full", "short"])
    #expect(rows.last?.text == "短い発話")
}

@Test
func liveProjectionCleansDisplayWithoutChangingMaterializedASRText() throws {
    let raw = "えー、今日は公開鍵暗号を説明します。"
    let segment = MaterializedTranscriptSegment(
        segmentID: "raw", startMilliseconds: 0, endMilliseconds: 1_000, text: raw,
        scene: .lecture, speakers: [], scopeSpans: [], contentPriority: .primary, isDiarized: false
    )
    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(segment.text == raw)
    #expect(row.text == "今日は公開鍵暗号を説明します。")
    #expect(row.textFragments.map(\.text).joined() == row.text)
}

@Test
func liveProjectionHidesEmptyTextButShowsEverythingSpoken() throws {
    let texts = [
        "",
        " \n\t",
        "聞き取れませんでした",
        "「聞き取れませんでした。」",
        "『認識できませんでした』",
        "えー",
        " えー、\n",
        "うん"
    ]
    let segments = texts.enumerated().map { index, text in
        MaterializedTranscriptSegment(
            segmentID: "s\(index)", startMilliseconds: Int64(index * 1000),
            endMilliseconds: Int64((index + 1) * 1000), text: text,
            scene: .unknown, speakers: [], scopeSpans: [], contentPriority: nil, isDiarized: false
        )
    }

    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.text) == ["聞き取れませんでした", "「聞き取れませんでした。」", "『認識できませんでした』", "うん"])
}

@Test
func liveProjectionUsesDominantSpeakerWhenItCoversAtLeastEightyPercent() throws {
    let segment = MaterializedTranscriptSegment(
        segmentID: "dominant", startMilliseconds: 1_000, endMilliseconds: 2_000,
        text: "発話", scene: .unknown,
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 1_800, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 1_800, endMilliseconds: 2_100, confidence: nil, displayLabel: nil)
        ], scopeSpans: [], contentPriority: nil, isDiarized: true
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["Speaker 1"])
    #expect(row.speakers.map(\.id) == ["A", "B"])
}

@Test
func liveProjectionShowsBothSpeakersWhenNoSpeakerReachesEightyPercent() throws {
    let segment = MaterializedTranscriptSegment(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "会話", scene: .unknown,
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 600, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 400, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)
        ], scopeSpans: [], contentPriority: nil, isDiarized: true
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["Speaker 1", "Speaker 2"])
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
            segmentID: "s1", text: "発話",
            detectedLanguage: nil
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
func liveProjectionUsesFirstAppearanceOfRawSpansOutsideVADTurns() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "turn", startFrame: 1_000, endFrame: 2_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "turn", text: "発話", detectedLanguage: nil),
        .speakerSpan(seq: 3, runID: "diar", speakerID: "in-turn", startFrame: 1_000, endFrame: 2_000, confidence: 0.9),
        .speakerSpan(seq: 4, runID: "diar", speakerID: "outside-turn", startFrame: 0, endFrame: 900, confidence: 0.8)
    ]
    let activeRuns = ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")
    let materialized = TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events,
        activeRuns: activeRuns
    )

    let row = try #require(LiveTranscriptProjection().rows(for: materialized).first)

    #expect(row.speakers.map(\.id) == ["in-turn"])
    #expect(row.displaySpeakerLabels == ["Speaker 2"])
}

@Test
func materializedSpeakerDisplayLabelDoesNotChangeSerializedShape() throws {
    let span = MaterializedSpeakerSpan(
        id: "S1", startMilliseconds: 10, endMilliseconds: 20,
        confidence: 0.5, displayLabel: "Speaker 1"
    )
    let encoded = try JSONEncoder().encode(span)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(Set(object.keys) == ["id", "start_ms", "end_ms", "confidence"])
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
            segmentID: "s1", text: "公開鍵暗号です",
            detectedLanguage: nil
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
        contentPriority: nil,
        isDiarized: true
    )

    let data = try JSONEncoder().encode(segment)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(Set(object.keys) == [
        "segment_id", "start_ms", "end_ms", "text", "scene", "speakers", "scope_spans"
    ])
    #expect(object["text"] as? String == "text")
}

@Test
func materializerMarksSegmentsDiarizedOnlyWhenADiarizationRunIsActive() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "s1", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "s1", text: "発話", detectedLanguage: nil)
    ]
    let live = try #require(TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    ).first)
    let final = try #require(TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")
    ).first)

    #expect(!live.isDiarized)
    #expect(final.isDiarized)
    #expect(final.speakers.isEmpty)
    #expect(try LiveTranscriptProjection().rows(for: [live]).map(\.displaySpeakerLabels) == [[]])
    #expect(try LiveTranscriptProjection().rows(for: [final]).map(\.displaySpeakerLabels) == [["UNKNOWN"]])
}

@Test
func liveProjectionHidesOnlyBackgroundOnlyDiscussionSegments() throws {
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
        contentPriority: .primary,
        isDiarized: false
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
        contentPriority: nil,
        isDiarized: false
    )

    let rows = try LiveTranscriptProjection().rows(for: [backgroundOnly, mixed])
    #expect(rows.map(\.segmentID) == ["mixed"])
}

@Test
func materializerSelectsSceneByLatestTransitionFrameNotAppendOrder() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "utterance", startFrame: 800, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "utterance", text: "speech", detectedLanguage: nil),
        .sceneChanged(seq: 3, runID: "scene", atFrame: 700, scene: .discussion),
        .sceneChanged(seq: 4, runID: "scene", atFrame: 0, scene: .lecture),
        .sceneChanged(seq: 5, runID: "scene", atFrame: 900, scene: .lecture)
    ]
    let result = try #require(TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", scene: "scene")
    ).first)
    #expect(result.scene == .discussion)
}

@Test
func materializerHandlesTenThousandSegmentLog() {
    let count = 10_000
    var events: [TranscriptEvent] = []
    events.reserveCapacity(count * 3)
    for index in 0..<count {
        let segmentID = "segment-\(index)"
        events.append(.segmentCreated(
            seq: UInt64(index * 3 + 1), segmentationRunID: "seg", segmentID: segmentID,
            startFrame: Int64(index * 1_000), endFrame: Int64((index + 1) * 1_000)
        ))
        events.append(.asrCompleted(
            seq: UInt64(index * 3 + 2), runID: "asr", segmentationRunID: "seg",
            segmentID: segmentID, text: "utterance \(index)",
            detectedLanguage: nil
        ))
        events.append(.sceneChanged(
            seq: UInt64(index * 3 + 3), runID: "scene",
            atFrame: Int64(index * 1_000),
            scene: index.isMultiple(of: 2) ? .discussion : .lecture
        ))
    }
    let clock = ContinuousClock()
    let start = clock.now
    let materialized = TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", scene: "scene")
    )
    let elapsed = start.duration(to: clock.now)
    #expect(materialized.count == count)
    #expect(materialized.first?.scene == .discussion)
    #expect(materialized.last?.scene == .lecture)
    #expect(materialized.last?.text == "utterance 9999")
    #expect(elapsed < .seconds(8))
}
