import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPipeline
import MacAmbientJevPortableRuntime

internal struct TranscribeFileArguments: Sendable {
    let inputURL: URL
    let sileroModelURL: URL
    let asrModelDirectory: URL
    let asrModelSize: ASRModelSize
    let threads: Int
    let outputURL: URL
    let artifactOutputURL: URL

    static func parse(_ arguments: [String]) throws -> Self {
        guard let inputPath = arguments.first, !inputPath.isEmpty else {
            throw TranscribeFileCommandError.invalidArguments("入力音声ファイルを1つ指定してください。")
        }

        let requiredOptions = [
            "--silero-model",
            "--asr-model-directory",
            "--asr-model-size",
            "--threads",
            "--output",
            "--artifact-output"
        ]
        let optionNames = Set(requiredOptions)
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard optionNames.contains(option) else {
                throw TranscribeFileCommandError.invalidArguments("不明なオプションまたは余分な引数です: \(option)")
            }
            guard values[option] == nil else {
                throw TranscribeFileCommandError.invalidArguments("オプションを重複して指定できません: \(option)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
                throw TranscribeFileCommandError.invalidArguments("\(option) の値がありません。")
            }
            let value = arguments[index + 1]
            if optionNames.contains(value) {
                throw TranscribeFileCommandError.invalidArguments("\(option) の値がありません。")
            }
            values[option] = value
            index += 2
        }

        for option in requiredOptions where values[option] == nil {
            throw TranscribeFileCommandError.invalidArguments("必須オプションがありません: \(option)")
        }

        guard let sizeValue = values["--asr-model-size"],
              let size = ASRModelSize(rawValue: sizeValue) else {
            throw TranscribeFileCommandError.invalidArguments("ASRモデルサイズは 0.6b または 1.7b で指定してください。")
        }
        guard let threadValue = values["--threads"],
              let threads = Int(threadValue),
              threads > 0,
              Int32(exactly: threads) != nil else {
            throw TranscribeFileCommandError.invalidArguments("--threads は 1 以上 Int32.max 以下の整数で指定してください。")
        }

        guard let sileroPath = values["--silero-model"],
              let modelDirectory = values["--asr-model-directory"],
              let outputPath = values["--output"],
              let artifactPath = values["--artifact-output"] else {
            throw TranscribeFileCommandError.invalidArguments("必須オプションの値がありません。")
        }

        let parsed = Self(
            inputURL: Self.canonicalURL(inputPath),
            sileroModelURL: Self.canonicalURL(sileroPath),
            asrModelDirectory: Self.canonicalURL(modelDirectory),
            asrModelSize: size,
            threads: threads,
            outputURL: Self.canonicalURL(outputPath),
            artifactOutputURL: Self.canonicalURL(artifactPath)
        )
        try Self.rejectOutputAliases(parsed)
        try Self.rejectExistingOutput(at: URL(fileURLWithPath: outputPath))
        try Self.rejectExistingOutput(at: URL(fileURLWithPath: artifactPath))
        return parsed
    }

    private static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func rejectOutputAliases(_ arguments: Self) throws {
        let pairs: [(URL, URL, String)] = [
            (arguments.inputURL, arguments.outputURL, "出力ファイルが入力音声ファイルと同じです。"),
            (arguments.inputURL, arguments.artifactOutputURL, "成果物ファイルが入力音声ファイルと同じです。"),
            (arguments.outputURL, arguments.artifactOutputURL, "2つの出力ファイルが同じです。")
        ]
        for (first, second, message) in pairs {
            if samePath(first, second) {
                throw TranscribeFileCommandError.invalidArguments(message)
            }
        }
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        #if os(Windows)
        return first.path.caseInsensitiveCompare(second.path) == .orderedSame
        #else
        return first.path == second.path
        #endif
    }

    private static func rejectExistingOutput(at url: URL) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let fileError = error as NSError
            if fileError.domain == NSCocoaErrorDomain,
               fileError.code == NSFileReadNoSuchFileError {
                return
            }
            throw TranscribeFileCommandError.filesystem(
                "出力先のファイル情報を取得できません (\(url.path)): \(error.localizedDescription)"
            )
        }
        throw TranscribeFileCommandError.invalidOutput("出力先は既に存在します: \(url.path)")
    }
}

