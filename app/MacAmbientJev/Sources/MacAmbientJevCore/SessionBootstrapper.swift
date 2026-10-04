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

        guard !fileManager.fileExists(atPath: sessionURL.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: sessionURL.path])
        }
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