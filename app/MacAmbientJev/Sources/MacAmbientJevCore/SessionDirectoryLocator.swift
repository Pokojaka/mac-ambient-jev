import Foundation

public struct SessionDirectoryLocator {
    private let fileManager: FileManager

    public init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    public func resolve(sessionsRoot: URL, sessionID: UUID) throws -> URL {
        let entries = try SessionDirectoryInventory.read(sessionsRoot: sessionsRoot, fileManager: fileManager)
        let matches = entries.filter { entry in
            guard case .success(let manifest) = entry.manifest else { return false }
            return manifest.sessionID == sessionID
        }
        switch matches.count {
        case 0: throw SessionDirectoryLookupError.notFound(sessionID)
        case 1:
            let entry = matches[0]
            let manifest = try entry.manifest.get()
            try SessionFolderName.validate(entry.url.lastPathComponent, manifest: manifest)
            return entry.url
        default:
            throw SessionDirectoryLookupError.multipleMatches(sessionID: sessionID, folders: matches.map(\.url))
        }
    }
}

public enum SessionDirectoryLookupError: Error, LocalizedError, Equatable {
    case notFound(UUID)
    case multipleMatches(sessionID: UUID, folders: [URL])

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "セッションが見つかりません: \(id)"
        case .multipleMatches(let id, let folders):
            "同じセッション ID \(id) を持つフォルダが複数あります: \(folders.map(\.lastPathComponent).joined(separator: ", "))"
        }
    }
}

/// Decode all immediate directories before validating names or scheduling work.
/// An unreadable manifest cannot contribute an identity; a malformed name can.
struct SessionDirectoryInventory {
    let url: URL
    let manifest: Result<SessionManifest, Error>

    static func read(sessionsRoot: URL, fileManager: FileManager) throws -> [Self] {
        // Enumerate existing names, preserving the caller's root URL spelling.
        // Foundation's URL enumeration can rewrite /var to /private/var on macOS.
        let names = try fileManager.contentsOfDirectory(atPath: sessionsRoot.path)
        var entries: [Self] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names.sorted() {
            let url = sessionsRoot.appending(path: name, directoryHint: .isDirectory)
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let manifest: Result<SessionManifest, Error>
            do {
                manifest = .success(try decoder.decode(
                    SessionManifest.self, from: Data(contentsOf: SessionLayout(sessionURL: url).manifestURL)
                ))
            } catch {
                manifest = .failure(error)
            }
            entries.append(Self(url: url, manifest: manifest))
        }
        return entries
    }

    static func duplicateFolders(in entries: [Self]) -> [UUID: [URL]] {
        var folders: [UUID: [URL]] = [:]
        for entry in entries {
            if case .success(let manifest) = entry.manifest {
                folders[manifest.sessionID, default: []].append(entry.url)
            }
        }
        return folders.filter { $0.value.count > 1 }
    }
}
