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

        let resolvedSource = sourceURL.resolvingSymlinksInPath()
        try SessionFileAccess.copy(resolvedSource, relativeTo: resolvedSource.deletingLastPathComponent(), to: destinationURL, relativeTo: sessionURL)
        return ImportedAudio(originalURL: destinationURL)
    }
}
