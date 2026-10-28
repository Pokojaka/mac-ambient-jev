import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization

/// Where `models.prepare` expects the pinned model assets, derived from the bundled manifests and pins
/// under the application models directory. Nothing here reads the environment or the disk.
public struct PortableInstalledModelLayout: Sendable, Equatable {
    public let modelsRoot: URL

    public init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
    }

    /// `silero/<commit>/silero_vad_16k_op15.onnx`
    public var sileroModelURL: URL {
        modelsRoot
            .appending(path: "silero", directoryHint: .isDirectory)
            .appending(path: SileroVADModel.revision, directoryHint: .isDirectory)
            .appending(path: SileroVADModel.filename, directoryHint: .notDirectory)
    }

    /// `qwen3-asr-<size>-int4-<commit>`, the directory `scripts/fetch_qwen3_asr_model.py` creates under `modelsRoot`.
    public func qwen3Directory(size: ASRModelSize) -> URL {
        modelsRoot.appending(path: "qwen3-asr-\(size.rawValue)-int4-\(size.commit)", directoryHint: .isDirectory)
    }

    /// `community1/<SHA-256 of the bundled manifest>`
    public func diarizationDirectory() throws -> URL {
        modelsRoot
            .appending(path: "community1", directoryHint: .isDirectory)
            .appending(path: try Community1Assets.pinnedManifestSHA256(), directoryHint: .isDirectory)
    }

    /// `clause-tagger/<Hugging Face commit>/clause-tagger-onnx`
    public func clauseTaggerDirectory() throws -> URL {
        let source = try ClauseTaggerManifest.bundled().source
        return modelsRoot
            .appending(path: "clause-tagger", directoryHint: .isDirectory)
            .appending(path: source.commit, directoryHint: .isDirectory)
            .appending(path: "clause-tagger-onnx", directoryHint: .isDirectory)
    }
}

extension PortableProcessingConfiguration {
    /// The configuration of an installed model profile. The clause tagger is included exactly when `withDecisions`.
    /// Threads are validated by the same rule as `resolve`; the paths are not checked here, `PortableModelPreparationService` does.
    public static func installed(
        layout: PortableInstalledModelLayout,
        qwen3Size: ASRModelSize,
        threads: Int,
        logicalCPUCount: Int,
        withDecisions: Bool
    ) throws -> PortableProcessingConfiguration {
        PortableProcessingConfiguration(
            sileroModelURL: layout.sileroModelURL,
            qwen3ModelDirectory: layout.qwen3Directory(size: qwen3Size),
            qwen3Size: qwen3Size,
            diarizationModelDirectory: try layout.diarizationDirectory(),
            clauseTaggerModelDirectory: withDecisions ? try layout.clauseTaggerDirectory() : nil,
            threads: try validatedThreads(threads, logicalCPUCount: logicalCPUCount)
        )
    }
}
