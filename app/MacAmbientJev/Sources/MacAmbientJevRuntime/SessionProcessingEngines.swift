import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevHaasASR

public extension SessionProcessingEngines {
    /// Creates the production engines used by the app and command-line tools. They load only the
    /// models `models` has verified and never download.
    static func production(models: MacModelStore) -> SessionProcessingEngines {
        SessionProcessingEngines(
            asr: HaasASREngine(intraOpThreads: HaasASREngine.macIntraOpThreads) {
                HaasASRModelFiles(verifiedDirectory: try await models.verifiedDirectory(.asr))
            },
            sessionVAD: FluidSessionVADSegmenter(models: models)
        )
    }
}
