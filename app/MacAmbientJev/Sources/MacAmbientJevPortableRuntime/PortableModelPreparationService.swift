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
    case missing(model: PortableModelKind, path: String, guidance: String)
    case invalid(model: PortableModelKind, path: String, detail: String, guidance: String)
    case loadFailed(model: PortableModelKind, path: String, detail: String)

    public var model: PortableModelKind {
        switch self {
        case let .missing(model, _, _), let .invalid(model, _, _, _), let .loadFailed(model, _, _): model
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .missing(model, path, guidance):
            "モデル(\(model.rawValue))がありません: \(path)。\(guidance)"
        case let .invalid(model, path, detail, guidance):
            "モデル(\(model.rawValue))が不正です: \(path) (\(detail))。\(guidance)"
        case let .loadFailed(model, path, detail):
            "モデル(\(model.rawValue))を読み込めません: \(path) (\(detail))"
        }
    }
}

/// Verifies the pinned installed models of one configuration, then loads each, in order VAD, ASR, diarization and,
/// only when the configuration has a clause tagger directory, the tagger. It never downloads (see
/// `PortableModelDownloads`), never substitutes a
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
        let sileroGuidance = configuration.sileroGuidance
        let clauseTaggerGuidance = configuration.clauseTaggerGuidance
        let qwen = configuration.qwen3ModelDirectory
        let qwenSize = configuration.qwen3Size
        let diarization = configuration.diarizationModelDirectory
        let diarizationFiles = try Community1Assets.manifestEntries().flatMap(\.files)

        var steps = [
            Step(
                model: .vad,
                validate: {
                    try Self.verify(
                        .vad,
                        directory: silero.deletingLastPathComponent(),
                        files: [SileroVADModel.manifestFile],
                        guidance: sileroGuidance
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
                    try Self.verify(.asr, directory: qwen, files: qwenSize.manifestEntry.files, guidance: Self.downloadGuidance)
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
                    try Self.verify(.diarization, directory: diarization, files: diarizationFiles, guidance: Self.downloadGuidance)
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
                    _ = try PortableClauseTaggerInspection.validateAssets(modelDirectory: tagger, guidance: clauseTaggerGuidance)
                },
                load: {
                    try await Self.load(.clauseTagger, path: tagger.path) {
                        try await Task.detached(executorPreference: BlockingIOExecutor.shared) { _ = try ONNXClauseTagger(modelDirectory: tagger, guidance: clauseTaggerGuidance, intraOpThreads: threads) }.value
                    }
                }
            ))
        }
        return steps
    }

    static let downloadGuidance = "設定画面の「モデルを準備」を押すと、もう一度ダウンロードします"

    /// Verifies every file with `ModelVerifier`. A downloaded file (ASR, diarization) that fails the size or
    /// hash check is deleted so the next preparation downloads it again.
    static func verify(
        _ model: PortableModelKind, directory: URL, files: [ModelManifestFile], guidance: String
    ) throws {
        for file in files {
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            do {
                try ModelVerifier.verify(file, in: directory)
            } catch let error as ModelVerificationError {
                let detail: String
                switch error {
                case .missing:
                    throw PortableModelPreparationError.missing(model: model, path: url.path, guidance: guidance)
                case let .wrongSize(_, expected, actual):
                    detail = "サイズが一致しません (期待: \(expected), 実際: \(actual))"
                case let .wrongHash(_, expected, actual):
                    detail = "SHA-256 が一致しません (期待: \(expected), 実際: \(actual))"
                case .notRegularFile:
                    throw PortableModelPreparationError.invalid(
                        model: model, path: url.path, detail: "通常ファイルではありません", guidance: guidance
                    )
                case let .unreadable(_, reason):
                    throw PortableModelPreparationError.invalid(
                        model: model, path: url.path, detail: "読み込めません: \(reason)", guidance: guidance
                    )
                }
                var deleted = ""
                if model == .asr || model == .diarization {
                    try SessionFileAccess.removeIfPresent(url, relativeTo: directory)
                    deleted = "。ファイルを削除しました"
                }
                throw PortableModelPreparationError.invalid(
                    model: model, path: url.path, detail: detail + deleted, guidance: guidance
                )
            }
        }
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
