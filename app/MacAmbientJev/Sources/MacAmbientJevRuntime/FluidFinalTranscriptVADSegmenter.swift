import FluidAudio
import MacAmbientJevCore
import MacAmbientJevPipeline

struct FluidFinalTranscriptVADSegmenter: FinalTranscriptVADSegmenter {
    static let version = "FluidAudio@0.15.8"

    let models: MacModelStore

    var provenance: RunProvenance {
        RunProvenance(
            engine: "fluidaudio-silero-vad",
            model: Repo.vad.rawValue,
            version: Self.version,
            configuration: VADSegmentationParameters.provenanceConfiguration
        )
    }

    func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference] {
        let engine = try await FluidVADSegmentationEngine.make(
            models: models,
            segmentationRunID: runID,
            canonicalSampleRate: reader.info.sampleRate,
            measureMicInputLevels: false
        )
        return try await VADTimelineProcessor(engine: engine).segmentAll(reader: reader)
    }
}
