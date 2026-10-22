import Foundation
import MacAmbientJevCore

enum ClauseTaggerAssetsError: Error, CustomStringConvertible {
    case invalidManifest(String)
    case directoryNotAbsolute(path: String)
    case directoryMissing(path: String)
    case missingFile(name: String, directory: String)
    case notRegularFile(path: String)
    case sizeMismatch(name: String, expected: Int, actual: Int)
    case hashMismatch(name: String, expected: String, actual: String)
    case unreadable(path: String, reason: String)

    static let fetchCommand = "python3 scripts/fetch_clause_tagger.py"

    var description: String {
        switch self {
        case let .invalidManifest(reason):
            return "Invalid clause tagger manifest: \(reason)"
        case let .directoryNotAbsolute(path):
            return "The clause tagger model directory must be an absolute path: \(path)"
        case let .directoryMissing(path):
            return "The clause tagger model directory is not an existing directory: \(path). Run `\(Self.fetchCommand)` and pass the directory it prints."
        case let .missingFile(name, directory):
            return "Clause tagger file \(name) is missing from \(directory). Run `\(Self.fetchCommand)` and pass the directory it prints."
        case let .notRegularFile(path):
            return "Clause tagger path is not a regular file: \(path)"
        case let .sizeMismatch(name, expected, actual):
            return "Clause tagger file \(name) has \(actual) bytes; the manifest pins \(expected). Delete the cache directory and run `\(Self.fetchCommand)` again."
        case let .hashMismatch(name, expected, actual):
            return "Clause tagger file \(name) SHA-256 mismatch: expected \(expected), actual \(actual). Delete the cache directory and run `\(Self.fetchCommand)` again."
        case let .unreadable(path, reason):
            return "Clause tagger file cannot be read: \(path) (\(reason))"
        }
    }
}

/// The pinned ONNX clause tagger release, decoded from the single `clause_tagger_model.json` resource
/// that `scripts/fetch_clause_tagger.py` also reads.
struct ClauseTaggerManifest: Decodable, Equatable {
    struct Release: Decodable, Equatable {
        let repository: String
        let tag: String
        let asset: String
        let byteCount: Int
        let sha256: String
        let directory: String
    }

    struct Model: Decodable, Equatable {
        let id: String
        let revision: String
        let tokenizerSHA256: String
        let encodingRevision: String
        let unitPolicy: String
        let trainingStatus: String
    }