internal struct TranscribeFileCommandResult: Sendable {
    let segmentTexts: [String]
    let audioSeconds: Double
    let modelLoadSeconds: Double
    let inferenceSeconds: Double
    let rtf: Double
}

internal enum TranscribeFileCommandError: Error, LocalizedError {
    case invalidArguments(String)
    case invalidInput(String)
    case filesystem(String)
    case invalidOutput(String)
    case invalidMetric(String)
    case operationAndCleanup(operation: String, cleanup: String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            "\(message)\n\(TranscribeFileCommand.usage)"
        case .invalidInput(let message), .filesystem(let message), .invalidOutput(let message), .invalidMetric(let message):
            message
        case .operationAndCleanup(let operation, let cleanup):
            "処理に失敗しました: \(operation)\n一時データの削除にも失敗しました: \(cleanup)"
        }
    }
}

internal enum TranscribeFileCommand {
    static let usage = """
    使い方:
      MacAmbientJevTranscribeFile <audio-file> --silero-model <path> --asr-model-directory <dir> --asr-model-size <0.6b|1.7b> --threads <n> --output <file.json> --artifact-output <artifact.json>
    """

    static func run(arguments: [String]) async throws -> TranscribeFileCommandResult? {
        if arguments == ["--help"] {
            FileHandle.standardOutput.write(Data((usage + "\n").utf8))
            return nil
        }
        let options = try TranscribeFileArguments.parse(arguments)
        try validatePaths(options)
        try SileroVADModel.validate(at: options.sileroModelURL)
        try options.asrModelSize.validate(directory: options.asrModelDirectory)

        let fileManager = FileManager.default
        let scratchURL = fileManager.temporaryDirectory
            .appendingPathComponent("MacAmbientJevTranscribeFile-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: scratchURL, withIntermediateDirectories: false)
        } catch {
            throw TranscribeFileCommandError.filesystem("一時作業ディレクトリを作成できません: \(error.localizedDescription)")
        }

        let engine = ONNXQwen3ASREngine(
            modelDirectory: options.asrModelDirectory,
            size: options.asrModelSize,
            intraOpThreads: options.threads
        )
        var pipelineResult: FileTranscriptionResult?
        var audioSeconds: Double?
        var vadProvenance: RunProvenance?
        var operationError: Error?
        do {
            let audio = try await PortableAudioFileImporter.open(inputURL: options.inputURL, sessionURL: scratchURL)
            audioSeconds = audio.info.durationSeconds
            let environment = try ONNXEnvironment.shared()
            let vad = SileroFinalTranscriptVADSegmenter(
                environment: environment,
                modelURL: options.sileroModelURL,
                intraOpThreads: options.threads
            )
            vadProvenance = vad.provenance
            let pipeline = FileTranscriptionPipeline(audio: audio, asr: engine, vadSegmenter: vad)
            pipelineResult = try await pipeline.process(sessionID: UUID(), sessionURL: scratchURL)
        } catch {
            operationError = error
        }

        await engine.unload()
        do {
            try fileManager.removeItem(at: scratchURL)
        } catch {
            if let operationError {
                throw TranscribeFileCommandError.operationAndCleanup(
                    operation: operationError.localizedDescription,
                    cleanup: error.localizedDescription
                )
            }
            throw TranscribeFileCommandError.filesystem("一時作業ディレクトリを削除できません: \(error.localizedDescription)")
        }
        if let operationError { throw operationError }
        guard let pipelineResult,
              let audioSeconds,
              let vadProvenance else {
            throw TranscribeFileCommandError.filesystem("文字起こし結果または実行情報がありません。")
        }

        let payload = try makePayload(
            result: pipelineResult,
            audioSeconds: audioSeconds,
            asrProvenance: engine.provenance,
            vadProvenance: vadProvenance,
            options: options
        )
        let primaryData = try JSONSerialization.data(withJSONObject: payload.primary, options: [.prettyPrinted, .sortedKeys])
        let artifactData = try JSONSerialization.data(withJSONObject: payload.artifact, options: [.prettyPrinted, .sortedKeys])
        try primaryData.write(to: options.outputURL, options: .atomic)
        try artifactData.write(to: options.artifactOutputURL, options: .atomic)

        return TranscribeFileCommandResult(
            segmentTexts: pipelineResult.segments.map(\.text),
            audioSeconds: payload.audioSeconds,
            modelLoadSeconds: payload.modelLoadSeconds,
            inferenceSeconds: payload.inferenceSeconds,
            rtf: payload.rtf
        )
    }

