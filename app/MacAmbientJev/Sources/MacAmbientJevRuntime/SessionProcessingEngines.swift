import MacAmbientJevCore
import MacAmbientJevPipeline

public extension SessionProcessingEngines {
    /// Creates the production engines used by the app and command-line tools. They load only the
    /// models `models` has verified and never download.
    static func production(models: MacModelStore) -> SessionProcessingEngines {
        SessionProcessingEngines(
            asr: NativeQwen3ASREngine(models: models),
            diarization: FluidOfflineDiarizationEngine(models: models),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter(models: models)
        )
    }
}
