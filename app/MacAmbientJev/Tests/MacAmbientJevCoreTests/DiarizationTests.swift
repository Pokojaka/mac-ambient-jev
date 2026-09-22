import Testing
@testable import MacAmbientJevCore

@Test
func speakerSpanMapperMapsSecondsOntoCanonicalFrames() {
    let mapper = SpeakerSpanMapper(sampleRate: 48_000)
    let span = mapper.map(
        speakerID: "speaker_1",
        startSeconds: 1.25,
        endSeconds: 2.0,
        confidence: 0.8
    )

    #expect(span.startFrame == 60_000)
    #expect(span.endFrame == 96_000)
    #expect(span.speakerID == "speaker_1")
    #expect(span.confidence == 0.8)
}

@Test
func completedOfflineDiarizationRunCanReplaceStreamingRun() throws {
    var runs = ActiveRuns(diarization: "diar_stream_01")
    runs.markCompleted(
        stage: .diarization,
        runID: "diar_offline_02",
        succeeded: true
    )
    try runs.select(stage: .diarization, runID: "diar_offline_02")

    #expect(runs.diarization == "diar_offline_02")
}
