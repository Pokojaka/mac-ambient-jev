import Foundation

public struct ImportedAudio: Sendable, Equatable {
    public let originalURL: URL
}

public enum AudioImporterError: Error, Equatable {
    case destinationAlreadyExists
}

public struct AudioImporter: Sendable {
    public init() {}

    public func importFile(_ sourceURL: URL, into sessionURL: URL) throws -> ImportedAudio {
        let audioDirectory = sessionURL.appending(path: "audio", directoryHint: .isDirectory)
        try SessionFileAccess.createDirectory(audioDirectory, relativeTo: sessionURL)

        let fileExtension = sourceURL.pathExtension
        let name = fileExtension.isEmpty ? "original" : "original.\(fileExtension)"
        let destinationURL = audioDirectory.appending(path: name)
        guard try SessionFileAccess.isDirectoryIfPresent(destinationURL, relativeTo: sessionURL) == nil else {
            throw AudioImporterError.destinationAlreadyExists
        }

        // A sandboxed app is granted only the chosen file, not its folder, so the source
        // is opened directly instead of through a pinned parent directory.
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try SessionFileAccess.openHandle(destinationURL, relativeTo: sessionURL, writable: true, create: true, exclusive: true)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        return ImportedAudio(originalURL: destinationURL)
    }
}
