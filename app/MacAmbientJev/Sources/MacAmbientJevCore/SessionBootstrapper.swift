import Foundation

public struct SessionBootstrapper {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func createSession(
        paths: AppPaths,
        sessionID: UUID,
        sourceKind: SessionSourceKind,
        originalFilename: String? = nil,
        captureSource: CaptureSource = .microphone,
        createdAt: Date = Date()
    ) throws -> URL {
        let sessionURL = paths.sessionsRoot.appending(
            path: sessionID.uuidString,
            directoryHint: .isDirectory
        )
        let manifest = SessionManifest(
            sessionID: sessionID,
            createdAt: createdAt,
            sourceKind: sourceKind,
            originalFilename: originalFilename,
            captureSource: captureSource
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        try fileManager.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(manifest).write(
            to: sessionURL.appending(path: "session.json"),
            options: .atomic
        )
        _ = try SessionWriter(sessionURL: sessionURL)

        return sessionURL
    }
}