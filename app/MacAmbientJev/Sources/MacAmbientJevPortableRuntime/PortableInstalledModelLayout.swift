import Foundation
import MacAmbientJevDiarization

/// Where `models.prepare` expects the pinned model assets, derived from the bundled manifests and pins.
/// Nothing here reads the environment or the disk.
public struct PortableInstalledModelLayout: Sendable, Equatable {
    /// What a missing or corrupt bundled model tells the user: the installation is broken.
    public static let bundledModelGuidance = "アプリの zip を展開し直してください"

    /// Read-only models shipped with the app: Silero VAD and the clause tagger.
    public let bundledRoot: URL
    /// Models `models.prepare` downloads: Qwen3-ASR and community-1.
    public let downloadedRoot: URL

    public init(bundledRoot: URL, downloadedRoot: URL) {
        self.bundledRoot = bundledRoot
        self.downloadedRoot = downloadedRoot
    }

    /// `silero/<commit>/silero_vad_16k_op15.onnx`
    public var sileroModelURL: URL {
        bundledRoot
            .appending(path: "silero", directoryHint: .isDirectory)
            .appending(path: SileroVADModel.revision, directoryHint: .isDirectory)
            .appending(path: SileroVADModel.filename, directoryHint: .notDirectory)
    }

    /// `qwen3-asr-<size>-int4-<commit>`, the directory `scripts/fetch_qwen3_asr_model.py` creates under `downloadedRoot`.
    public func qwen3Directory(size: Qwen3ASRModelSize) -> URL {
        downloadedRoot.appending(path: "qwen3-asr-\(size.rawValue)-int4-\(size.commit)", directoryHint: .isDirectory)
    }

    /// `community1/<SHA-256 of the bundled manifest>`
    public func diarizationDirectory() throws -> URL {
        downloadedRoot
            .appending(path: "community1", directoryHint: .isDirectory)
            .appending(path: try Community1Assets.pinnedManifestSHA256(), directoryHint: .isDirectory)
    }

    /// `clause-tagger/<Hugging Face commit>/clause-tagger-onnx`
    public func clauseTaggerDirectory() throws -> URL {
        let source = try ClauseTaggerManifest.bundled().source
        return bundledRoot
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
        qwen3Size: Qwen3ASRModelSize,
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
            threads: try validatedThreads(threads, logicalCPUCount: logicalCPUCount),
            sileroGuidance: PortableInstalledModelLayout.bundledModelGuidance,
            clauseTaggerGuidance: PortableInstalledModelLayout.bundledModelGuidance
        )
    }
}
