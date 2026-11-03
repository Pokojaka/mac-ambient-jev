@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import MacAmbientJevCore

/// Builds FluidAudio's model objects from directories that `MacModelStore` has verified, with
/// `MLModel(contentsOf:)` only. FluidAudio's own loaders download missing files and purge a cache
/// that fails to load, so they never run.
enum FluidModelLoading {
    static func diarizerModels(from directory: URL) async throws -> OfflineDiarizerModels {
        try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
            let started = Date()
            let names = ModelNames.OfflineDiarizer.self
            return OfflineDiarizerModels(
                segmentationModel: try coreMLModel(directory, names.segmentationPath, .all),
                fbankModel: try coreMLModel(directory, names.fbankPath, .cpuOnly),
                embeddingModel: try coreMLModel(directory, names.embeddingPath, .all),
                pldaRhoModel: try coreMLModel(directory, names.pldaRhoPath, .all),
                pldaPsi: try pldaPsi(directory.appending(path: names.pldaParameters)),
                compilationDuration: Date().timeIntervalSince(started)
            )
        }.value
    }

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

    /// The `psi` tensor of `plda-parameters.json`: base64 little-endian Float32, widened to Double.
    static func pldaPsi(_ url: URL) throws -> [Double] {
        guard
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any],
            let base64 = psi["data_base64"] as? String,
            let bytes = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
            bytes.count >= MemoryLayout<Float>.size
        else {
            throw OfflineDiarizationError.processingFailed("PLDA psi parameters are missing or empty in \(url.path)")
        }
        var floats = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}