    enum Dimension: Decodable, Equatable {
        case fixed(Int)
        case symbolic(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .fixed(value)
            } else {
                self = .symbolic(try container.decode(String.self))
            }
        }
    }

    struct Tensor: Decodable, Equatable {
        let name: String
        let dtype: String
        let shape: [Dimension]
    }

    struct ONNX: Decodable, Equatable {
        let opset: Int
        let minimumSequenceLength: Int
        let maximumSequenceLength: Int
        let inputs: [Tensor]
        let outputs: [Tensor]
    }

    enum Role: String, Decodable, CaseIterable {
        case model
        case tokenizer
        case export
        case license
    }

    struct Member: Decodable, Equatable {
        let role: Role
        let name: String
        let byteCount: Int
        let sha256: String
    }

    let schemaVersion: Int
    let release: Release
    let model: Model
    let onnx: ONNX
    let members: [Member]

    static let resourceName = "clause_tagger_model"

    static func bundled() throws -> ClauseTaggerManifest {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json", subdirectory: "Resources") else {
            throw ClauseTaggerAssetsError.invalidManifest("resource \(resourceName).json is missing from the module bundle")
        }
        return try parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> ClauseTaggerManifest {
        let manifest: ClauseTaggerManifest
        do {
            manifest = try JSONDecoder().decode(ClauseTaggerManifest.self, from: data)
        } catch {
            throw ClauseTaggerAssetsError.invalidManifest("cannot decode: \(error)")
        }
        try manifest.validate()
        return manifest
    }

    func member(_ role: Role) throws -> Member {
        guard let member = members.first(where: { $0.role == role }) else {
            throw ClauseTaggerAssetsError.invalidManifest("no member for role \(role.rawValue)")
        }
        return member
    }

    func identity() throws -> ClauseTaggerModelIdentity {
        try ClauseTaggerModelIdentity(
            modelID: model.id, revision: model.revision, tokenizerSHA256: model.tokenizerSHA256
        )
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw ClauseTaggerAssetsError.invalidManifest("unsupported schemaVersion \(schemaVersion)")
        }
        guard !release.repository.isEmpty, !release.tag.isEmpty,
              Self.isPlainName(release.asset), Self.isPlainName(release.directory) else {
            throw ClauseTaggerAssetsError.invalidManifest("release needs a repository, a tag, an asset name and a directory name")
        }
        guard release.byteCount > 0, Self.isLowercaseHex(release.sha256, length: 64) else {
            throw ClauseTaggerAssetsError.invalidManifest("release needs a positive byteCount and a 64-digit lowercase hex sha256")
        }
        guard !model.id.isEmpty, Self.isLowercaseHex(model.revision, length: 64),
              Self.isLowercaseHex(model.tokenizerSHA256, length: 64) else {
            throw ClauseTaggerAssetsError.invalidManifest("model needs an id, a 64-digit revision and a 64-digit tokenizerSHA256")
        }
        guard !model.encodingRevision.isEmpty, !model.unitPolicy.isEmpty, !model.trainingStatus.isEmpty else {
            throw ClauseTaggerAssetsError.invalidManifest("model encodingRevision, unitPolicy and trainingStatus must not be empty")
        }
        guard onnx.opset > 0, onnx.minimumSequenceLength >= 1,
              onnx.maximumSequenceLength >= onnx.minimumSequenceLength,
              !onnx.inputs.isEmpty, !onnx.outputs.isEmpty else {
            throw ClauseTaggerAssetsError.invalidManifest("onnx needs a positive opset, a sequence length range and the tensor contract")
        }
        for role in Role.allCases {
            let count = members.filter { $0.role == role }.count
            guard count == 1 else {
                throw ClauseTaggerAssetsError.invalidManifest("role \(role.rawValue) must appear exactly once, found \(count)")
            }
        }
        guard Set(members.map(\.name)).count == members.count else {
            throw ClauseTaggerAssetsError.invalidManifest("member names must be unique")
        }
        for member in members {
            guard Self.isPlainName(member.name) else {
                throw ClauseTaggerAssetsError.invalidManifest("member name must be a plain file name: \(member.name)")
            }
            guard member.byteCount > 0 else {
                throw ClauseTaggerAssetsError.invalidManifest("member \(member.name) byteCount must be positive")
            }
            guard Self.isLowercaseHex(member.sha256, length: 64) else {
                throw ClauseTaggerAssetsError.invalidManifest("member \(member.name) sha256 must be 64 lowercase hex digits")
            }
        }
        guard try member(.tokenizer).sha256 == model.tokenizerSHA256 else {
            throw ClauseTaggerAssetsError.invalidManifest("the tokenizer member sha256 must equal model.tokenizerSHA256")
        }
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    private static func isLowercaseHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// Verified ONNX clause tagger files in a caller-supplied directory.
public struct ClauseTaggerAssets: Sendable {
    public let modelURL: URL
    public let tokenizerURL: URL
    public let identity: ClauseTaggerModelIdentity

    /// Verifies every member the bundled manifest pins in `modelDirectory` (regular file, size, streamed
    /// SHA-256). Any missing, wrong-size or corrupt file throws; nothing is repaired or downloaded.
    public init(modelDirectory: URL) throws {
        try self.init(modelDirectory: modelDirectory, manifest: ClauseTaggerManifest.bundled())
    }

    init(modelDirectory: URL, manifest: ClauseTaggerManifest) throws {
        try manifest.validate()
        let path = modelDirectory.path
        guard modelDirectory.isFileURL, (path as NSString).isAbsolutePath else {
            throw ClauseTaggerAssetsError.directoryNotAbsolute(path: path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClauseTaggerAssetsError.directoryMissing(path: path)
        }
        for member in manifest.members {
            try Self.verify(member, at: modelDirectory.appendingPathComponent(member.name, isDirectory: false), directory: modelDirectory)
        }
        self.modelURL = modelDirectory.appendingPathComponent(try manifest.member(.model).name, isDirectory: false)
        self.tokenizerURL = modelDirectory.appendingPathComponent(try manifest.member(.tokenizer).name, isDirectory: false)
        self.identity = try manifest.identity()
    }

    public static func pinnedIdentity() throws -> ClauseTaggerModelIdentity {
        try ClauseTaggerManifest.bundled().identity()
    }

    private static func verify(_ member: ClauseTaggerManifest.Member, at url: URL, directory: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            throw ClauseTaggerAssetsError.missingFile(name: member.name, directory: directory.path)
        } catch {
            throw ClauseTaggerAssetsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ClauseTaggerAssetsError.notRegularFile(path: url.path)
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard size == member.byteCount else {
            throw ClauseTaggerAssetsError.sizeMismatch(name: member.name, expected: member.byteCount, actual: size)
        }
        let actual: String
        do {
            actual = try FileSHA256.hexDigest(ofFileAt: url)
        } catch {
            throw ClauseTaggerAssetsError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard actual == member.sha256 else {
            throw ClauseTaggerAssetsError.hashMismatch(name: member.name, expected: member.sha256, actual: actual)
        }
    }
}
