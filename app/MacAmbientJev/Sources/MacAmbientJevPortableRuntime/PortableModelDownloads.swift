import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization

/// One model's pinned entries and the directory they live in.
struct PortableModelDownload: Sendable, Equatable {
    let model: PortableModelKind
    let directory: URL
    let entries: [ModelManifestEntry]
}

/// Fetches the ASR files of the configured size and the diarization files that are missing or have the
/// wrong size. Files with the pinned size are not hashed here; `PortableModelPreparationService` verifies
/// every file before loading.
public enum PortableModelDownloads {
    public static func fetchMissing(
        configuration: PortableProcessingConfiguration,
        transport: any ModelDownloadTransport,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await fetchMissing(try plan(for: configuration), transport: transport, onProgress: onProgress)
    }

    static func plan(for configuration: PortableProcessingConfiguration) throws -> [PortableModelDownload] {
        [
            PortableModelDownload(
                model: .asr, directory: configuration.qwen3ModelDirectory,
                entries: [configuration.qwen3Size.manifestEntry]
            ),
            PortableModelDownload(
                model: .diarization, directory: configuration.diarizationModelDirectory,
                entries: try Community1Assets.manifestEntries()
            ),
        ]
    }

    static func fetchMissing(
        _ downloads: [PortableModelDownload],
        transport: any ModelDownloadTransport,
        onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        let missing = downloads.flatMap { download in
            download.entries.filter { !isPresent($0, in: download.directory) }.map { (download.directory, $0) }
        }
        let total = missing.reduce(Int64(0)) { sum, item in
            sum + item.1.files.reduce(Int64(0)) { $0 + $1.byteCount }
        }
        guard total > 0 else { return }
        onProgress(ModelDownloadProgress(bytesDone: 0, bytesTotal: total))
        var offset: Int64 = 0
        for (directory, entry) in missing {
            do {
                try SessionFileAccess.createDirectory(directory, relativeTo: directory)
            } catch {
                throw ModelDownloadError.diskWrite(file: directory.path, reason: error.localizedDescription)
            }
            let base = offset
            try await ModelFetcher.fetch(into: directory, entry: entry, transport: transport) {
                onProgress(ModelDownloadProgress(bytesDone: base + $0.bytesDone, bytesTotal: total))
            }
            offset += entry.files.reduce(Int64(0)) { $0 + $1.byteCount }
        }
    }

    /// Every file is a regular file of the pinned size.
    private static func isPresent(_ entry: ModelManifestEntry, in directory: URL) -> Bool {
        entry.files.allSatisfy { file in
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            return (try? SessionFileAccess.fileSize(url, relativeTo: directory)).map { Int64($0) == file.byteCount } ?? false
        }
    }
}
