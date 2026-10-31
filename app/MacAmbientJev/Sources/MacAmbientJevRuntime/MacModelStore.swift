import Foundation
import MacAmbientJevCore

public enum MacModelError: Error, Equatable, LocalizedError, Sendable {
    case notInstalled(MacModel)
    case invalid(MacModel, ModelVerificationError)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(model):
            "\(model.displayName)のモデルがありません。アプリの設定画面でモデルを取得してください。"
        case let .invalid(model, error):
            "\(model.displayName)のモデルが想定と違います（\(Self.detail(error))）。アプリの設定画面でモデルを取得し直してください。"
        }
    }

    private static func detail(_ error: ModelVerificationError) -> String {
        switch error {
        case let .missing(file): "\(file) がありません"
        case let .notRegularFile(file): "\(file) が通常のファイルではありません"
        case let .wrongSize(file, expected, actual): "\(file) のサイズが違います（想定 \(expected) バイト、実際 \(actual) バイト）"
        case let .wrongHash(file, _, _): "\(file) の内容が違います"
        case let .unreadable(file, reason): "\(file) を読めません: \(reason)"
        }
    }
}

extension MacModel {
    /// The model directory relative to `modelsRoot`. The diarization models sit one level down
    /// because the repository folder is part of the layout FluidAudio's own cache used.
    var relativeDirectory: String {
        switch self {
        case .asr: "qwen3-asr-1.7b-mlx-8bit"
        case .diarization: "fluidaudio-offline-diarizer/speaker-diarization"
        case .vad: "fluidaudio-silero-vad"
        }
    }
}

/// Owns where each Mac model lives under `modelsRoot` and whether its files match the manifest.
/// Engines load only from `verifiedDirectory`; only `fetch` writes model files.
public final class MacModelStore: Sendable {
    private let modelsRoot: URL
    private let directories: [MacModel: URL]
    private let manifest: [MacModel: ModelManifestEntry]
    private let verifyFiles: @Sendable (URL, ModelManifestEntry) throws -> Void
    private let state = VerificationState()

    public convenience init(paths: AppPaths) throws {
        try self.init(
            modelsRoot: paths.modelsRoot,
            manifest: MacModelManifest.bundled(),
            verify: { try ModelVerifier.verify(directory: $0, entry: $1) }
        )
    }

    /// A store whose diarization model sits in `directory`, for the measurement oracle. The
    /// files are still checked against the manifest.
    public convenience init(diarizationDirectory directory: URL) throws {
        try self.init(
            modelsRoot: directory,
            manifest: MacModelManifest.bundled(),
            verify: { try ModelVerifier.verify(directory: $0, entry: $1) },
            directories: [.diarization: directory]
        )
    }

    init(
        modelsRoot: URL,
        manifest: [MacModel: ModelManifestEntry],
        verify: @escaping @Sendable (URL, ModelManifestEntry) throws -> Void,
        directories: [MacModel: URL] = [:]
    ) {
        self.modelsRoot = modelsRoot
        self.directories = directories
        self.manifest = manifest
        self.verifyFiles = verify
    }

    public func entry(_ model: MacModel) -> ModelManifestEntry { manifest[model]! }

    public func directory(_ model: MacModel) -> URL {
        directories[model] ?? modelsRoot.appending(path: model.relativeDirectory, directoryHint: .isDirectory)
    }

    /// A cheap check without hashing: every manifest file is a regular file of the pinned byte count.
    public func isFetched(_ model: MacModel) -> Bool {
        let directory = directory(model)
        return entry(model).files.allSatisfy { file in
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: directory.appending(path: file.name).path
            ) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
                && (attributes[.size] as? NSNumber)?.int64Value == file.byteCount
        }
    }

    /// Verifies every manifest file of `model` once per process on `BlockingIOExecutor`. Callers
    /// that arrive during a verification share it. A failure is thrown and not remembered.
    public func verifiedDirectory(_ model: MacModel) async throws -> URL {
        let directory = directory(model)
        let entry = entry(model)
        let verify = verifyFiles
        try await state.ensureVerified(model) {
            try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                do {
                    try verify(directory, entry)
                } catch let error as ModelVerificationError {
                    if case .missing = error { throw MacModelError.notInstalled(model) }
                    throw MacModelError.invalid(model, error)
                }
            }.value
        }
        return directory
    }

    /// Downloads the pinned files of `model` and forgets that it was verified, so the next
    /// `verifiedDirectory` hashes the files again.
    public func fetch(
        _ model: MacModel,
        transport: any ModelDownloadTransport,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        await state.invalidate(model)
        do {
            try await ModelFetcher.fetch(
                into: directory(model), entry: entry(model), transport: transport, progress: progress
            )
        } catch {
            await state.invalidate(model)
            throw error
        }
        await state.invalidate(model)
    }
}

private actor VerificationState {
    private var verified = Set<MacModel>()
    private var inFlight: [MacModel: Task<Void, Error>] = [:]
    private var generation: [MacModel: Int] = [:]

    func ensureVerified(_ model: MacModel, run: @escaping @Sendable () async throws -> Void) async throws {
        while !verified.contains(model) {
            let startedAt = generation[model, default: 0]
            let task: Task<Void, Error>
            if let existing = inFlight[model] {
                task = existing
            } else {
                task = Task { try await run() }
                inFlight[model] = task
            }
            do {
                try await task.value
            } catch {
                if inFlight[model] == task { inFlight[model] = nil }
                throw error
            }
            if inFlight[model] == task { inFlight[model] = nil }
            if generation[model, default: 0] == startedAt { verified.insert(model) }
        }
    }

    func invalidate(_ model: MacModel) {
        verified.remove(model)
        inFlight[model] = nil
        generation[model, default: 0] += 1
    }
}
