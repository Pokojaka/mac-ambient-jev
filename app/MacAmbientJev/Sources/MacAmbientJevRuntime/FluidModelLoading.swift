@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore

/// Builds FluidAudio's model objects from directories that `MacModelStore` has verified, with
/// `MLModel(contentsOf:)` only. FluidAudio's own loaders download missing files and purge a cache
/// that fails to load, so they never run.
enum FluidModelLoading {
    static func vadManager(from directory: URL, config: VadConfig) async throws -> VadManager {
        let model = try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
            try coreMLModel(directory, ModelNames.VAD.sileroVadFile, config.computeUnits)
        }.value
        return VadManager(config: config, vadModel: model)
    }

    private static func coreMLModel(_ directory: URL, _ name: String, _ units: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        configuration.allowLowPrecisionAccumulationOnGPU = true
        return try MLModel(contentsOf: directory.appending(path: name), configuration: configuration)
    }

}
