import FluidAudio
import MacAmbientJevCore
import MacAmbientJevPipeline

struct FluidFinalTranscriptVADSegmenter: FinalTranscriptVADSegmenter {
    static let version = "FluidAudio@0.15.8"

    var provenance: RunProvenance {
        RunProvenance(
            engine: "fluidaudio-silero-vad",
            model: Repo.vad.rawValue,
            version: Self.version,
            configuration: [
                "pre_roll_seconds": String(FluidVADSegmentationEngine.preRollSeconds),
                "max_segment_seconds": String(FluidVADSegmentationEngine.maxSegmentSeconds),
                "min_silence_seconds": String(FluidVADSegmentationEngine.minSilenceSeconds),
                "vad_threshold": String(FluidVADSegmentationEngine.speechProbabilityThreshold),
                "split_search_window_seconds": String(FluidVADSegmentationEngine.splitSearchWindowSeconds),
                "split_energy_frame_seconds": String(FluidVADSegmentationEngine.splitEnergyFrameSeconds),
                "minimum_independent_segment_seconds": String(FluidVADSegmentationEngine.minimumIndependentSegmentSeconds),
            ]
        )
    }

    func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference] {
        let engine = try await FluidVADSegmentationEngine.make(
            segmentationRunID: runID,
            canonicalSampleRate: reader.info.sampleRate,
            measureMicInputLevels: false
        )
        return try await VADTimelineProcessor(engine: engine).segmentAll(reader: reader)
    }
}
