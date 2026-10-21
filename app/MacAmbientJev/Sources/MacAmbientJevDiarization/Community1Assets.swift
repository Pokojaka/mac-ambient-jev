import Foundation
import MacAmbientJevCore

enum Community1AssetsError: Error, CustomStringConvertible {
    case invalidManifest(String)
    case missingFile(name: String, directory: String)
    case notRegularFile(path: String)
    case sizeMismatch(name: String, expected: Int, actual: Int)
    case hashMismatch(name: String, expected: String, actual: String)
    case unreadable(path: String, reason: String)

    static let fetchCommand = "python3 scripts/fetch_community1_diarization.py"

    var description: String {
        switch self {
        case let .invalidManifest(reason):
            return "Invalid Community-1 diarization manifest: \(reason)"
        case let .missingFile(name, directory):
            return "Community-1 model file \(name) is missing from \(directory). Run `\(Self.fetchCommand)` and pass the directory it prints."
        case let .notRegularFile(path):
            return "Community-1 model path is not a regular file: \(path)"
        case let .sizeMismatch(name, expected, actual):
            return "Community-1 model file \(name) has \(actual) bytes; the manifest pins \(expected). Run `\(Self.fetchCommand)` again."
        case let .hashMismatch(name, expected, actual):
            return "Community-1 model file \(name) SHA-256 mismatch: expected \(expected), actual \(actual). Delete the file and run `\(Self.fetchCommand)` again."
        case let .unreadable(path, reason):
            return "Community-1 model file cannot be read: \(path) (\(reason))"
        }
    }
}

/// The pinned Community-1 model files and the PLDA coordinate orientation, decoded from the single
/// `community1_diarization_models.json` resource that `scripts/fetch_community1_diarization.py` also reads.
struct Community1Manifest: Decodable, Equatable {
    enum Role: String, Decodable, CaseIterable {
        case segmentation
        case embedding
        case plda
        case xvector
    }

    struct Source: Decodable, Equatable {
        let repository: String
        let revision: String
    }

    struct File: Decodable, Equatable {
        let role: Role
        let source: String
        let name: String
        let byteCount: Int
        let sha256: String
    }

    let sources: [String: Source]
    let files: [File]
    let coordinateSigns: [Int]

    static let resourceName = "community1_diarization_models"

    static func bundled() throws -> Community1Manifest {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json", subdirectory: "Resources") else {
            throw Community1AssetsError.invalidManifest("resource \(resourceName).json is missing from the module bundle")
        }
        return try parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> Community1Manifest {
        let manifest: Community1Manifest
        do {
            manifest = try JSONDecoder().decode(Community1Manifest.self, from: data)
        } catch {
            throw Community1AssetsError.invalidManifest("cannot decode: \(error)")
        }
        try manifest.validate()
        return manifest
    }

    func file(_ role: Role) throws -> File {
        guard let file = files.first(where: { $0.role == role }) else {
            throw Community1AssetsError.invalidManifest("no file for role \(role.rawValue)")
        }
        return file
    }

    func validate() throws {
        for role in Role.allCases {
            let count = files.filter { $0.role == role }.count
            guard count == 1 else {
                throw Community1AssetsError.invalidManifest("role \(role.rawValue) must appear exactly once, found \(count)")
            }
        }
        guard Set(files.map(\.name)).count == files.count else {
            throw Community1AssetsError.invalidManifest("file names must be unique")
        }
        for (id, source) in sources {
            guard !source.repository.isEmpty, Self.isLowercaseHex(source.revision, length: 40) else {
                throw Community1AssetsError.invalidManifest("source \(id) needs a repository and a 40-digit lowercase hex revision")
            }
        }
        for file in files {
            guard sources[file.source] != nil else {
                throw Community1AssetsError.invalidManifest("file \(file.name) names unknown source \(file.source)")
            }
            guard !file.name.isEmpty, file.name != ".", file.name != "..",
                  !file.name.contains("/"), !file.name.contains("\\") else {
                throw Community1AssetsError.invalidManifest("file name must be a plain file name: \(file.name)")
            }
            guard file.byteCount > 0 else {
                throw Community1AssetsError.invalidManifest("file \(file.name) byteCount must be positive")
            }
            guard Self.isLowercaseHex(file.sha256, length: 64) else {
                throw Community1AssetsError.invalidManifest("file \(file.name) sha256 must be 64 lowercase hex digits")
            }
        }
        guard coordinateSigns.count == Community1Profile.rhoDimensions,
              coordinateSigns.allSatisfy({ $0 == -1 || $0 == 1 }) else {
            throw Community1AssetsError.invalidManifest(
                "coordinateSigns must hold \(Community1Profile.rhoDimensions) values of -1 or 1"
            )
        }
    }

    private static func isLowercaseHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// Verified Community-1 model files in a caller-supplied directory, plus the decoded PLDA transform.
struct Community1Assets {
    let segmentationURL: URL
    let embeddingURL: URL
    let plda: Community1PLDA

    /// Checks size and SHA-256 of the four pinned files, then decodes the PLDA JSON files with the
    /// manifest's coordinate signs. Any missing, wrong-size or corrupt file throws; nothing is repaired.
    init(modelDirectory: URL, manifest: Community1Manifest) throws {
        try manifest.validate()
        var urls: [Community1Manifest.Role: URL] = [:]
        for file in manifest.files {
            let url = modelDirectory.appendingPathComponent(file.name, isDirectory: false)
            try Self.verify(file, at: url, directory: modelDirectory)
            urls[file.role] = url
        }
        guard let segmentationURL = urls[.segmentation], let embeddingURL = urls[.embedding],
              let pldaURL = urls[.plda], let xvectorURL = urls[.xvector] else {
            throw Community1AssetsError.invalidManifest("manifest does not cover all roles")
        }
        self.segmentationURL = segmentationURL
        self.embeddingURL = embeddingURL
        self.plda = try Community1PLDA(
            pldaData: try Self.read(pldaURL),
            xvectorData: try Self.read(xvectorURL),
            coordinateSigns: manifest.coordinateSigns
        )
    }

    private static func verify(_ file: Community1Manifest.File, at url: URL, directory: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw Community1AssetsError.missingFile(name: file.name, directory: directory.path)
        } catch {
            throw Community1AssetsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Community1AssetsError.notRegularFile(path: url.path)
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard size == file.byteCount else {
            throw Community1AssetsError.sizeMismatch(name: file.name, expected: file.byteCount, actual: size)
        }
        let actual: String
        do {
            actual = try FileSHA256.hexDigest(ofFileAt: url)
        } catch {
            throw Community1AssetsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard actual == file.sha256 else {
            throw Community1AssetsError.hashMismatch(name: file.name, expected: file.sha256, actual: actual)
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Community1AssetsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
    }
}
