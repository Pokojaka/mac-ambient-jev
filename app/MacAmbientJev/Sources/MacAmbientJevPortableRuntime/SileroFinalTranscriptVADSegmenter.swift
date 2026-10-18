import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline

public struct SileroFinalTranscriptVADSegmenter: FinalTranscriptVADSegmenter {
    private let environment: ONNXEnvironment
    private let modelURL: URL
    private let intraOpThreads: Int

    public init(environment: ONNXEnvironment, modelURL: URL, intraOpThreads: Int) {
        self.environment = environment
        self.modelURL = modelURL
        self.intraOpThreads = intraOpThreads
    }

    public var provenance: RunProvenance {
        RunProvenance(
            engine: "onnxruntime-silero-vad",
            model: SileroVADModel.filename,
            version: "silero-vad@\(SileroVADModel.revision)+onnxruntime@\(ONNXEnvironment.runtimeVersion)",
            configuration: [
                "pre_roll_seconds": String(VADSegmentationParameters.preRollSeconds),
                "max_segment_seconds": String(VADSegmentationParameters.maxSegmentSeconds),
                "min_silence_seconds": String(VADSegmentationParameters.minSilenceSeconds),
                "vad_threshold": String(VADSegmentationParameters.speechProbabilityThreshold),
                "split_search_window_seconds": String(VADSegmentationParameters.splitSearchWindowSeconds),
                "split_energy_frame_seconds": String(VADSegmentationParameters.splitEnergyFrameSeconds),
                "minimum_independent_segment_seconds": String(VADSegmentationParameters.minimumIndependentSegmentSeconds),
                "negative_vad_threshold": String(VADStreamingStateMachine.negativeThreshold),
                "chunk_samples": String(VADSegmentationParameters.chunkSamples),
                "frame_samples": String(SileroVAD.frameSamples),
                "frame_aggregation": "noisy-or",
                "model_sha256": SileroVADModel.sha256,
                "intra_op_threads": String(intraOpThreads),
            ]
        )
    }

    public func segment(
        reader: any TimelineAudioReading,
        runID: String
    ) async throws -> [SegmentReference] {
        let engine = try SileroVADSegmentationEngine(
            environment: environment,
            modelURL: modelURL,
            intraOpThreads: intraOpThreads,
            segmentationRunID: runID,
            canonicalSampleRate: reader.info.sampleRate,
            measureMicInputLevels: false
        )
        return try await VADTimelineProcessor(engine: engine).segmentAll(reader: reader)
    }
}
