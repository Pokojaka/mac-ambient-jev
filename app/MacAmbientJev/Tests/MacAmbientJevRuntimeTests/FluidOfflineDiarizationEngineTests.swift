import Foundation
import FluidAudio
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline
@testable import MacAmbientJevRuntime

private func fluidSegment(startFrame: Int64, endFrame: Int64) -> TimedSpeakerSegment {
    TimedSpeakerSegment(
        speakerId: "S1", embedding: [],
        startTimeSeconds: Float(Double(startFrame) / CanonicalAudio.sampleRate),
        endTimeSeconds: Float(Double(endFrame) / CanonicalAudio.sampleRate),
        qualityScore: 0.75
    )
}

@Test(arguments: [
    (16_000, Int64(8_000), Int64(16_660)),
    (1_567_286, Int64(807_878), Int64(1_567_946)),
    (160_000, Int64(8_000), Int64(288_000)),
    (160_001, Int64(8_000), Int64(320_000))
])
func fluidDiarizationBoundsOnlyFinalWindowPadding(sampleCount: Int, startFrame: Int64, endFrame: Int64) throws {
    let spans = try FluidOfflineDiarizationEngine.mapSegments(
        [fluidSegment(startFrame: startFrame, endFrame: endFrame)],
        sampleCount: sampleCount, config: .default
    )
    #expect(spans == [SpeakerSpan(speakerID: "S1", startFrame: startFrame,
        endFrame: Int64(sampleCount), confidence: 0.75)])
}

@Test(arguments: [
    (16_000, Int64(16_000), Int64(16_660)),
    (16_000, Int64(16_001), Int64(16_660)),
    (16_000, Int64(8_000), Int64(160_001)),
    (160_000, Int64(8_000), Int64(288_001)),
    (160_001, Int64(8_000), Int64(320_001)),
    (16_000, Int64(-1), Int64(16_660)),
    (16_000, Int64(8_000), Int64(8_000)),
    (16_000, Int64(8_000), Int64(7_999)),
    (0, Int64(0), Int64(1))
])
func fluidDiarizationRejectsInvalidOrBeyondPaddingSpans(sampleCount: Int, startFrame: Int64, endFrame: Int64) {
    #expect(throws: FinalTranscriptPipelineError.self) {
        try FluidOfflineDiarizationEngine.mapSegments(
            [fluidSegment(startFrame: startFrame, endFrame: endFrame)],
            sampleCount: sampleCount, config: .default
        )
    }
}

@Test
func fluidDiarizationUsesConfiguredWindowScheduleAndKeepsInRangeSpan() throws {
    var config = OfflineDiarizerConfig.default
    config.segmentation.stepRatio = 1
    let withinAudio = fluidSegment(startFrame: 8_000, endFrame: 16_000)
    let spans = try FluidOfflineDiarizationEngine.mapSegments(
        [withinAudio], sampleCount: 160_000, config: config
    )
    #expect(spans == [SpeakerSpan(speakerID: "S1", startFrame: 8_000, endFrame: 16_000, confidence: 0.75)])
    #expect(throws: FinalTranscriptPipelineError.self) {
        try FluidOfflineDiarizationEngine.mapSegments(
            [fluidSegment(startFrame: 8_000, endFrame: 160_001)],
            sampleCount: 160_000, config: config
        )
    }
}

@Test
func fluidDiarizationProductionConfigurationOverridesOnlyMinimumSegmentDuration() throws {
    let config = FluidOfflineDiarizationEngine.configuration
    let defaults = OfflineDiarizerConfig.default

    #expect(defaults.embedding.minSegmentDurationSeconds == 1.0)
    #expect(config.embedding.minSegmentDurationSeconds == 0.3)
    try config.validate()
    #expect(Double(config.segmentation.sampleRate) == CanonicalAudio.sampleRate)
    #expect(config.segmentation.stepRatio == defaults.segmentation.stepRatio)
    #expect(config.segmentation.windowDurationSeconds == defaults.segmentation.windowDurationSeconds)
    #expect(config.embedding.excludeOverlap == defaults.embedding.excludeOverlap)
    #expect(config.embedding.batchSize == defaults.embedding.batchSize)
    #expect(config.clustering.threshold == defaults.clustering.threshold)
    #expect(config.postProcessing.minGapDurationSeconds == defaults.postProcessing.minGapDurationSeconds)
    #expect(config.postProcessing.exclusiveSegments == defaults.postProcessing.exclusiveSegments)
}

@Test
func fluidDiarizationProvenanceRecordsProductionConfiguration() {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
    )
    let paths = AppPaths(
        applicationSupportURL: temporaryRoot.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: temporaryRoot.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: temporaryRoot.appending(path: "sessions", directoryHint: .isDirectory)
    )
    let provenance = FluidOfflineDiarizationEngine(paths: paths).provenance

    #expect(provenance.version == "FluidAudio@0.15.8")
    #expect(provenance.configuration == [
        "config": "OfflineDiarizerConfig.default",
        "embedding.min_segment_duration_seconds": "0.3"
    ])
}
