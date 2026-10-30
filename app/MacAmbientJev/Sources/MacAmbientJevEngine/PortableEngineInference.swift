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
    let clauseTaggerInspection: PortableClauseTaggerInspection
    let usageCounter = DecisionUsageCounter()

    init(layout: PortableInstalledModelLayout, logicalCPUCount: Int) {
        self.init(
            layout: layout,
            logicalCPUCount: logicalCPUCount,
            clauseTaggerInspection: PortableClauseTaggerInspection(
                modelDirectory: { try layout.clauseTaggerDirectory() }
            )
        )
    }

    init(
        layout: PortableInstalledModelLayout,
        logicalCPUCount: Int,
        clauseTaggerInspection: PortableClauseTaggerInspection
    ) {
        self.layout = layout
        self.logicalCPUCount = logicalCPUCount
        self.clauseTaggerInspection = clauseTaggerInspection
    }

    func configuration(for settings: EngineSettings) throws -> PortableProcessingConfiguration {
        guard let size = ASRModelSize(rawValue: settings.asrSize.rawValue) else {
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
            throw Self.modelError(error)
        }
    }

    static func modelError(_ error: PortableModelPreparationError) -> EngineAdapterError {
        let code: EngineErrorCode
        switch error {
        case .missing: code = .modelMissing
        case .invalid: code = .modelCorrupt
        case .loadFailed: code = .modelFailure
        }
        return EngineAdapterError(
            code: code, message: error.localizedDescription, recoveryAction: .prepareModels,
            details: [EngineAdapterError.detail(domain: "models", code: error.model.rawValue, message: error.localizedDescription)]
        )
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        do {
            return try await clauseTaggerInspection.inspect()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PortableModelPreparationError {
            throw Self.modelError(error)
        } catch {
            throw EngineAdapterError(
                code: .modelFailure,
                message: "発話文モデルを確認できません: \(error.localizedDescription)",
                recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        let configuration = try configuration(for: settings)
        let bundle: PortableSessionEngineBundle
        do {
            bundle = try PortableSessionEngineBundle(configuration: configuration, usageCounter: usageCounter)
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
