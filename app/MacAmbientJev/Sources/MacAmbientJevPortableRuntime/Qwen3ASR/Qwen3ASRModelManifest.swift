import Foundation
import MacAmbientJevCore

extension ASRModelSize {
    public var hiddenSize: Int { manifest.hiddenSize }
    public var repository: String { manifest.repository }
    public var commit: String { manifest.commit }
    public var files: [Qwen3ASRModelFile] { manifest.files }

    var encoderFilename: String { manifest.file(for: .encoder).name }
    var decoderInitFilename: String { manifest.file(for: .decoderInit).name }
    var decoderStepFilename: String { manifest.file(for: .decoderStep).name }
    var decoderWeightsFilename: String { manifest.file(for: .decoderWeights).name }
    var embeddingFilename: String { manifest.file(for: .embedTokens).name }
    var tokenizerFilename: String { manifest.file(for: .tokenizer).name }

    private var manifest: Qwen3ASRModelManifestEntry {
        Self.manifests[rawValue]!
    }

    private static let manifests: [String: Qwen3ASRModelManifestEntry] = {
        guard let url = Bundle.module.url(
            forResource: "qwen3_asr_models",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            fatalError("Qwen3-ASR の同梱モデルマニフェスト Resources/qwen3_asr_models.json が見つかりません。パッケージ設定の不備です。")
        }

        do {
            let data = try Data(contentsOf: url)
            return try decodeManifests(data)
        } catch {
            fatalError("Qwen3-ASR の同梱モデルマニフェスト Resources/qwen3_asr_models.json が不正です。パッケージ設定の不備です: \(error.localizedDescription)")
        }
    }()

    internal static func decodeManifests(_ data: Data) throws -> [String: Qwen3ASRModelManifestEntry] {
        let manifests = try JSONDecoder().decode([String: Qwen3ASRModelManifestEntry].self, from: data)
        try validate(manifests)
        return manifests
    }

    private static func validate(_ manifests: [String: Qwen3ASRModelManifestEntry]) throws {
        let expectedSizes: Set<String> = [ASRModelSize.small.rawValue, ASRModelSize.large.rawValue]
        guard manifests.count == 2, Set(manifests.keys) == expectedSizes else {
            throw Qwen3ASRModelError.invalid("マニフェストには 0.6b と 1.7b のモデル情報だけを定義してください。")
        }

        for size in ASRModelSize.allCases {
            guard let entry = manifests[size.rawValue] else {
                throw Qwen3ASRModelError.invalid("マニフェストに \(size.rawValue) のモデル情報がありません。")
            }
            guard entry.hiddenSize > 0 else {
                throw Qwen3ASRModelError.invalid("\(size.rawValue) の hiddenSize は正の値でなければなりません。")
            }
            guard !entry.repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Qwen3ASRModelError.invalid("\(size.rawValue) の repository は空にできません。")
            }
            guard !entry.commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Qwen3ASRModelError.invalid("\(size.rawValue) の commit は空にできません。")
            }
            guard entry.files.count == 6 else {
                throw Qwen3ASRModelError.invalid("\(size.rawValue) のファイル一覧は 6 件でなければなりません。")
            }

