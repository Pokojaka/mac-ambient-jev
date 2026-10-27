import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization
import MacAmbientJevONNX

public enum PortableModelKind: String, CaseIterable, Sendable, Equatable {
    case vad
    case asr
    case diarization
    case clauseTagger = "clause_tagger"
}

public enum PortableModelPreparationStage: String, Sendable, Equatable {
    case validating
    case loading
}

/// `completed` counts the models finished in `stage`. `model` is the one starting; it is nil on the
/// closing event of a stage, where `completed == total`.
public struct PortableModelPreparationProgress: Sendable, Equatable {
    public let stage: PortableModelPreparationStage
    public let model: PortableModelKind?
    public let completed: Int
    public let total: Int
}

public enum PortableModelPreparationError: Error, LocalizedError, Equatable {
    case missing(model: PortableModelKind, path: String, installCommand: String)
    case invalid(model: PortableModelKind, path: String, detail: String, installCommand: String)
    case loadFailed(model: PortableModelKind, path: String, detail: String)

    public var model: PortableModelKind {
        switch self {
        case let .missing(model, _, _), let .invalid(model, _, _, _), let .loadFailed(model, _, _): model
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .missing(model, path, command):
            "モデル(\(model.rawValue))がありません: \(path)。次の手順で配置してください: \(command)"
        case let .invalid(model, path, detail, command):
            "モデル(\(model.rawValue))が不正です: \(path) (\(detail))。次の手順で配置し直してください: \(command)"
        case let .loadFailed(model, path, detail):
            "モデル(\(model.rawValue))を読み込めません: \(path) (\(detail))"
        }
    }
}

struct PortableAssetFile: Equatable {
    let name: String
    let byteCount: Int64?
    let sha256: String
}

/// Existence, regular-file type, size and streamed SHA-256 of pinned files in one directory.
enum PortableAssetVerifier {
    static func verify(
        model: PortableModelKind,
        files: [PortableAssetFile],
        directory: URL,
        installCommand: String
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw PortableModelPreparationError.missing(model: model, path: directory.path, installCommand: installCommand)
        }
        guard isDirectory.boolValue else {
            throw invalid(model, directory, "ディレクトリではありません", installCommand)
        }
        for file in files {
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                throw PortableModelPreparationError.missing(model: model, path: url.path, installCommand: installCommand)
            } catch {
                throw invalid(model, url, "ファイル情報を取得できません: \(error.localizedDescription)", installCommand)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw invalid(model, url, "通常ファイルではありません", installCommand)
            }
            if let expected = file.byteCount {
                let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actual == expected else {
                    throw invalid(model, url, "サイズが一致しません (期待: \(expected), 実際: \(actual))", installCommand)
                }
            }
            let digest: String
            do {
                digest = try FileSHA256.hexDigest(ofFileAt: url)
            } catch {
                throw invalid(model, url, "読み込めません: \(error.localizedDescription)", installCommand)
            }
            guard digest == file.sha256 else {
                throw invalid(model, url, "SHA-256 が一致しません (期待: \(file.sha256), 実際: \(digest))", installCommand)
            }
        }
    }

    private static func invalid(
        _ model: PortableModelKind, _ url: URL, _ detail: String, _ installCommand: String
    ) -> PortableModelPreparationError {
        .invalid(model: model, path: url.path, detail: detail, installCommand: installCommand)
    }
}

/// Verifies the pinned installed models of one configuration, then loads each, in order VAD, ASR, diarization and,
/// only when the configuration has a clause tagger directory, the tagger. It never downloads, never substitutes a
/// model and creates no recognition or decision request. Each model is released after it loads.
public struct PortableModelPreparationService: Sendable {
    struct Step: Sendable {
        let model: PortableModelKind
        let validate: @Sendable () throws -> Void
        let load: @Sendable () async throws -> Void
    }

    public init() {}

    public func prepare(
        configuration: PortableProcessingConfiguration,
        onProgress: @escaping @Sendable (PortableModelPreparationProgress) -> Void
    ) async throws {
        try await Self.run(steps: try Self.steps(for: configuration), onProgress: onProgress)
    }

