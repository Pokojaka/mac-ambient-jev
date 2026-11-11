import Foundation
import MacAmbientJevCore

/// Fetches the configured ASR files that are missing or have the wrong size. Files with the pinned size are
/// not hashed here; `PortableModelPreparationService` verifies every file before loading.
public enum PortableModelDownloads {
    public static func fetchMissing(
        configuration: PortableProcessingConfiguration,
        transport: any ModelDownloadTransport,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let directory = configuration.qwen3ModelDirectory
        let entry = configuration.qwen3Size.manifestEntry
        guard !isPresent(entry, in: directory) else { return }
        do {
            try SessionFileAccess.createDirectory(directory, relativeTo: directory)
        } catch {
            throw ModelDownloadError.diskWrite(file: directory.path, reason: error.localizedDescription)
        }
        try await ModelFetcher.fetch(into: directory, entry: entry, transport: transport, progress: onProgress)
    }

    /// Every file is a regular file of the pinned size.
    private static func isPresent(_ entry: ModelManifestEntry, in directory: URL) -> Bool {
        entry.files.allSatisfy { file in
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            return (try? SessionFileAccess.fileSize(url, relativeTo: directory)).map { Int64($0) == file.byteCount } ?? false
        }
    }
}
