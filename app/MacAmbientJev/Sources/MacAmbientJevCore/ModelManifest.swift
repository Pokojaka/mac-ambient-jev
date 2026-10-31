import Foundation

/// One pinned file of a downloadable model. `name` is a relative path under the model directory
/// and under the repository at `ModelManifestEntry.commit`.
public struct ModelManifestFile: Codable, Equatable, Sendable {
    public let name: String
    public let role: String
    public let byteCount: Int64
    public let sha256: String

    public init(name: String, role: String, byteCount: Int64, sha256: String) {
        self.name = name
        self.role = role
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// A model repository pinned to one commit, with every file it needs.
public struct ModelManifestEntry: Codable, Equatable, Sendable {
    public let repository: String
    public let commit: String
    public let files: [ModelManifestFile]

    public init(repository: String, commit: String, files: [ModelManifestFile]) {
        self.repository = repository
        self.commit = commit
        self.files = files
    }
}

public enum ModelManifestError: Error, Equatable, Sendable {
    case invalid(String)
}

public enum ModelManifest {
    /// Decodes a manifest keyed by model id and validates every entry.
    public static func decode(_ data: Data) throws -> [String: ModelManifestEntry] {
        let entries = try JSONDecoder().decode([String: ModelManifestEntry].self, from: data)
        for (key, entry) in entries {
            try validate(entry, key: key)
        }
        return entries
    }

    public static func validate(_ entry: ModelManifestEntry, key: String) throws {
        guard !entry.repository.isEmpty, !entry.repository.contains(where: \.isWhitespace) else {
            throw ModelManifestError.invalid("\(key): repository が不正です: \(entry.repository)")
        }
        guard isLowercaseHex(entry.commit, length: 40) else {
            throw ModelManifestError.invalid("\(key): commit は 40 桁の小文字 16 進数でなければなりません: \(entry.commit)")
        }
        guard !entry.files.isEmpty else {
            throw ModelManifestError.invalid("\(key): ファイル一覧が空です")
        }
        var names = Set<String>()
        for file in entry.files {
            guard isRelativePath(file.name) else {
                throw ModelManifestError.invalid("\(key): ファイル名は '..' や絶対パスを含まない相対パスでなければなりません: \(file.name)")
            }
            guard names.insert(file.name).inserted else {
                throw ModelManifestError.invalid("\(key): ファイル名が重複しています: \(file.name)")
            }
            guard file.byteCount > 0 else {
                throw ModelManifestError.invalid("\(key): \(file.name) の byteCount は正の値でなければなりません")
            }
            guard isLowercaseHex(file.sha256, length: 64) else {
                throw ModelManifestError.invalid("\(key): \(file.name) の sha256 は 64 桁の小文字 16 進数でなければなりません")
            }
        }
    }

    private static func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func isRelativePath(_ name: String) -> Bool {
        guard !name.isEmpty, !name.utf8.contains(0), !name.contains("\\"), !name.hasPrefix("/") else {
            return false
        }
        return name.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public enum ModelVerificationError: Error, Equatable, Sendable {
    case missing(file: String)
    case notRegularFile(file: String)
    case wrongSize(file: String, expected: Int64, actual: Int64)
    case wrongHash(file: String, expected: String, actual: String)
    case unreadable(file: String, reason: String)
}

public enum ModelVerifier {
    /// Verifies every manifest file under `directory`: a regular file (no symlink, also in the
    /// parent directories), the byte count, then the streamed SHA-256. Throws on the first failure.
    public static func verify(directory: URL, entry: ModelManifestEntry) throws {
        for file in entry.files {
            try verify(file, in: directory)
        }
    }

    /// Verifies one manifest file the same way, for callers that fetch file by file.
    public static func verify(_ file: ModelManifestFile, in directory: URL) throws {
        let fileManager = FileManager.default
        var current = directory
        let components = file.name.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current = current.appending(path: component, directoryHint: .inferFromPath)
            let isFile = index == components.count - 1
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: current.path)
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                    throw ModelVerificationError.missing(file: file.name)
                }
                throw ModelVerificationError.unreadable(file: file.name, reason: error.localizedDescription)
            }
            let type = attributes[.type] as? FileAttributeType
            guard type == (isFile ? .typeRegular : .typeDirectory) else {
                throw ModelVerificationError.notRegularFile(file: file.name)
            }
            if isFile {
                let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actualSize == file.byteCount else {
                    throw ModelVerificationError.wrongSize(
                        file: file.name, expected: file.byteCount, actual: actualSize
                    )
                }
            }
        }
        let digest: String
        do {
            digest = try FileSHA256.hexDigest(ofFileAt: current)
        } catch {
            throw ModelVerificationError.unreadable(file: file.name, reason: error.localizedDescription)
        }
        guard digest == file.sha256 else {
            throw ModelVerificationError.wrongHash(file: file.name, expected: file.sha256, actual: digest)
        }
    }
}
