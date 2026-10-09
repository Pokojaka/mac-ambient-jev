import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func materializerUsesOnlySelectedASRRun() throws {
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
    let result = try TranscriptMaterializer(sampleRate: 48_000)
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
    let segments = try TranscriptMaterializer(sampleRate: 48_000).materialize(
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
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "raw", startMilliseconds: 0, endMilliseconds: 1_000, text: raw,
        speakers: [], isDiarized: false
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
    let segments = try texts.enumerated().map { index, text in
        try MaterializedTranscriptSegment.fixture(
            segmentID: "s\(index)", startMilliseconds: Int64(index * 1000),
            endMilliseconds: Int64((index + 1) * 1000), text: text,
            speakers: [], isDiarized: false
        )
    }

    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.text) == ["聞き取れませんでした", "「聞き取れませんでした。」", "『認識できませんでした』", "うん"])
}

@Test
func liveProjectionUsesDominantSpeakerWhenItCoversAtLeastEightyPercent() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "dominant", startMilliseconds: 1_000, endMilliseconds: 2_000,
        text: "発話",
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 1_800, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 1_800, endMilliseconds: 2_100, confidence: nil, displayLabel: nil)
        ], isDiarized: true
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["Speaker 1"])
    #expect(row.speakers.map(\.id) == ["A", "B"])
}

@Test
func liveProjectionShowsBothSpeakersWhenNoSpeakerReachesEightyPercent() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "会話",
        speakers: [
            MaterializedSpeakerSpan(id: "A", startMilliseconds: 0, endMilliseconds: 600, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "B", startMilliseconds: 400, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)
        ], isDiarized: true
    )

    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(row.displaySpeakerLabels == ["Speaker 1", "Speaker 2"])
    #expect(row.speakers.map(\.id) == ["A", "B"])
}

@Test
func materializerKeepsMultipleSpeakerSpans() throws {
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
        )
    ]
    let runs = ActiveRuns(
        segmentation: "seg", asr: "asr",
        diarization: "diar"
    )
    let segment = try #require(
        try TranscriptMaterializer(sampleRate: 1000)
            .materialize(events: events, activeRuns: runs)
            .first
    )

    #expect(segment.speakers == [
        MaterializedSpeakerSpan(id: "speaker_1", startMilliseconds: 0, endMilliseconds: 400,
                                confidence: 0.8, displayLabel: "Speaker 1"),
        MaterializedSpeakerSpan(id: "speaker_2", startMilliseconds: 400, endMilliseconds: 1_000,
                                confidence: 0.7, displayLabel: "Speaker 2")
    ])
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
    let materialized = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events,
        activeRuns: activeRuns
    )

    let row = try #require(LiveTranscriptProjection().rows(for: materialized).first)

    #expect(row.speakers.map(\.id) == ["in-turn"])
    #expect(row.displaySpeakerLabels == ["Speaker 2"])
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
        try TranscriptMaterializer(sampleRate: 1000).materialize(
            events: events,
            activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
        ).first
    )

    #expect(segment.text == "公開鍵暗号です")
    #expect(segment.clauseState == .boundaryPending)
    #expect(segment.clauseSlices.isEmpty)
}

@Test
func materializedJSONKeepsRawASRAlongsideTheFillerRemovedDisplayText() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "s1",
        startMilliseconds: 0,
        endMilliseconds: 1000,
        text: "えー、本文",
        speakers: [],
        isDiarized: true
    )

    let data = try JSONEncoder().encode(segment)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(Set(object.keys) == Set([
        "segment_id", "source", "start_ms", "end_ms", "text", "display_text",
        "speakers", "clause_state", "clause_slices"
    ]))
    #expect(object["text"] as? String == "えー、本文")
    #expect(object["display_text"] as? String == "本文")
}

@Test
func materializerMarksSegmentsDiarizedOnlyWhenADiarizationRunIsActive() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "s1", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "s1", text: "発話", detectedLanguage: nil)
    ]
    let live = try #require(try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    ).first)
    let final = try #require(try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")
    ).first)

    #expect(!live.isDiarized)
    #expect(final.isDiarized)
    #expect(final.speakers.isEmpty)
    #expect(try LiveTranscriptProjection().rows(for: [live]).map(\.displaySpeakerLabels) == [[]])
    #expect(try LiveTranscriptProjection().rows(for: [final]).map(\.displaySpeakerLabels) == [["UNKNOWN"]])
}

