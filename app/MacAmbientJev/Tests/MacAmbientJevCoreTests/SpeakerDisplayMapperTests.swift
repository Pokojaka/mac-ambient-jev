import Testing
@testable import MacAmbientJevCore

@Test
func speakerDisplayMapperUsesFirstAppearanceAndGroupsEighthAndLaterSpeakers() {
    let spans: [SpeakerSpan] = (1...9).map { index in
        let start = Int64(index * 100)
        let end = index == 1 ? start + 1 : start + 1_000
        return SpeakerSpan(speakerID: "S\(index)", startFrame: start, endFrame: end, confidence: nil)
    }

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans)

    for index in 1...7 {
        #expect(labels["S\(index)"] == "Speaker \(index)")
    }
    #expect(labels["S8"] == "OTHER")
    #expect(labels["S9"] == "OTHER")
}

@Test
func speakerDisplayMapperBreaksFirstStartTiesByRawID() {
    let spans = [
        SpeakerSpan(speakerID: "Z", startFrame: 20, endFrame: 40, confidence: nil),
        SpeakerSpan(speakerID: "B", startFrame: 10, endFrame: 30, confidence: nil),
        SpeakerSpan(speakerID: "A", startFrame: 10, endFrame: 30, confidence: nil)
    ]

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans)

    #expect(labels["A"] == "Speaker 1")
    #expect(labels["B"] == "Speaker 2")
    #expect(labels["Z"] == "Speaker 3")
}

@Test
func speakerDisplayMapperIgnoresZeroLengthSpansAndKeepsEarliestValidStart() {
    let spans = [
        SpeakerSpan(speakerID: "ignored", startFrame: 0, endFrame: 0, confidence: nil),
        SpeakerSpan(speakerID: "A", startFrame: 30, endFrame: 40, confidence: nil),
        SpeakerSpan(speakerID: "B", startFrame: 20, endFrame: 25, confidence: nil),
        SpeakerSpan(speakerID: "A", startFrame: 10, endFrame: 15, confidence: nil)
    ]

    let labels = SpeakerDisplayMapper.makeLabels(spans: spans)

    #expect(labels["ignored"] == nil)
    #expect(labels["A"] == "Speaker 1")
    #expect(labels["B"] == "Speaker 2")
}

@Test
func speakerDisplayMapperKeepsUnmappedSpeakersUnknown() {
    let labels = SpeakerDisplayMapper.makeLabels(
        spans: [SpeakerSpan(speakerID: "A", startFrame: 0, endFrame: 10, confidence: nil)]
    )

    #expect(SpeakerDisplayMapper.label(for: "missing", labels: labels) == "UNKNOWN")
    #expect(SpeakerDisplayMapper.label(for: "A", labels: labels) == "Speaker 1")
}

@Test
func speakerDisplayMapperDeduplicatesOtherInMixedTurns() throws {
    let spans = (1...9).map { index in
        SpeakerSpan(speakerID: "S\(index)", startFrame: Int64(index),
                    endFrame: Int64(index + 1), confidence: nil)
    }
    let segment = try MaterializedTranscriptSegment.fixture(
        segmentID: "mixed", startMilliseconds: 0, endMilliseconds: 1_000,
        text: "会話", fillerRanges: [],
        speakers: [
            MaterializedSpeakerSpan(id: "S1", startMilliseconds: 0, endMilliseconds: 600, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "S8", startMilliseconds: 400, endMilliseconds: 1_000, confidence: nil, displayLabel: nil),
            MaterializedSpeakerSpan(id: "S9", startMilliseconds: 700, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)
        ], isDiarized: true
    )

    #expect(SpeakerDisplayMapper.turnLabels(
        for: segment, labels: SpeakerDisplayMapper.makeLabels(spans: spans)
    ) == ["Speaker 1", "OTHER"])
}

@Test
func liveProjectionSummarizesMultipleSpeakersAndKeepsUnknownLabel() throws {
    let overlappingSpeakers = [
        MaterializedSpeakerSpan(id: "S1", startMilliseconds: 0, endMilliseconds: 1_000, confidence: nil, displayLabel: nil),
        MaterializedSpeakerSpan(id: "S2", startMilliseconds: 500, endMilliseconds: 1_000, confidence: nil, displayLabel: nil)
    ]
    let segments = [
        try MaterializedTranscriptSegment.fixture(
            segmentID: "overlap", startMilliseconds: 0, endMilliseconds: 1_000,
            text: "重なり", fillerRanges: [], speakers: overlappingSpeakers, isDiarized: true
        ),
        try MaterializedTranscriptSegment.fixture(
            segmentID: "unknown", startMilliseconds: 1_000, endMilliseconds: 2_000,
            text: "不明", fillerRanges: [], speakers: [], isDiarized: true
        )
    ]

    let projection = LiveTranscriptProjection()
    let finalRows = try projection.rows(for: segments)
    #expect(finalRows[0].speakers.map(\.id) == ["S1", "S2"])
    #expect(finalRows[0].displaySpeakerLabels == ["Speaker 1", "Speaker 2"])
    #expect(finalRows[1].displaySpeakerLabels == ["UNKNOWN"])
}
