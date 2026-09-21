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
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )

        let fileExtension = sourceURL.pathExtension
        let name = fileExtension.isEmpty ? "original" : "original.\(fileExtension)"
        let destinationURL = audioDirectory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw AudioImporterError.destinationAlreadyExists
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return ImportedAudio(originalURL: destinationURL)
    }
}
