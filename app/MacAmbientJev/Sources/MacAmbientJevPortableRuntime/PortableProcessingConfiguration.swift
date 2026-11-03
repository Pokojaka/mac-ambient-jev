import Foundation
import MacAmbientJevCore

public enum PortableProcessingConfigurationError: Error, LocalizedError, Equatable {
    case invalidEnvironment(key: String, reason: String)
    case invalidThreads(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEnvironment(key, reason):
            return "環境変数 \(key) が不正です: \(reason)"
        case let .invalidThreads(reason):
            return "--threads が不正です: \(reason)"
        }
    }
}

/// The typed inputs of one portable processing run. Resolving them reads no model; `PortableSessionEngineBundle` loads.
public struct PortableProcessingConfiguration: Sendable, Equatable {
    public static let sileroModelKey = "MAC_AMBIENT_JEV_SILERO_MODEL"
    public static let qwen3DirectoryKey = "QWEN3_ASR_ONNX_MODEL_DIRECTORY"
    public static let qwen3SizeKey = "QWEN3_ASR_ONNX_MODEL_SIZE"
    public static let diarizationDirectoryKey = "MAC_AMBIENT_JEV_DIARIZATION_ONNX_MODEL_DIRECTORY"
    public static let clauseTaggerDirectoryKey = "MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY"
    public static let maximumThreads = 4

    public let sileroModelURL: URL
    public let qwen3ModelDirectory: URL
    public let qwen3Size: ASRModelSize
    public let diarizationModelDirectory: URL
    /// Non-nil exactly when decisions are requested.
    public let clauseTaggerModelDirectory: URL?
    /// Threads for ASR, diarization and the clause tagger. The VAD always uses one.
    public let threads: Int

    public init(
        sileroModelURL: URL,
        qwen3ModelDirectory: URL,
        qwen3Size: ASRModelSize,
        diarizationModelDirectory: URL,
        clauseTaggerModelDirectory: URL?,
        threads: Int
    ) {
        self.sileroModelURL = sileroModelURL
        self.qwen3ModelDirectory = qwen3ModelDirectory
        self.qwen3Size = qwen3Size
        self.diarizationModelDirectory = diarizationModelDirectory
        self.clauseTaggerModelDirectory = clauseTaggerModelDirectory
        self.threads = threads
    }

    /// `threads` is the `--threads` value; `nil` means the flag was absent. The clause tagger variable is read only when
    /// `withDecisions` is true. Each path must be absolute and name an existing file (Silero) or directory.
    public static func resolve(
        environment: [String: String],
        threads: Int?,
        logicalCPUCount: Int,
        withDecisions: Bool
    ) throws -> PortableProcessingConfiguration {
        let threads = try validatedThreads(threads, logicalCPUCount: logicalCPUCount)
        let sileroModelURL = try existingPath(environment, key: sileroModelKey, isDirectory: false)
        let qwen3ModelDirectory = try existingPath(environment, key: qwen3DirectoryKey, isDirectory: true)
        let qwen3Size = try qwen3Size(environment)
        let diarizationModelDirectory = try existingPath(environment, key: diarizationDirectoryKey, isDirectory: true)
        let clauseTaggerModelDirectory = withDecisions
            ? try existingPath(environment, key: clauseTaggerDirectoryKey, isDirectory: true)
            : nil
        return PortableProcessingConfiguration(
            sileroModelURL: sileroModelURL,
            qwen3ModelDirectory: qwen3ModelDirectory,
            qwen3Size: qwen3Size,
            diarizationModelDirectory: diarizationModelDirectory,
            clauseTaggerModelDirectory: clauseTaggerModelDirectory,
            threads: threads
        )
    }

    static func validatedThreads(_ threads: Int?, logicalCPUCount: Int) throws -> Int {
        guard let threads else {
            throw PortableProcessingConfigurationError.invalidThreads(reason: "必須です")
        }
        let upperBound = min(maximumThreads, logicalCPUCount)
        guard threads >= 1, threads <= upperBound else {
            throw PortableProcessingConfigurationError.invalidThreads(
                reason: "1 から \(upperBound) の整数を指定してください（指定: \(threads)）"
            )
        }
        return threads
    }

    private static func qwen3Size(_ environment: [String: String]) throws -> ASRModelSize {
        guard let value = environment[qwen3SizeKey] else {
            throw PortableProcessingConfigurationError.invalidEnvironment(key: qwen3SizeKey, reason: "必須です")
        }
        guard let size = ASRModelSize(rawValue: value) else {
            throw PortableProcessingConfigurationError.invalidEnvironment(
                key: qwen3SizeKey, reason: "0.6b または 1.7b を指定してください（指定: \(value)）"
            )
        }
        return size
    }

    private static func existingPath(_ environment: [String: String], key: String, isDirectory: Bool) throws -> URL {
        guard let path = environment[key] else {
            throw PortableProcessingConfigurationError.invalidEnvironment(key: key, reason: "必須です")
        }
        guard !path.isEmpty else {
            throw PortableProcessingConfigurationError.invalidEnvironment(key: key, reason: "空にできません")
        }
        guard (path as NSString).isAbsolutePath else {
            throw PortableProcessingConfigurationError.invalidEnvironment(key: key, reason: "絶対パスを指定してください（指定: \(path)）")
        }
        var isDirectoryFlag: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectoryFlag) else {
            throw PortableProcessingConfigurationError.invalidEnvironment(key: key, reason: "存在しません: \(path)")
        }
        guard isDirectoryFlag.boolValue == isDirectory else {
            throw PortableProcessingConfigurationError.invalidEnvironment(
                key: key, reason: isDirectory ? "ディレクトリではありません: \(path)" : "ファイルではありません: \(path)"
            )
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }
}
