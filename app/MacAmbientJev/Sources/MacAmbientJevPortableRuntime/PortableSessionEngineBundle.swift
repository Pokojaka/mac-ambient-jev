import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline

/// The concrete portable engines of one processing operation. Building it validates the Silero file and creates the ONNX
/// environment; the ASR, diarization and clause tagger models load on first use, and a failure there stops the operation.
public struct PortableSessionEngineBundle: Sendable {
    public let configuration: PortableProcessingConfiguration
    public let engines: SessionProcessingEngines
    /// The VAD's environment, which the live VAD session factory shares.
    public let vadEnvironment: ONNXEnvironment
    /// Non-nil exactly when the configuration requests decisions; `localModelIdentity()` loads the tagger once.
    public let decisionProviderFactory: DecisionProviderFactory?
    public let contentPriority: ContentPriorityAccess

    public init(configuration: PortableProcessingConfiguration) throws {
        try SileroVADModel.validate(at: configuration.sileroModelURL)
        let vadEnvironment = try ONNXEnvironment(loggingID: "MacAmbientJev-PortableProcessing")
        let engines = SessionProcessingEngines(
            asr: ONNXQwen3ASREngine(
                modelDirectory: configuration.qwen3ModelDirectory,
                size: configuration.qwen3Size,
                intraOpThreads: configuration.threads
            ),
            diarization: try ONNXCommunity1DiarizationEngine(
                modelDirectory: configuration.diarizationModelDirectory,
                intraOpThreads: configuration.threads
            ),
            finalTranscriptVAD: SileroFinalTranscriptVADSegmenter(
                environment: vadEnvironment,
                modelURL: configuration.sileroModelURL,
                intraOpThreads: 1
            )
        )

        self.configuration = configuration
        self.engines = engines
        self.vadEnvironment = vadEnvironment
        if let taggerDirectory = configuration.clauseTaggerModelDirectory {
            let usageCounter = DecisionUsageCounter()
            let threads = configuration.threads
            let factory = DecisionProviderFactory(
                usageCounter: usageCounter,
                loadProvider: {
                    let tagger = try ONNXClauseTagger(modelDirectory: taggerDirectory, intraOpThreads: threads)
                    return LoadedDecisionProvider(provider: tagger, identity: tagger.identity)
                }
            )
            decisionProviderFactory = factory
            contentPriority = .localTagger({ try factory.makeCoordinator() }, usageCounter: usageCounter)
        } else {
            decisionProviderFactory = nil
            contentPriority = .disabled
        }
    }
}
