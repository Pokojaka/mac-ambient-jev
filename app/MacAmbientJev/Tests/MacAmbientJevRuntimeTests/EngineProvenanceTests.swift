import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline
import Testing
@testable import MacAmbientJevRuntime

private struct ResolvedPin: Decodable {
    struct State: Decodable {
        let version: String?
    }

    let identity: String
    let state: State
}

private struct ResolvedPackages: Decodable {
    let pins: [ResolvedPin]
}

private func resolvedPin(_ identity: String) throws -> ResolvedPin {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resolved = try JSONDecoder().decode(
        ResolvedPackages.self,
        from: Data(contentsOf: packageRoot.appending(path: "Package.resolved"))
    )
    return try #require(resolved.pins.first { $0.identity == identity })
}

@Test
func productionEngineProvenanceNamesHaasAndResolvedFluidAudioPin() throws {
    let fluidAudio = try #require(try resolvedPin("fluidaudio").state.version)
    let paths = AppPaths(
        applicationSupportURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
        cacheURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
        sessionsRootOverride: nil
    )

    let models = try MacModelStore(paths: paths)
    let production = SessionProcessingEngines.production(models: models)
    #expect(production.asr.provenance == RunProvenance(
        engine: "onnxruntime-haas-tdt",
        model: "Sanami/haas-ja-onnx/int8dyn",
        version: "haas-ja-v1.0@354baedfd9612b00e74cc1ae87dff7f2c558db6f+onnxruntime@1.31.0",
        configuration: [
            "language": "ja",
            "decoding": "tdt-greedy",
            "max_symbols_per_frame": "10",
            "intra_op_threads": "4",
            "minimum_input_seconds": "0.02",
            "maximum_input_seconds": "30.0",
        ]
    ))
    #expect(production.sessionVAD.provenance.version == "FluidAudio@\(fluidAudio)")
}