    private static func validatePaths(_ options: TranscribeFileArguments) throws {
        try validateReadableFile(options.inputURL, description: "入力音声ファイル")
        try validateReadableFile(options.sileroModelURL, description: "Sileroモデル")
        try validateReadableDirectory(options.asrModelDirectory, description: "ASRモデルディレクトリ")
        try validateOutput(options.outputURL)
        try validateOutput(options.artifactOutputURL)
    }

    private static func validateReadableFile(_ url: URL, description: String) throws {
        let attributes = try attributes(at: url, description: description)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TranscribeFileCommandError.invalidInput("\(description)は通常ファイルではありません: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscribeFileCommandError.invalidInput("\(description)を読み取れません: \(url.path)")
        }
    }

    private static func validateReadableDirectory(_ url: URL, description: String) throws {
        let attributes = try attributes(at: url, description: description)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw TranscribeFileCommandError.invalidInput("\(description)はディレクトリではありません: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw TranscribeFileCommandError.invalidInput("\(description)を読み取れません: \(url.path)")
        }
    }

    private static func validateOutput(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        let parentAttributes = try attributes(at: parent, description: "出力先ディレクトリ")
        guard parentAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw TranscribeFileCommandError.invalidOutput("出力先の親パスはディレクトリではありません: \(parent.path)")
        }
    }

    private static func attributes(at url: URL, description: String) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw TranscribeFileCommandError.invalidInput("\(description)の情報を取得できません (\(url.path)): \(error.localizedDescription)")
        }
    }

    static func makePayload(
        result: FileTranscriptionResult,
        audioSeconds: Double,
        asrProvenance: RunProvenance,
        vadProvenance: RunProvenance,
        options: TranscribeFileArguments
    ) throws -> (primary: [String: Any], artifact: [String: Any], audioSeconds: Double, modelLoadSeconds: Double, inferenceSeconds: Double, rtf: Double) {
        let modelLoadSeconds = result.metrics.modelLoadSeconds
        let rawInferenceSeconds = result.segmentationSeconds + result.asrWallSeconds - modelLoadSeconds
        guard audioSeconds.isFinite, audioSeconds > 0,
              modelLoadSeconds.isFinite, modelLoadSeconds >= 0,
              rawInferenceSeconds.isFinite, rawInferenceSeconds >= 0 else {
            throw TranscribeFileCommandError.invalidMetric("実行時間の計測値が不正です。")
        }
        let inferenceSeconds = rawInferenceSeconds
        let rtf = inferenceSeconds / audioSeconds
        guard inferenceSeconds.isFinite, rtf.isFinite else {
            throw TranscribeFileCommandError.invalidMetric("実行時間の計測値が不正です。")
        }

        let runtime: [String: Any] = [
            "audio_seconds": audioSeconds,
            "model_load_seconds": modelLoadSeconds,
            "inference_seconds": inferenceSeconds,
            "rtf": rtf
        ]
        let primarySegments: [[String: Any]] = try result.segments.map { segment in
            [
                "start_ms": try milliseconds(frame: segment.reference.startFrame),
                "end_ms": try milliseconds(frame: segment.reference.endFrame),
                "text": segment.text
            ]
        }
        let primary: [String: Any] = [
            "schema_version": 1,
            "asr": try jsonObject(asrProvenance),
            "vad": try jsonObject(vadProvenance),
            "segments": primarySegments,
            "runtime": runtime
        ]

        let configuration = asrProvenance.configuration
        let inferenceConfig: [String: Any] = [
            "language": try requiredConfiguration("language", from: configuration),
            "minimum_input_seconds": try requiredDoubleConfiguration("minimum_input_seconds", from: configuration),
            "quantization": try requiredConfiguration("quantization", from: configuration),
            "mel_variant": try requiredConfiguration("mel_variant", from: configuration),
            "max_new_tokens": try requiredIntConfiguration("max_new_tokens", from: configuration),
            "no_repeat_ngram": try requiredConfiguration("no_repeat_ngram", from: configuration),
            "intra_op_threads": try requiredIntConfiguration("intra_op_threads", from: configuration),
            "inter_op_threads": try requiredIntConfiguration("inter_op_threads", from: configuration),
            "cpu_memory_arena": try requiredBoolConfiguration("cpu_memory_arena", from: configuration),
            "segmentation": "silero-final-transcript"
        ]
        let artifactSegments: [[String: Any]] = [[
            "start_ms": 0,
            "end_ms": try milliseconds(seconds: audioSeconds),
            "text": result.segments.map(\.text).joined(separator: "\n"),
            "language": "ja"
        ]]
        let artifactEngine: [String: Any] = [
            "name": "qwen3-asr",
            "model": options.asrModelSize.repository,
            "revision": options.asrModelSize.commit,
            "backend": "onnxruntime",
            "device": "cpu",
            "package_versions": ["onnxruntime": ONNXEnvironment.runtimeVersion],
            "inference_config": inferenceConfig
        ]
        let artifact: [String: Any] = [
            "schema_version": 2,
            "engine": artifactEngine,
            "segments": artifactSegments,
            "runtime": runtime
        ]
        return (primary, artifact, audioSeconds, modelLoadSeconds, inferenceSeconds, rtf)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscribeFileCommandError.invalidMetric("実行情報をJSONオブジェクトに変換できません。")
        }
        return object
    }

    private static func requiredConfiguration(_ key: String, from configuration: [String: String]) throws -> String {
        guard let value = configuration[key] else {
            throw TranscribeFileCommandError.invalidMetric("ASR設定に \(key) がありません。")
        }
        return value
    }

    private static func requiredDoubleConfiguration(_ key: String, from configuration: [String: String]) throws -> Double {
        let string = try requiredConfiguration(key, from: configuration)
        guard let value = Double(string), value.isFinite else {
            throw TranscribeFileCommandError.invalidMetric("ASR設定 \(key) を数値に変換できません: \(string)")
        }
        return value
    }

    private static func requiredIntConfiguration(_ key: String, from configuration: [String: String]) throws -> Int {
        let string = try requiredConfiguration(key, from: configuration)
        guard let value = Int(string) else {
            throw TranscribeFileCommandError.invalidMetric("ASR設定 \(key) を整数に変換できません: \(string)")
        }
        return value
    }

    private static func requiredBoolConfiguration(_ key: String, from configuration: [String: String]) throws -> Bool {
        let string = try requiredConfiguration(key, from: configuration)
        guard let value = Bool(string) else {
            throw TranscribeFileCommandError.invalidMetric("ASR設定 \(key) を真偽値に変換できません: \(string)")
        }
        return value
    }

    private static func milliseconds(frame: Int64) throws -> Int {
        guard frame >= 0 else {
            throw TranscribeFileCommandError.invalidMetric("区間フレーム位置が負数です。")
        }
        return try milliseconds(seconds: Double(frame) / Double(CanonicalAudio.sampleRate))
    }

    private static func milliseconds(seconds: Double) throws -> Int {
        let rounded = (seconds * 1_000).rounded(.toNearestOrEven)
        guard rounded.isFinite, let value = Int(exactly: rounded) else {
            throw TranscribeFileCommandError.invalidMetric("ミリ秒の値がIntの範囲外です。")
        }
        return value
    }
}

@main
internal struct TranscribeFileMain {
    static func main() async {
        do {
            _ = try await TranscribeFileCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
