import Foundation

public struct AppPaths: Sendable {
    public let applicationSupportURL: URL
    public let cacheURL: URL

    public init(applicationSupportURL: URL, cacheURL: URL) {
        self.applicationSupportURL = applicationSupportURL
        self.cacheURL = cacheURL
    }

    public var root: URL {
        applicationSupportURL
            .appending(path: "mac-ambient-jev", directoryHint: .isDirectory)
    }

    public var sessionsRoot: URL {
        root.appending(path: "sessions", directoryHint: .isDirectory)
    }

    public var modelsRoot: URL {
        root.appending(path: "models", directoryHint: .isDirectory)
    }

    public var configRoot: URL {
        root.appending(path: "config", directoryHint: .isDirectory)
    }

    public var cachesRoot: URL {
        cacheURL
            .appending(path: "mac-ambient-jev", directoryHint: .isDirectory)
    }
}
