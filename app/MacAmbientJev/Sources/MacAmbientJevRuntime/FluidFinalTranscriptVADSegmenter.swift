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
            configuration: [
                "pre_roll_seconds": String(VADSegmentationParameters.preRollSeconds),
                "max_segment_seconds": String(VADSegmentationParameters.maxSegmentSeconds),
                "min_silence_seconds": String(VADSegmentationParameters.minSilenceSeconds),
                "vad_threshold": String(VADSegmentationParameters.speechProbabilityThreshold),
                "split_search_window_seconds": String(VADSegmentationParameters.splitSearchWindowSeconds),
                "split_energy_frame_seconds": String(VADSegmentationParameters.splitEnergyFrameSeconds),
                "minimum_independent_segment_seconds": String(VADSegmentationParameters.minimumIndependentSegmentSeconds),
            ]
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
