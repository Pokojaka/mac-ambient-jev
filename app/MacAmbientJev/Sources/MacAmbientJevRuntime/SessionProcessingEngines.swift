import MacAmbientJevCore
import MacAmbientJevPipeline

public extension SessionProcessingEngines {
    /// Creates the production engines used by the app and command-line tools.
    static func production(paths: AppPaths) -> SessionProcessingEngines {
        SessionProcessingEngines(
            asr: NativeQwen3ASREngine(modelStore: ModelStore(paths: paths)),
            diarization: FluidOfflineDiarizationEngine(paths: paths),
            finalTranscriptVAD: FluidFinalTranscriptVADSegmenter()
        )
    }
}
