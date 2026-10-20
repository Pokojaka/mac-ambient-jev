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
        fillerRanges: [try TextUTF16Range(start: 0, end: 2)],
        speakers: [], isDiarized: false
    )
    let row = try #require(LiveTranscriptProjection().rows(for: [segment]).first)
    #expect(segment.text == raw)
    #expect(row.text == "今日は公開鍵暗号を説明します。")
}

private func prioritySlice(
    _ clauseID: String, _ start: Int, _ end: Int, _ priority: ContentPriority?, needsRetry: Bool = false
) throws -> ClauseRowSlice {
    ClauseRowSlice(
        reference: try ClauseReference(boundaryRunID: "boundary", clauseID: clauseID),
        sourceRange: try TextUTF16Range(start: start, end: end), priority: priority, needsRetry: needsRetry
    )
}

@Test
func lowPrioritySentencesAreRemovedFromScreenTranscriptAndDisplayText() throws {
    let raw = "えー、資料を配ります。はい。"
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000, text: raw,
        fillerRanges: [try TextUTF16Range(start: 0, end: 2)],
        speakers: [], isDiarized: false, clauseState: .classified,
        clauseSlices: [try prioritySlice("c1_0", 0, 11, .primary), try prioritySlice("c1_1", 11, 14, .lowPriority)]
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(segment)) as? [String: Any]
    )
    #expect(object["text"] as? String == raw)
    #expect(object["display_text"] as? String == "資料を配ります。")
    #expect(try LiveTranscriptProjection().rows(for: [segment]).map(\.text) == ["資料を配ります。"])
}

@Test
func rowWhoseEverySentenceIsLowPriorityIsNotShown() throws {
    let lowOnly = try MaterializedTranscriptSegment.fixture(
        segmentID: "low", startMilliseconds: 0, endMilliseconds: 1_000, text: "はい。うん。",
        fillerRanges: [], speakers: [], isDiarized: false, clauseState: .classified,
        clauseSlices: [try prioritySlice("c1_0", 0, 3, .lowPriority), try prioritySlice("c1_1", 3, 6, .lowPriority)]
    )
    let primary = try MaterializedTranscriptSegment.fixture(
        segmentID: "primary", startMilliseconds: 1_000, endMilliseconds: 2_000, text: "本題です。",
        fillerRanges: [], speakers: [], isDiarized: false, clauseState: .classified,
        clauseSlices: [try prioritySlice("c2_0", 0, 5, .primary)]
    )
    #expect(lowOnly.text == "はい。うん。")
    #expect(lowOnly.displayText == "")
    #expect(try LiveTranscriptProjection().rows(for: [lowOnly, primary]).map(\.text) == ["本題です。"])
}

@Test
func undecidedSentencesKeepTheirTextNextToRemovedLowPrioritySentences() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "pending", startMilliseconds: 0, endMilliseconds: 1_000, text: "はい。うん。そうです。続き",
        fillerRanges: [], speakers: [], isDiarized: false, clauseState: .awaitingNextSegment,
        clauseSlices: [
            try prioritySlice("c1_0", 0, 3, .lowPriority),
            try prioritySlice("c1_1", 3, 6, .lowPriority, needsRetry: true),
            try prioritySlice("c1_2", 6, 11, nil)
        ]
    )
    #expect(try LiveTranscriptProjection().rows(for: [segment]).map(\.text) == ["うん。そうです。続き"])
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
            fillerRanges: [], speakers: [], isDiarized: false
        )
    }

    let rows = try LiveTranscriptProjection().rows(for: segments)
    #expect(rows.map(\.text) == [
        "聞き取れませんでした", "「聞き取れませんでした。」", "『認識できませんでした』",
        "えー", " えー、\n", "うん"
    ])
}

@Test
func liveProjectionUsesDominantSpeakerWhenItCoversAtLeastEightyPercent() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "dominant", startMilliseconds: 1_000, endMilliseconds: 2_000,
        text: "発話", fillerRanges: [],
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
        text: "会話", fillerRanges: [],
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
func materializerAppliesFillerRemovalOnlyAfterSavedAssessment() throws {
    let raw = "えー、資料を配ります。"
    let sourceEvents: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "seg", segmentID: "s1", startFrame: 0, endFrame: 1_000),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "seg", segmentID: "s1",
                      text: raw, detectedLanguage: nil)
    ]
    let localRuns = ActiveRuns(segmentation: "seg", asr: "asr")
    let beforeAssessment = try #require(try TranscriptMaterializer(sampleRate: 1_000)
        .materialize(events: sourceEvents, activeRuns: localRuns).first)
    #expect(beforeAssessment.displayText == raw)
    let beforeObject = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(beforeAssessment)) as? [String: Any]
    )
    #expect(beforeObject["display_text"] as? String == raw)
    #expect(try LiveTranscriptProjection().rows(for: [beforeAssessment]).map(\.text) == [raw])

    let source = try SegmentTextReference(segmentationRunID: "seg", segmentID: "s1", asrRunID: "asr", asrEventSeq: 2)
    let pending = TranscriptEvent.clause(
        seq: 3, runID: "boundary",
        kind: .clauseBoundaryPending(ClauseBoundaryPendingPayload(
            source: source, reason: .requestFailed, message: "request failed"
        ))
    )
    let failed = try #require(try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: sourceEvents + [pending],
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", clauseBoundary: "boundary")
    ).first)
    #expect(failed.displayText == raw)
    #expect(try LiveTranscriptProjection().rows(for: [failed]).map(\.text) == [raw])

    let candidates = try ClauseBoundaryCandidate.candidates(in: raw)
    let assessment = try ClauseBoundaryAssessment(
        source: source,
        candidates: candidates,
        probabilities: Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, 0.1) }),
        nextHead: nil,
        continuationProbability: nil,
        fillerRanges: [try TextUTF16Range(start: 0, end: 2)],
        request: try DecisionRequestRecord(requestID: "boundary-request", inputTokens: testInputTokens),
        sourceDecision: .assessed
    )
    let assessedEvent = TranscriptEvent.clause(
        seq: 3, runID: "boundary", kind: .clauseBoundaryAssessed(assessment)
    )
    let saved = try #require(try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: sourceEvents + [assessedEvent],
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr", clauseBoundary: "boundary")
    ).first)
    #expect(saved.text == raw)
    #expect(saved.clauseSlices.isEmpty)
    #expect(saved.displayText == "資料を配ります。")

    let object = try #require(
        JSONSerialization.jsonObject(with: try JSONEncoder().encode(saved)) as? [String: Any]
    )
    #expect(Set(object.keys) == Set([
        "segment_id", "source", "start_ms", "end_ms", "text", "display_text",
        "speakers", "clause_state", "clause_slices"
    ]))
    #expect(object["text"] as? String == raw)
    #expect(object["display_text"] as? String == "資料を配ります。")
    #expect(try LiveTranscriptProjection().rows(for: [saved]).map(\.text) == ["資料を配ります。"])
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