    static func run(
        steps: [Step],
        onProgress: @escaping @Sendable (PortableModelPreparationProgress) -> Void
    ) async throws {
        let total = steps.count
        for stage in [PortableModelPreparationStage.validating, .loading] {
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                onProgress(PortableModelPreparationProgress(stage: stage, model: step.model, completed: index, total: total))
                switch stage {
                case .validating:
                    try await Task.detached(executorPreference: BlockingIOExecutor.shared) { try step.validate() }.value
                case .loading:
                    try await step.load()
                }
            }
            onProgress(PortableModelPreparationProgress(stage: stage, model: nil, completed: total, total: total))
        }
    }

    static func steps(for configuration: PortableProcessingConfiguration) throws -> [Step] {
        let threads = configuration.threads
        let silero = configuration.sileroModelURL
        let qwen = configuration.qwen3ModelDirectory
        let qwenSize = configuration.qwen3Size
        let diarization = configuration.diarizationModelDirectory
        let diarizationFiles = try Community1Assets.pinnedIdentity().fileSHA256
            .sorted { $0.key < $1.key }
            .map { PortableAssetFile(name: $0.key, byteCount: nil, sha256: $0.value) }

        var steps = [
            Step(
                model: .vad,
                validate: {
                    try PortableAssetVerifier.verify(
                        model: .vad,
                        files: [PortableAssetFile(name: silero.lastPathComponent, byteCount: nil, sha256: SileroVADModel.sha256)],
                        directory: silero.deletingLastPathComponent(),
                        installCommand: "python3 scripts/fetch_silero_vad.py を実行し、出力されたファイルを \(silero.path) に置く"
                    )
                },
                load: {
                    try await Self.load(.vad, path: silero.path) {
                        let environment = try ONNXEnvironment.shared()
                        try await Task.detached(executorPreference: BlockingIOExecutor.shared) { _ = try SileroVAD(environment: environment, modelURL: silero, intraOpThreads: 1) }.value
                    }
                }
            ),
            Step(
                model: .asr,
                validate: {
                    try PortableAssetVerifier.verify(
                        model: .asr,
                        files: qwenSize.files.map { PortableAssetFile(name: $0.name, byteCount: $0.byteCount, sha256: $0.sha256) },
                        directory: qwen,
                        installCommand: "python3 scripts/fetch_qwen3_asr_model.py \(qwenSize.rawValue) \(qwen.deletingLastPathComponent().path)"
                    )
                },
                load: {
                    try await Self.load(.asr, path: qwen.path) {
                        let engine = ONNXQwen3ASREngine(modelDirectory: qwen, size: qwenSize, intraOpThreads: threads)
                        try await engine.prepare()
                        await engine.unload()
                    }
                }
            ),
            Step(
                model: .diarization,
                validate: {
                    try PortableAssetVerifier.verify(
                        model: .diarization,
                        files: diarizationFiles,
                        directory: diarization,
                        installCommand: "python3 scripts/fetch_community1_diarization.py を実行し、出力されたディレクトリの内容を \(diarization.path) に置く"
                    )
                },
                load: {
                    try await Self.load(.diarization, path: diarization.path) {
                        let engine = try ONNXCommunity1DiarizationEngine(modelDirectory: diarization, intraOpThreads: threads)
                        try await engine.prepare()
                        await engine.unload()
                    }
                }
            ),
        ]

        if let tagger = configuration.clauseTaggerModelDirectory {
            steps.append(Step(
                model: .clauseTagger,
                validate: {
                    _ = try PortableClauseTaggerInspection.validateAssets(modelDirectory: tagger)
                },
                load: {
                    try await Self.load(.clauseTagger, path: tagger.path) {
                        try await Task.detached(executorPreference: BlockingIOExecutor.shared) { _ = try ONNXClauseTagger(modelDirectory: tagger, intraOpThreads: threads) }.value
                    }
                }
            ))
        }
        return steps
    }

    private static func load(
        _ model: PortableModelKind, path: String, _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PortableModelPreparationError.loadFailed(model: model, path: path, detail: error.localizedDescription)
        }
    }
}
