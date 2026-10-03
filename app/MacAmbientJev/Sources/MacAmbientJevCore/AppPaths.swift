import Foundation

public enum AppPathsError: Error, LocalizedError, Equatable {
    case directoryUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let directory):
            "保存先のシステムフォルダー（\(directory)）を取得できません"
        }
    }
}

public struct AppPaths: Sendable {
    public let applicationSupportURL: URL
    public let cacheURL: URL
    private let sessionsRootOverride: URL?

    public init(
        applicationSupportURL: URL,
        cacheURL: URL,
        sessionsRootOverride: URL?
    ) {
        self.applicationSupportURL = applicationSupportURL
        self.cacheURL = cacheURL
        self.sessionsRootOverride = sessionsRootOverride
    }

    public static func systemDefault(fileManager: FileManager) throws -> AppPaths {
        AppPaths(
            applicationSupportURL: try userDirectory(.applicationSupportDirectory, fileManager: fileManager),
            cacheURL: try userDirectory(.cachesDirectory, fileManager: fileManager),
            sessionsRootOverride: nil
        )
    }

    private static func userDirectory(
        _ directory: FileManager.SearchPathDirectory,
        fileManager: FileManager
    ) throws -> URL {
        guard let url = fileManager.urls(for: directory, in: .userDomainMask).first else {
            throw AppPathsError.directoryUnavailable(String(describing: directory))
        }
        return url
    }

    public var root: URL {
        applicationSupportURL
            .appending(path: "mac-ambient-jev", directoryHint: .isDirectory)
    }

    public var sessionsRoot: URL {
        sessionsRootOverride ?? root.appending(path: "sessions", directoryHint: .isDirectory)
    }

    public var modelsRoot: URL {
        root.appending(path: "models", directoryHint: .isDirectory)
    }

    public var cachesRoot: URL {
        cacheURL
            .appending(path: "mac-ambient-jev", directoryHint: .isDirectory)
    }
}