private func makeTenThousandSegmentEvents() -> [TranscriptEvent] {
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
    return events
}

@Test
func materializerHandlesTenThousandSegmentLog() throws {
    let materialized = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: makeTenThousandSegmentEvents(),
        activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    #expect(materialized.count == 10_000)
    #expect(materialized.last?.text == "utterance 9999")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MATERIALIZER_BENCHMARK"] == "1"))
func materializerTenThousandSegmentBenchmark() throws {
    let events = makeTenThousandSegmentEvents()
    let clock = ContinuousClock()
    let start = clock.now
    let materialized = try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: events, activeRuns: ActiveRuns(segmentation: "seg", asr: "asr")
    )
    let elapsed = start.duration(to: clock.now)
    #expect(materialized.count == 10_000)
    #expect(materialized.last?.text == "utterance 9999")
    print("MATERIALIZER_MEASUREMENT segments=10000 elapsed=\(elapsed)")
}

@Test
func materializerProjectsOneCrossRowClauseWithoutChangingRawRowsOrSpeakerTiming() async throws {
    let root = temporarySessionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    _ = try publishLocal(root: root, events: try await writeTranscript(["えー、第一。うん", "えー、続き"], root: root, sessionID: id))
    let result = try await buildAndPublish(
        root: root, sessionID: id,
        provider: ScriptedDecisionProvider(
            boundary: punctuationBoundaries(
                continuing: ["s01"], fillerRangesBySegment: [
                    "s01": [try TextUTF16Range(start: 0, end: 2)],
                    "s02": [try TextUTF16Range(start: 0, end: 2)]
                ]
            ),
            priority: lowForBackchannel
        ),
        scope: .all
    )
    let segments = result.materializedSegments
    #expect(segments.map(\.text) == ["えー、第一。うん", "えー、続き"])
    #expect(segments.map(\.displayText) == ["第一。", ""])
    #expect(segments.map(\.startMilliseconds) == [0, 1_000])
    #expect(segments.map(\.endMilliseconds) == [900, 1_900])
    #expect(segments[0].clauseSlices.map(\.sourceRange)
        == [try TextUTF16Range(start: 0, end: 6), try TextUTF16Range(start: 6, end: 8)])
    #expect(segments[1].clauseSlices.map(\.sourceRange) == [try TextUTF16Range(start: 0, end: 5)])
    #expect(segments[0].clauseSlices.last?.reference == segments[1].clauseSlices.first?.reference)
    #expect(segments[0].clauseSlices.map(\.priority) == [.primary, .lowPriority])
    #expect(segments[1].clauseSlices.map(\.priority) == [.lowPriority])
    #expect(try LiveTranscriptProjection().rows(for: segments).map(\.text) == ["第一。"])
}

@Test
func lowPriorityRemovalKeepsFillerRemovalAndSurrogatePairsIntact() throws {
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "emoji", startMilliseconds: 0, endMilliseconds: 1_000, text: "えー、低。えー、😀本文",
        fillerRanges: [try TextUTF16Range(start: 0, end: 2), try TextUTF16Range(start: 5, end: 7)],
        speakers: [], isDiarized: false, clauseState: .classified,
        clauseSlices: [try prioritySlice("c1_0", 0, 5, .lowPriority), try prioritySlice("c1_1", 5, 12, .primary)]
    )
    #expect(segment.displayText == "😀本文")
}

@Test
func segmentRejectsOverlappingClauseSlices() throws {
    #expect(throws: TranscriptMaterializationError.invalidClauseSlice(segmentID: "s")) {
        _ = try MaterializedTranscriptSegment.fixture(
            segmentID: "s", startMilliseconds: 0, endMilliseconds: 100, text: "本文です",
            fillerRanges: [], speakers: [], isDiarized: false, clauseState: .classified,
            clauseSlices: [try prioritySlice("c1_0", 0, 2, .primary), try prioritySlice("c1_1", 1, 4, .lowPriority)]
        )
    }
}

@Test
func segmentRejectsAClauseSliceInsideACharacter() throws {
    let text = "👩🏽‍💻本文"
    #expect(throws: TextUTF16RangeError.invalidCharacterBoundary(start: 1, end: text.utf16.count)) {
        _ = try MaterializedTranscriptSegment.fixture(
            segmentID: "s", startMilliseconds: 0, endMilliseconds: 100, text: text,
            fillerRanges: [], speakers: [], isDiarized: false, clauseState: .classified,
            clauseSlices: [try prioritySlice("c1_0", 1, text.utf16.count, .lowPriority)]
        )
    }
}