@Test
func materializerHandlesTenThousandSegmentLog() throws {
    let count = 10_000
    var events: [TranscriptEvent] = []
    events.reserveCapacity(count * 2)
    for index in 0..<count {
        let segmentID = "segment-\(index)"
        events.append(.segmentCreated(
            seq: UInt64(index * 2 + 1), segmentationRunID: "seg", segmentID: segmentID,
            startFrame: Int64(index * 1_000), endFrame: Int64((index + 1) * 1_000)
        ))
        events.append(.asrCompleted(
            seq: UInt64(index * 2 + 2), runID: "asr", segmentationRunID: "seg",
            segmentID: segmentID, text: "utterance \(index)",
            detectedLanguage: nil
        ))
    }
    let clock = ContinuousClock()
    let start = clock.now
    let materialized = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    let elapsed = start.duration(to: clock.now)
    #expect(materialized.count == count)
    #expect(materialized.last?.text == "utterance 9999")
    #expect(elapsed < .seconds(8))
}

@Test
func materializerProjectsOneCrossRowClauseWithoutChangingRawRowsOrSpeakerTiming() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["えー、第一。うん", "えー、続き"], root: root, sessionID: id))
    let result = try await buildAndPublish(
        root: root, sessionID: id,
        provider: ScriptedDecisionProvider(boundary: punctuationBoundaries(continuing: ["s01"]), priority: lowForBackchannel),
        scope: .all
    )
    let segments = result.materializedSegments
    #expect(segments.map(\.text) == ["えー、第一。うん", "えー、続き"])
    #expect(segments.map(\.displayText) == ["第一。うん", "続き"])
    #expect(segments.map(\.startMilliseconds) == [0, 1_000])
    #expect(segments.map(\.endMilliseconds) == [900, 1_900])
    #expect(segments[0].clauseSlices.map(\.sourceRange)
        == [try TextUTF16Range(start: 0, end: 6), try TextUTF16Range(start: 6, end: 8)])
    #expect(segments[0].clauseSlices.map(\.displayRanges)
        == [[try TextUTF16Range(start: 0, end: 3)], [try TextUTF16Range(start: 3, end: 5)]])
    #expect(segments[1].clauseSlices.map(\.sourceRange) == [try TextUTF16Range(start: 0, end: 5)])
    #expect(segments[1].clauseSlices.map(\.displayRanges) == [[try TextUTF16Range(start: 0, end: 2)]])
    #expect(segments[0].clauseSlices.last?.reference == segments[1].clauseSlices.first?.reference)
    #expect(segments[0].clauseSlices.map(\.priority) == [.primary, .lowPriority])
    #expect(segments[1].clauseSlices.map(\.priority) == [.lowPriority])
    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.text) == ["第一。うん", "続き"])
    #expect(rows.map(\.shouldCollapseRow) == [false, true])
}

@Test(arguments: [false, true])
func liveProjectionRejectsInvalidRawOrDisplayClauseCoordinates(insideCharacter: Bool) throws {
    let base = try MaterializedTranscriptSegment.fixture(
        segmentID: "s", startMilliseconds: 0, endMilliseconds: 100, text: "👩🏽‍💻本文",
        speakers: [], isDiarized: false
    )
    let slice = ClauseRowSlice(
        reference: try ClauseReference(boundaryRunID: "boundary", clauseID: "c1_0"),
        sourceRange: try TextUTF16Range(start: insideCharacter ? 1 : 0, end: base.text.utf16.count),
        displayRanges: [try TextUTF16Range(start: 0, end: 1)], priority: .lowPriority, needsRetry: false
    )
    let invalid = MaterializedTranscriptSegment(
        segmentID: base.segmentID, source: base.source, startMilliseconds: base.startMilliseconds,
        endMilliseconds: base.endMilliseconds, text: base.text, textProjection: base.textProjection,
        speakers: base.speakers, clauseState: .classified,
        clauseSlices: [slice], isDiarized: false
    )
    #expect(throws: (any Error).self) { _ = try LiveTranscriptProjection().rows(for: [invalid]) }
}
