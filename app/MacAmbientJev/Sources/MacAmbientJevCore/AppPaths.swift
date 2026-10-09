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

public enum SessionsRootPolicy {
    public enum Error: Swift.Error, LocalizedError, Equatable {
        case unsafeRoot

        public var errorDescription: String? {
            "Sessions root must be a real directory, not a symlink, outside protected application data and cache roots."
        }
    }

    public static func validated(
        _ root: URL,
        protectedRoots: [URL],
        fileManager: FileManager
    ) throws -> URL {
        func resolve(_ url: URL) -> URL {
            var ancestor = url.standardizedFileURL
            var missing: [String] = []
            while !fileManager.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                missing.append(ancestor.lastPathComponent)
                ancestor.deleteLastPathComponent()
            }
            var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
            for component in missing.reversed() { resolved.appendPathComponent(component) }
            return resolved.standardizedFileURL
        }
        let selected = root.standardizedFileURL
        let resolvedSelected = resolve(selected)
        for protected in protectedRoots {
            let a = resolvedSelected.pathComponents.map { $0.lowercased() }
            let b = resolve(protected).pathComponents.map { $0.lowercased() }
            guard !a.starts(with: b), !b.starts(with: a) else { throw Error.unsafeRoot }
        }
        do { _ = try SessionFileAccess.isDirectoryIfPresent(selected, relativeTo: selected) }
        catch { throw Error.unsafeRoot }
        return selected
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
    public var protectedSessionsRoots: [URL] {
        let container = applicationSupportURL.deletingLastPathComponent()
            .appending(path: "Containers/app.mac-ambient-jev/Data/Library")
        return [
            root,
            cachesRoot,
            container.appending(path: "Application Support/mac-ambient-jev"),
            container.appending(path: "Caches/mac-ambient-jev")
        ]
    }
}