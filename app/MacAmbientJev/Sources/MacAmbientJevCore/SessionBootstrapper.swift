import Foundation

public struct SessionBootstrapper {
    private let fileManager: FileManager

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    @discardableResult
    public func createSession(
        paths: AppPaths,
        sessionID: UUID,
        source: SessionSource,
        createdAt: Date,
        timeZone: TimeZone
    ) throws -> URL {
        let sessionURL = paths.sessionsRoot.appending(
            path: try SessionFolderName.make(
                createdAt: createdAt, sessionID: sessionID, source: source, timeZone: timeZone
            ),
            directoryHint: .isDirectory
        )
        let manifest = SessionManifest(
            sessionID: sessionID,
            createdAt: createdAt,
            source: source
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        try SessionFileAccess.createDirectory(paths.sessionsRoot, relativeTo: paths.sessionsRoot)
        try SessionFileAccess.createExclusiveDirectory(sessionURL, relativeTo: paths.sessionsRoot)
        try SessionFileAccess.writeAtomically(
            encoder.encode(manifest), to: sessionURL.appending(path: "session.json"), relativeTo: sessionURL
        )
        try SessionAudioStorageStore(layout: SessionLayout(sessionURL: sessionURL))
            .save(.initial(for: source))
        _ = try SessionWriter(sessionURL: sessionURL)

        return sessionURL
    }
}