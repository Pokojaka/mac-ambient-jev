import Foundation
import MacAmbientJevCore

/// Coalesces concurrent inspections into one in-flight validation without caching results.
/// Cancelling a waiter does not cancel the shared validation; validation never creates an ONNX session.
public actor PortableClauseTaggerInspection {
    private let validate: @Sendable () async throws -> ClauseTaggerModelIdentity
    private var inFlight: Task<ClauseTaggerModelIdentity, any Error>?

    public init(modelDirectory: URL) {
        self.init(modelDirectory: { modelDirectory })
    }

    public init(modelDirectory: @escaping @Sendable () throws -> URL) {
        self.validate = {
            try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                let directory = try modelDirectory()
                return try Self.validateAssets(modelDirectory: directory)
            }.value
        }
    }

    init(validate: @escaping @Sendable () async throws -> ClauseTaggerModelIdentity) {
        self.validate = validate
    }

    public func inspect() async throws -> ClauseTaggerModelIdentity {
        try await inspect(onJoined: {})
    }

    func inspect(onJoined: @Sendable () -> Void) async throws -> ClauseTaggerModelIdentity {
        try Task.checkCancellation()

        let task: Task<ClauseTaggerModelIdentity, any Error>
        if let inFlight {
            task = inFlight
        } else {
            let validate = self.validate
            task = Task {
                defer { self.inFlight = nil }
                return try await validate()
            }
            inFlight = task
        }
        onJoined()

        do {
            let identity = try await task.value
            try Task.checkCancellation()
            return identity
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            throw error
        }
    }

    public nonisolated static func validateAssets(modelDirectory: URL) throws -> ClauseTaggerModelIdentity {
        do {
            let manifest = try ClauseTaggerManifest.bundled()
            return try validateAssets(modelDirectory: modelDirectory, manifest: manifest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PortableModelPreparationError {
            throw error
        } catch {
            throw PortableModelPreparationError.invalid(
                model: .clauseTagger,
                path: modelDirectory.path,
                detail: error.localizedDescription,
                installCommand: installCommand(for: modelDirectory)
            )
        }
    }

    nonisolated static func validateAssets(
        modelDirectory: URL,
        manifest: ClauseTaggerManifest
    ) throws -> ClauseTaggerModelIdentity {
        do {
            try manifest.validate()
            guard modelDirectory.isFileURL, (modelDirectory.path as NSString).isAbsolutePath else {
                throw PortableModelPreparationError.invalid(
                    model: .clauseTagger,
                    path: modelDirectory.path,
                    detail: "モデルディレクトリは絶対パスの file URL である必要があります",
                    installCommand: installCommand(for: modelDirectory)
                )
            }
            try PortableAssetVerifier.verify(
                model: .clauseTagger,
                files: manifest.members.map {
                    PortableAssetFile(name: $0.name, byteCount: Int64($0.byteCount), sha256: $0.sha256)
                },
                directory: modelDirectory,
                installCommand: installCommand(for: modelDirectory)
            )
            return try manifest.identity()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PortableModelPreparationError {
            throw error
        } catch {
            throw PortableModelPreparationError.invalid(
                model: .clauseTagger,
                path: modelDirectory.path,
                detail: error.localizedDescription,
                installCommand: installCommand(for: modelDirectory)
            )
        }
    }

    private nonisolated static func installCommand(for modelDirectory: URL) -> String {
        "python3 scripts/fetch_clause_tagger.py を実行し、出力されたディレクトリの内容を \(modelDirectory.path) に置く"
    }
}
