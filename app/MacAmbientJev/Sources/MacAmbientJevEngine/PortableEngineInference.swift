import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
import MacAmbientJevPortableRuntime

/// The installed-model inference of the engine: `PortableModelPreparationService` verifies and loads the pinned
/// models under the application's models directory, and `PortableSessionEngineBundle` builds the engines.
struct PortableEngineInference: EngineInferenceProviding {
    let layout: PortableInstalledModelLayout
    let logicalCPUCount: Int

    func configuration(for settings: EngineSettings) throws -> PortableProcessingConfiguration {
        guard let size = Qwen3ASRModelSize(rawValue: settings.asrSize.rawValue) else {
            throw EngineAdapterError(
                code: .invalidSettings, message: "ASR サイズ \(settings.asrSize.rawValue) はインストール済みモデルにありません",
                recoveryAction: .replaceSettings, details: []
            )
        }
        do {
            return try PortableProcessingConfiguration.installed(
                layout: layout, qwen3Size: size, threads: settings.threads, logicalCPUCount: logicalCPUCount,
                withDecisions: settings.decisionsEnabled
            )
        } catch {
            throw EngineAdapterError(
                code: .invalidSettings, message: error.localizedDescription, recoveryAction: .replaceSettings,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
    }

    func prepare(settings: EngineSettings, onProgress: @escaping @Sendable (EngineModelProgress) -> Void) async throws {
        let configuration = try configuration(for: settings)
        do {
            try await PortableModelPreparationService().prepare(configuration: configuration) { progress in
                let stage: EngineModelProgress.Stage = progress.stage == .validating ? .validating : .loading
                onProgress(EngineModelProgress(stage: stage, completed: progress.completed, total: progress.total))
            }
        } catch let error as PortableModelPreparationError {
            let code: EngineErrorCode
            switch error {
            case .missing: code = .modelMissing
            case .invalid: code = .modelCorrupt
            case .loadFailed: code = .modelFailure
            }
            throw EngineAdapterError(
                code: code, message: error.localizedDescription, recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(domain: "models", code: error.model.rawValue, message: error.localizedDescription)]
            )
        }
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let configuration = try configuration(for: settings)
        let bundle: PortableSessionEngineBundle
        do {
            bundle = try PortableSessionEngineBundle(configuration: configuration)
        } catch {
            throw EngineAdapterError(
                code: .modelFailure, message: "モデルを構成できません: \(error.localizedDescription)", recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
        return EngineInference(
            engines: bundle.engines,
            contentPriority: bundle.contentPriority,
            timelineBuilder: PortableImportedAudioTimelineBuilder(),
            makeLiveVADSession: { processingDirectory, sessionURL, checkpoint, runID in
                try SileroLiveVADSessionFactory.make(
                    environment: bundle.vadEnvironment,
                    modelURL: bundle.configuration.sileroModelURL,
                    intraOpThreads: 1,
                    processingDirectory: processingDirectory,
                    sessionURL: sessionURL,
                    initialCheckpoint: checkpoint,
                    measureMicInputLevels: false,
                    segmentationRunID: runID
                )
            }
        )
    }
}
