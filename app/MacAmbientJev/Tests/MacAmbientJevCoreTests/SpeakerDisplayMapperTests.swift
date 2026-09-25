import Testing
@testable import MacAmbientJevCore

@Test
func speakerDisplayMapperRanksFourSpeakersAndMapsOverflow() {
    let spans = [
        SpeakerSpan(speakerID: "S1", startFrame: 0, endFrame: 100, confidence: nil),
        SpeakerSpan(speakerID: "S2", startFrame: 100, endFrame: 250, confidence: nil),
        SpeakerSpan(speakerID: "S3", startFrame: 250, endFrame: 450, confidence: nil),
        SpeakerSpan(speakerID: "S4", startFrame: 450, endFrame: 700, confidence: nil),
        SpeakerSpan(speakerID: "S5", startFrame: 700, endFrame: 1_000, confidence: nil)
    ]

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans)

    #expect(labels["S5"] == "話者1")
    #expect(labels["S4"] == "話者2")
    #expect(labels["S3"] == "話者3")
    #expect(labels["S2"] == "話者4")
    #expect(labels["S1"] == "その他")
}

@Test
func speakerDisplayMapperBreaksDurationTiesByFirstStartThenRawID() {
    let spans = [
        SpeakerSpan(speakerID: "Z", startFrame: 20, endFrame: 40, confidence: nil),
        SpeakerSpan(speakerID: "B", startFrame: 10, endFrame: 30, confidence: nil),
        SpeakerSpan(speakerID: "A", startFrame: 10, endFrame: 30, confidence: nil)
    ]

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans, limit: 3)

    #expect(labels["A"] == "話者1")
    #expect(labels["B"] == "話者2")
    #expect(labels["Z"] == "話者3")
}

@Test
func speakerDisplayMapperUnionsOverlappingSpansForSameSpeaker() {
    let spans = [
        SpeakerSpan(speakerID: "A", startFrame: 0, endFrame: 100, confidence: nil),
        SpeakerSpan(speakerID: "A", startFrame: 50, endFrame: 150, confidence: nil),
        SpeakerSpan(speakerID: "B", startFrame: 0, endFrame: 120, confidence: nil)
    ]

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans, limit: 2)

    #expect(labels["A"] == "話者1")
    #expect(labels["B"] == "話者2")
}

@Test
func speakerDisplayMapperLabelsMissingAndOverflowSpeakers() {
    let labels = SpeakerDisplayMapper.makeLabels(
        spans: [
            SpeakerSpan(speakerID: "A", startFrame: 0, endFrame: 10, confidence: nil),
            SpeakerSpan(speakerID: "B", startFrame: 20, endFrame: 30, confidence: nil)
        ],
        limit: 1
    )

    #expect(SpeakerDisplayMapper.label(for: nil, labels: labels) == "話者不明")
    #expect(SpeakerDisplayMapper.label(for: "B", labels: labels) == "その他")
}

@Test
func liveProjectionSummarizesMultipleSpeakersAndKeepsUnknownLabel() throws {
    let overlappingSpeakers = [
        MaterializedSpeakerSpan(id: "S1", startMilliseconds: 0, endMilliseconds: 1_000, confidence: nil),
        MaterializedSpeakerSpan(id: "S2", startMilliseconds: 500, endMilliseconds: 1_000, confidence: nil)
    ]
    let segments = [
        MaterializedTranscriptSegment(
            segmentID: "overlap", startMilliseconds: 0, endMilliseconds: 1_000,
            text: "重なり", scene: .unknown, speakers: overlappingSpeakers,
            scopeSpans: [], contentPriority: nil
        ),
        MaterializedTranscriptSegment(
            segmentID: "unknown", startMilliseconds: 1_000, endMilliseconds: 2_000,
            text: "不明", scene: .unknown, speakers: [],
            scopeSpans: [], contentPriority: nil
        )
    ]

    let projection = LiveTranscriptProjection()
    let finalRows = projection.rows(for: segments)
    #expect(finalRows[0].speakers.map(\.id) == ["S1", "S2"])
    #expect(finalRows[0].displaySpeakerLabels == ["複数話者"])
    #expect(finalRows[1].displaySpeakerLabels == ["話者不明"])
}

@Test
func materializerKeepsEmptyASRResultForShortFinalTurn() throws {
    let events: [TranscriptEvent] = [
        .segmentCreated(seq: 1, segmentationRunID: "final", segmentID: "short", startFrame: 0, endFrame: 100),
        .asrCompleted(seq: 2, runID: "asr", segmentationRunID: "final", segmentID: "short", text: "")
    ]

    let segment = try #require(
        TranscriptMaterializer(sampleRate: 48_000).materialize(
            events: events,
            activeRuns: ActiveRuns(segmentation: "final", asr: "asr")
        ).first
    )

    #expect(segment.text.isEmpty)
}