            var names = Set<String>()
            for file in entry.files {
                guard file.byteCount > 0 else {
                    throw Qwen3ASRModelError.invalid("\(size.rawValue) のファイル \(file.name) の byteCount は正の値でなければなりません。")
                }
                guard !file.name.isEmpty,
                      file.name != ".",
                      file.name != "..",
                      !file.name.contains("/"),
                      !file.name.contains("\\"),
                      !file.name.utf8.contains(0)
                else {
                    throw Qwen3ASRModelError.invalid("\(size.rawValue) のファイル名は空でない単純な basename でなければなりません: \(file.name)")
                }
                guard names.insert(file.name).inserted else {
                    throw Qwen3ASRModelError.invalid("\(size.rawValue) のファイル名が重複しています: \(file.name)")
                }
            }
        }
    }

    public func validate(directory: URL) throws {
        try validateModelDirectory(directory)
    }

    func validateModelDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw Qwen3ASRModelError.invalid("モデルディレクトリは file URL でなければなりません: \(directory.absoluteString)")
        }

        let fileManager = FileManager.default
        let directoryAttributes = try Self.attributes(at: directory)
        guard let directoryType = directoryAttributes[.type] as? FileAttributeType,
              directoryType == .typeDirectory
        else {
            throw Qwen3ASRModelError.invalid("モデルディレクトリのパスがディレクトリではありません: \(directory.path)")
        }
        guard fileManager.isReadableFile(atPath: directory.path) else {
            throw Qwen3ASRModelError.invalid("モデルディレクトリを読み取れません: \(directory.path)")
        }

        for file in files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            let attributes = try Self.attributes(at: url)
            guard let fileType = attributes[.type] as? FileAttributeType,
                  fileType == .typeRegular
            else {
                throw Qwen3ASRModelError.invalid("モデルファイルが通常ファイルではありません: \(url.path)")
            }
            guard fileManager.isReadableFile(atPath: url.path) else {
                throw Qwen3ASRModelError.invalid("モデルファイルを読み取れません: \(url.path)")
            }
            guard let size = attributes[.size] as? NSNumber else {
                throw Qwen3ASRModelError.invalid("モデルファイルのサイズ情報を取得できません: \(url.path) (期待値: \(file.byteCount) bytes, 実際: 不明)")
            }

            let actualByteCount = size.int64Value
            guard actualByteCount == file.byteCount else {
                throw Qwen3ASRModelError.invalid("モデルファイルのサイズが一致しません: \(url.path) (期待値: \(file.byteCount) bytes, 実際: \(actualByteCount) bytes)")
            }
        }
    }

    private static func attributes(at url: URL) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw Qwen3ASRModelError.invalid("ファイル情報を取得できません: \(url.path): \(error.localizedDescription)")
        }
    }
}

public enum Qwen3ASRModelFileRole: String, Decodable, CaseIterable, Sendable {
    case encoder
    case decoderInit = "decoder_init"
    case decoderStep = "decoder_step"
    case decoderWeights = "decoder_weights"
    case embedTokens = "embed_tokens"
    case tokenizer
}

public struct Qwen3ASRModelFile: Decodable, Sendable, Equatable {
    public let name: String
    public let role: Qwen3ASRModelFileRole
    public let byteCount: Int64
    public let sha256: String
}

struct Qwen3ASRModelManifestEntry: Decodable {
    let hiddenSize: Int
    let repository: String
    let commit: String
    let files: [Qwen3ASRModelFile]
    private let filesByRole: [Qwen3ASRModelFileRole: Qwen3ASRModelFile]

    func file(for role: Qwen3ASRModelFileRole) -> Qwen3ASRModelFile {
        filesByRole[role]!
    }

    private enum CodingKeys: String, CodingKey {
        case hiddenSize
        case repository
        case commit
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        repository = try container.decode(String.self, forKey: .repository)
        commit = try container.decode(String.self, forKey: .commit)
        let decodedFiles = try container.decode([Qwen3ASRModelFile].self, forKey: .files)

        var roles = Set<Qwen3ASRModelFileRole>()
        for file in decodedFiles {
            guard roles.insert(file.role).inserted else {
                throw Qwen3ASRModelError.invalid("ファイル role が重複しています: \(file.role.rawValue)")
            }
        }
        for role in Qwen3ASRModelFileRole.allCases where !roles.contains(role) {
            throw Qwen3ASRModelError.invalid("ファイル role が不足しています: \(role.rawValue)")
        }

        files = decodedFiles
        filesByRole = Dictionary(uniqueKeysWithValues: decodedFiles.map { ($0.role, $0) })
    }
}

enum Qwen3ASRModelError: Error, LocalizedError, Sendable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message):
            message
        }
    }
}
