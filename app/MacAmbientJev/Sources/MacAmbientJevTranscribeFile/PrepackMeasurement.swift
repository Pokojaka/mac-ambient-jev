#if os(Windows)
import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevPortableRuntime
import WinSDK

internal enum PrepackMeasurement {
    static let usage = """
    Windows CPU prepack measurement:
      MacAmbientJevTranscribeFile measure-prepack --fixture <path> --asr-model-directory <dir> --asr-model-size <0.6b|1.7b> --threads <positive-int32> --prepack <current|external-mapped|saved-prepacked> --action <save|measure> --calls <integer-at-least-50> --output <new.json> [--prepack-directory <new-or-existing-dir>]

    --prepack-directory is required only for saved-prepacked. Use --action save to create it,
    then --action measure to validate and measure the saved files. No automatic regeneration occurs.
    """

    private static let fixtureSHA256 = "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"
    private static let fixtureSampleCount = 52_907
    private static let fixtureByteCount = 44 + fixtureSampleCount * 2
    private static let fixtureSampleRate = 16_000
    private static let manifestFilename = "manifest.json"
    private static let expectedGraphRoles = ["encoder", "decoder_init", "decoder_step"]
    private static let externalMappedEntries = [
        "session.use_device_allocator_for_initializers": "0",
        "session.disable_prepacking": "0",
    ]

    private enum Mode: String {
        case current
        case externalMapped = "external-mapped"
        case savedPrepacked = "saved-prepacked"
    }

    private enum Action: String {
        case save
        case measure
    }

    private struct Options {
        let fixtureURL: URL
        let modelDirectory: URL
        let modelSize: ASRModelSize
        let threads: Int
        let mode: Mode
        let action: Action
        let calls: Int
        let outputURL: URL
        let prepackDirectory: URL?
    }

    private struct Fixture {
        let audio: ASRAudioInput
        let sha256: String
        let sampleCount: Int
        let audioSeconds: Double
    }

    private struct ModelFileIdentity: Codable, Equatable {
        let role: String
        let name: String
        let sha256: String
        let byteCount: Int64

        enum CodingKeys: String, CodingKey {
            case role, name, sha256
            case byteCount = "byte_count"
        }
    }

    private struct ModelIdentity: Codable, Equatable {
        let size: String
        let repository: String
        let commit: String
        let files: [ModelFileIdentity]
    }

    private struct ArtifactFileIdentity: Codable, Equatable {
        let name: String
        let sha256: String
        let byteCount: Int64

        enum CodingKeys: String, CodingKey {
            case name, sha256
            case byteCount = "byte_count"
        }
    }

    private struct PrepackManifest: Codable, Equatable {
        let schemaVersion: Int
        let model: ModelIdentity
        let onnxRuntimeVersion: String
        let architectureISA: String
        let x64ExperimentStatus: String
        let threads: Int
        let interOpThreads: Int
        let cpuMemoryArenaEnabled: Bool
        let graphOptimizationLevel: String
        let generationDurationSeconds: Double
        let sessionEntriesByGraph: [String: [String: String]]
        let generatedFiles: [ArtifactFileIdentity]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case model
            case onnxRuntimeVersion = "onnxruntime_version"
            case architectureISA = "architecture_isa"
            case x64ExperimentStatus = "x64_experiment_status"
            case threads
            case interOpThreads = "inter_op_threads"
            case cpuMemoryArenaEnabled = "cpu_memory_arena_enabled"
            case graphOptimizationLevel = "graph_optimization_level"
            case generationDurationSeconds = "generation_duration_seconds"
            case sessionEntriesByGraph = "session_entries_by_graph"
            case generatedFiles = "generated_files"
        }
    }

    private struct SaveResult: Encodable {
        let schemaVersion = 1
        let action = "save"
        let generationDurationSeconds: Double
        let manifest: PrepackManifest

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case action
            case generationDurationSeconds = "generation_duration_seconds"
            case manifest
        }
    }

    private struct ProcessMemorySnapshot: Encodable {
        let peakWorkingSetBytes: UInt64
        let workingSetBytes: UInt64
        let privateUsageBytes: UInt64
        let peakPagefileUsageBytes: UInt64
        let pageFaultCount: UInt32

        enum CodingKeys: String, CodingKey {
            case peakWorkingSetBytes = "peak_working_set_bytes"
            case workingSetBytes = "working_set_bytes"
            case privateUsageBytes = "private_usage_bytes"
            case peakPagefileUsageBytes = "peak_pagefile_usage_bytes"
            case pageFaultCount = "page_fault_count"
        }
    }

    private struct FixtureRecord: Encodable {
        let sha256: String
        let sampleCount: Int
        let sampleRate: Int
        let audioSeconds: Double

        enum CodingKeys: String, CodingKey {
            case sha256
            case sampleCount = "sample_count"
            case sampleRate = "sample_rate"
            case audioSeconds = "audio_seconds"
        }
    }

    private struct InferenceSettings: Encodable {
        let language = "ja"
        let decoding = "greedy"
        let maxNewTokens = 448
        let noRepeatNgramSize: Int? = nil

        enum CodingKeys: String, CodingKey {
            case language, decoding
            case maxNewTokens = "max_new_tokens"
            case noRepeatNgramSize = "no_repeat_ngram_size"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(language, forKey: .language)
            try container.encode(decoding, forKey: .decoding)
            try container.encode(maxNewTokens, forKey: .maxNewTokens)
            try container.encodeNil(forKey: .noRepeatNgramSize)
        }
    }

    private struct FirstTranscription: Encodable {
        let elapsedSeconds: Double
        let rtf: Double
        let text: String
        let generatedIDs: [Int64]

        enum CodingKeys: String, CodingKey {
            case elapsedSeconds = "elapsed_seconds"
            case rtf, text
            case generatedIDs = "generated_ids"
        }
    }

    private struct WarmSummary: Encodable {
        let calls: Int
        let latencySeconds: [Double]
        let rtf: [Double]
        let meanRTF: Double
        let p95Seconds: Double

        enum CodingKeys: String, CodingKey {
            case calls
            case latencySeconds = "latency_seconds"
            case rtf
            case meanRTF = "mean_rtf"
            case p95Seconds = "p95_seconds"
        }
    }

    private struct MemorySnapshots: Encodable {
        let beforeLoad: ProcessMemorySnapshot
        let afterPrepare: ProcessMemorySnapshot
        let afterFirstTranscribe: ProcessMemorySnapshot
        let afterAllWarmCalls: ProcessMemorySnapshot

        enum CodingKeys: String, CodingKey {
            case beforeLoad = "before_load"
            case afterPrepare = "after_prepare"
            case afterFirstTranscribe = "after_first_transcribe"
            case afterAllWarmCalls = "after_all_warm_calls"
        }
    }

    private struct MeasurementResult: Encodable {
        let schemaVersion = 1
        let action = "measure"
        let mode: String
        let modeDescription: String
        let processID: Int32
        let architectureISA: String
        let onnxRuntimeVersion: String
        let model: ModelIdentity
        let fixture: FixtureRecord
        let threads: Int
        let interOpThreads: Int
        let cpuMemoryArenaEnabled = false
        let graphOptimizationLevel = "enable_all"
        let x64ExperimentStatus = "unrun"
        let graphConfigEntries: [String: [String: String]]
        let savedPrepackManifest: PrepackManifest?
        let coldProcessLoadSeconds: Double
        let firstTranscription: FirstTranscription
        let warm: WarmSummary
        let memory: MemorySnapshots
        let inferenceSettings = InferenceSettings()
        let timerScope = "cold_process_load_seconds measures engine.prepare() only; fixture/model acquisition and all SHA-256 validation are completed before the timer."
        let memoryNotes = "PeakWorkingSetSize and PeakPagefileUsage are process-lifetime high-water marks, including any transient load peak. PrivateUsage is current private commit at each snapshot, not a peak; PeakPagefileUsage is the true peak private commit. WorkingSetSize is current resident memory."
        let validationCacheNote = "Fixture and derived-file hashes are validated before timing; the operating-system file cache is therefore warmed by validation."
        let consistencyNote = "The first transcription's exact UTF-8 bytes and generated token IDs are required for every subsequent call. No expected Japanese transcript is enforced."

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case action, mode
            case modeDescription = "mode_description"
            case processID = "process_id"
            case architectureISA = "architecture_isa"
            case onnxRuntimeVersion = "onnxruntime_version"
            case model, fixture, threads
            case interOpThreads = "inter_op_threads"
            case cpuMemoryArenaEnabled = "cpu_memory_arena_enabled"
            case graphOptimizationLevel = "graph_optimization_level"
            case x64ExperimentStatus = "x64_experiment_status"
            case graphConfigEntries = "graph_config_entries"
            case savedPrepackManifest = "saved_prepack_manifest"
            case coldProcessLoadSeconds = "cold_process_load_seconds"
            case firstTranscription = "first_transcription"
            case warm, memory
            case inferenceSettings = "inference_settings"
            case timerScope = "timer_scope"
            case memoryNotes = "memory_notes"
            case validationCacheNote = "validation_cache_note"
            case consistencyNote = "consistency_note"
        }
    }

    private struct CoreMeasurement {
        let coldProcessLoadSeconds: Double
        let first: FirstTranscription
        let warm: WarmSummary
        let memory: MemorySnapshots
    }

    private enum MeasurementError: Error, LocalizedError {
        case invalidArguments(String)
        case invalidInput(String)
        case filesystem(String)
        case cleanup(operation: String, cleanup: String)

        var errorDescription: String? {
            switch self {
            case .invalidArguments(let message), .invalidInput(let message), .filesystem(let message):
                message
            case .cleanup(let operation, let cleanup):
                "処理に失敗しました: \(operation)\n所有する一時データの削除にも失敗しました: \(cleanup)"
            }
        }
    }

    static func run(_ arguments: [String]) async throws {
        let options = try parse(arguments)
        let architecture = try architectureISA()
        try validatePaths(options)
        let modelIdentity = try validateAndIdentifyModel(options)
        let fixture = try loadFixture(at: options.fixtureURL)

        if options.action == .save {
            try await savePrepack(options: options, modelIdentity: modelIdentity)
            return
        }

        let savedManifest: PrepackManifest?
        if options.mode == .savedPrepacked {
            guard let directory = options.prepackDirectory else {
                throw MeasurementError.invalidArguments("saved-prepacked では --prepack-directory が必要です。")
            }
            savedManifest = try validateSavedPrepack(
                at: directory,
                options: options,
                modelIdentity: modelIdentity,
                architecture: architecture
            )
        } else {
            savedManifest = nil
        }

        let engine = try makeMeasurementEngine(options: options)
        let core = try await measure(engine: engine, fixture: fixture, calls: options.calls)
        let result = MeasurementResult(
            mode: options.mode.rawValue,
            modeDescription: modeDescription(options.mode),
            processID: ProcessInfo.processInfo.processIdentifier,
            architectureISA: architecture,
            onnxRuntimeVersion: ONNXEnvironment.runtimeVersion,
            model: modelIdentity,
            fixture: FixtureRecord(
                sha256: fixture.sha256,
                sampleCount: fixture.sampleCount,
                sampleRate: fixtureSampleRate,
                audioSeconds: fixture.audioSeconds
            ),
            threads: options.threads,
            interOpThreads: Int(ONNXSession.interOpThreads),
            graphConfigEntries: measurementConfigEntries(options.mode),
            savedPrepackManifest: savedManifest,
            coldProcessLoadSeconds: core.coldProcessLoadSeconds,
            firstTranscription: core.first,
            warm: core.warm,
            memory: core.memory
        )
        try writeNewJSON(result, to: options.outputURL)
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        let required = [
            "--fixture",
            "--asr-model-directory",
            "--asr-model-size",
            "--threads",
            "--prepack",
            "--action",
            "--calls",
            "--output",
        ]
        let accepted = Set(required + ["--prepack-directory"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard accepted.contains(option) else {
                throw MeasurementError.invalidArguments("不明なオプションまたは余分な引数です: \(option)\n\(usage)")
            }
            guard values[option] == nil else {
                throw MeasurementError.invalidArguments("オプションを重複して指定できません: \(option)\n\(usage)")
            }
            guard index + 1 < arguments.count,
                  !arguments[index + 1].isEmpty,
                  !accepted.contains(arguments[index + 1]) else {
                throw MeasurementError.invalidArguments("\(option) の値がありません。\n\(usage)")
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        for option in required where values[option] == nil {
            throw MeasurementError.invalidArguments("必須オプションがありません: \(option)\n\(usage)")
        }

        guard let sizeText = values["--asr-model-size"],
              let size = ASRModelSize(rawValue: sizeText) else {
            throw MeasurementError.invalidArguments("--asr-model-size は 0.6b または 1.7b で指定してください。")
        }
        guard let threadText = values["--threads"],
              let threads = Int(threadText), threads > 0, Int32(exactly: threads) != nil else {
            throw MeasurementError.invalidArguments("--threads は 1 以上 Int32.max 以下の整数で指定してください。")
        }
        guard let modeText = values["--prepack"], let mode = Mode(rawValue: modeText) else {
            throw MeasurementError.invalidArguments("--prepack は current、external-mapped、saved-prepacked のいずれかで指定してください。")
        }
        guard let actionText = values["--action"], let action = Action(rawValue: actionText) else {
            throw MeasurementError.invalidArguments("--action は save または measure で指定してください。")
        }
        guard let callsText = values["--calls"], let calls = Int(callsText), calls >= 50 else {
            throw MeasurementError.invalidArguments("--calls は 50 以上の整数で指定してください。")
        }
        guard let fixturePath = values["--fixture"],
              let modelPath = values["--asr-model-directory"],
              let outputPath = values["--output"] else {
            throw MeasurementError.invalidArguments("必須オプションの値がありません。")
        }

        let prepackDirectory: URL?
        if mode == .savedPrepacked {
            guard let path = values["--prepack-directory"], !path.isEmpty else {
                throw MeasurementError.invalidArguments("saved-prepacked では --prepack-directory が必要です。")
            }
            prepackDirectory = canonicalURL(path)
        } else {
            guard values["--prepack-directory"] == nil else {
                throw MeasurementError.invalidArguments("--prepack-directory は saved-prepacked の場合だけ指定できます。")
            }
            prepackDirectory = nil
        }
        guard action != .save || mode == .savedPrepacked else {
            throw MeasurementError.invalidArguments("--action save は saved-prepacked の場合だけ指定できます。")
        }

        return Options(
            fixtureURL: canonicalURL(fixturePath),
            modelDirectory: canonicalURL(modelPath),
            modelSize: size,
            threads: threads,
            mode: mode,
            action: action,
            calls: calls,
            outputURL: canonicalURL(outputPath),
            prepackDirectory: prepackDirectory
        )
    }

    private static func validatePaths(_ options: Options) throws {
        try requireReadable(.typeRegular, at: options.fixtureURL, description: "fixture")
        try requireReadable(.typeDirectory, at: options.modelDirectory, description: "ASRモデルディレクトリ")
        try requireDirectory(at: options.outputURL.deletingLastPathComponent(), description: "JSON出力先の親ディレクトリ")
        try requireAbsent(at: options.outputURL, description: "JSON出力先")

        guard !samePath(options.outputURL, options.fixtureURL) else {
            throw MeasurementError.invalidInput("JSON出力先がfixtureと同じです: \(options.outputURL.path)")
        }
        guard !isSameOrDescendant(options.outputURL, of: options.modelDirectory) else {
            throw MeasurementError.invalidInput("JSON出力先をモデルのソースディレクトリ内に置けません: \(options.outputURL.path)")
        }

        if options.mode == .savedPrepacked {
            guard let directory = options.prepackDirectory else {
                throw MeasurementError.invalidArguments("saved-prepacked では --prepack-directory が必要です。")
            }
            guard !samePath(directory, options.modelDirectory),
                  !isSameOrDescendant(directory, of: options.modelDirectory) else {
                throw MeasurementError.invalidInput("派生ディレクトリをモデルのソースディレクトリと同一または内部にできません: \(directory.path)")
            }
            guard !samePath(directory, options.fixtureURL) else {
                throw MeasurementError.invalidInput("派生ディレクトリがfixtureと同じです: \(directory.path)")
            }
            try requireDirectory(at: directory.deletingLastPathComponent(), description: "派生ディレクトリの親")
            if options.action == .save {
                try requireAbsent(at: directory, description: "新しい派生ディレクトリ")
            } else {
                try requireReadable(.typeDirectory, at: directory, description: "saved-prepacked派生ディレクトリ")
            }
            guard !isSameOrDescendant(options.outputURL, of: directory) else {
                throw MeasurementError.invalidInput("JSON出力先を派生ディレクトリ内に置けません: \(options.outputURL.path)")
            }
        }
    }

    private static func validateAndIdentifyModel(_ options: Options) throws -> ModelIdentity {
        try options.modelSize.validate(directory: options.modelDirectory)
        var files: [ModelFileIdentity] = []
        for file in options.modelSize.files.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
            let url = options.modelDirectory.appendingPathComponent(file.name, isDirectory: false)
            let attributes = try itemAttributes(at: url, description: "モデルファイル")
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let number = attributes[.size] as? NSNumber,
                  number.int64Value == file.byteCount else {
                throw MeasurementError.invalidInput("Pinned model file type or byte count mismatch: \(url.path)")
            }
            let actualHash = try FileSHA256.hexDigest(ofFileAt: url)
            guard actualHash == file.sha256 else {
                throw MeasurementError.invalidInput("Pinned model SHA-256 mismatch for \(url.path): expected \(file.sha256), actual \(actualHash)")
            }
            files.append(ModelFileIdentity(
                role: file.role.rawValue,
                name: file.name,
                sha256: file.sha256,
                byteCount: file.byteCount
            ))
        }
        return ModelIdentity(
            size: options.modelSize.rawValue,
            repository: options.modelSize.repository,
            commit: options.modelSize.commit,
            files: files
        )
    }

    private static func loadFixture(at url: URL) throws -> Fixture {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MeasurementError.invalidInput("fixtureを読み込めません (\(url.path)): \(error.localizedDescription)")
        }
        let digest = FileSHA256.hexDigest(of: data)
        guard digest == fixtureSHA256, data.count == fixtureByteCount else {
            throw MeasurementError.invalidInput("fixtureのSHA-256またはbyte countが一致しません: expected \(fixtureSHA256), \(fixtureByteCount); actual \(digest), \(data.count)")
        }

        let bytes = [UInt8](data)
        var samples = [Float]()
        samples.reserveCapacity(fixtureSampleCount)
        for index in 0..<fixtureSampleCount {
            let offset = 44 + index * 2
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768.0)
        }
        let audioSeconds = Double(fixtureSampleCount) / Double(fixtureSampleRate)
        guard audioSeconds.isFinite, audioSeconds > 0 else {
            throw MeasurementError.invalidInput("fixtureの音声時間が不正です。")
        }
        return Fixture(
            audio: ASRAudioInput(samples: samples, sampleRate: fixtureSampleRate),
            sha256: digest,
            sampleCount: fixtureSampleCount,
            audioSeconds: audioSeconds
        )
    }

    private static func savePrepack(options: Options, modelIdentity: ModelIdentity) async throws {
        guard let destination = options.prepackDirectory else {
            throw MeasurementError.invalidArguments("saved-prepacked saveには --prepack-directory が必要です。")
        }
        let fileManager = FileManager.default
        let stagingName = ".\(destination.lastPathComponent).\(UUID().uuidString).staging"
        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
        let canonicalStagingURL = canonicalURL(stagingURL.path)
        guard samePath(stagingURL, canonicalStagingURL),
              samePath(canonicalURL(stagingURL.deletingLastPathComponent().path), stagingURL.deletingLastPathComponent()) else {
            throw MeasurementError.filesystem("staging sibling path failed canonical validation: \(stagingURL.path)")
        }

        try requireAbsent(at: destination, description: "新しい派生ディレクトリ")
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        } catch {
            throw MeasurementError.filesystem("stagingディレクトリを作成できません (\(stagingURL.path)): \(error.localizedDescription)")
        }
        var ownsStaging = true

        do {
            let engine = ONNXQwen3ASREngine.forCPUMeasurement(
                modelDirectory: options.modelDirectory,
                size: options.modelSize,
                intraOpThreads: options.threads,
                graphDirectory: options.modelDirectory,
                configEntriesByGraph: saveSessionEntries(options: options, stagingDirectory: stagingURL)
            )
            let started = DispatchTime.now().uptimeNanoseconds
            var preparationError: Error?
            do {
                try await engine.prepare()
            } catch {
                preparationError = error
            }
            await engine.unload()
            if let preparationError { throw preparationError }
            let ended = DispatchTime.now().uptimeNanoseconds
            let duration = try elapsedSeconds(start: started, end: ended)

            let generatedFiles = try hashGeneratedFiles(in: stagingURL, modelSize: options.modelSize)
            let architecture = try architectureISA()
            let manifest = PrepackManifest(
                schemaVersion: 1,
                model: modelIdentity,
                onnxRuntimeVersion: ONNXEnvironment.runtimeVersion,
                architectureISA: architecture,
                x64ExperimentStatus: "unrun",
                threads: options.threads,
                interOpThreads: Int(ONNXSession.interOpThreads),
                cpuMemoryArenaEnabled: false,
                graphOptimizationLevel: "enable_all",
                generationDurationSeconds: duration,
                sessionEntriesByGraph: recordedSaveSessionEntries(options: options),
                generatedFiles: generatedFiles
            )
            try writeNewJSON(manifest, to: stagingURL.appendingPathComponent(manifestFilename))
            try validateManifestDirectoryContents(at: stagingURL, expectedFileNames: Set(generatedFiles.map(\.name) + [manifestFilename]))

            try requireAbsent(at: destination, description: "新しい派生ディレクトリ")
            try validateOwnedStagingPath(stagingURL, expected: canonicalStagingURL)
            do {
                try fileManager.moveItem(at: stagingURL, to: destination)
                ownsStaging = false
            } catch {
                throw MeasurementError.filesystem("完成した派生ディレクトリを公開できません (\(destination.path)): \(error.localizedDescription)")
            }

            try writeNewJSON(
                SaveResult(generationDurationSeconds: duration, manifest: manifest),
                to: options.outputURL
            )
        } catch {
            let operation = error.localizedDescription
            if ownsStaging {
                do {
                    try removeOwnedStaging(stagingURL, expected: canonicalStagingURL)
                } catch {
                    throw MeasurementError.cleanup(operation: operation, cleanup: error.localizedDescription)
                }
            }
            throw error
        }
    }

    private static func validateSavedPrepack(
        at directory: URL,
        options: Options,
        modelIdentity: ModelIdentity,
        architecture: String
    ) throws -> PrepackManifest {
        let manifestURL = directory.appendingPathComponent(manifestFilename, isDirectory: false)
        do {
            try requireRegularNonSymlinkFile(at: manifestURL, expectedParent: directory)
        } catch {
            throw MeasurementError.invalidInput("saved-prepacked manifest is missing, unreadable, or not a regular file: \(error.localizedDescription). Explicit regeneration with --action save is required.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw MeasurementError.invalidInput("saved-prepacked manifestを読み込めません: \(manifestURL.path): \(error.localizedDescription)。再生成する場合は明示的に --action save を実行してください。")
        }
        let manifest: PrepackManifest
        do {
            manifest = try JSONDecoder().decode(PrepackManifest.self, from: data)
        } catch {
            throw MeasurementError.invalidInput("saved-prepacked manifestが不正です: \(error.localizedDescription)。再生成する場合は明示的に --action save を実行してください。")
        }

        guard manifest.schemaVersion == 1,
              manifest.model == modelIdentity,
              manifest.onnxRuntimeVersion == ONNXEnvironment.runtimeVersion,
              manifest.architectureISA == architecture,
              manifest.x64ExperimentStatus == "unrun",
              manifest.threads == options.threads,
              manifest.threads > 0,
              Int32(exactly: manifest.threads) != nil,
              manifest.interOpThreads == Int(ONNXSession.interOpThreads),
              !manifest.cpuMemoryArenaEnabled,
              manifest.graphOptimizationLevel == "enable_all",
              manifest.generationDurationSeconds.isFinite,
              manifest.generationDurationSeconds >= 0,
              manifest.sessionEntriesByGraph == recordedSaveSessionEntries(options: options) else {
            throw MeasurementError.invalidInput("saved-prepacked manifest identity/configuration does not match this pinned runtime and model. Explicit regeneration with --action save is required.")
        }

        let expectedNames = expectedGeneratedFileNames(modelSize: options.modelSize)
        guard Set(manifest.generatedFiles.map(\.name)) == expectedNames,
              manifest.generatedFiles.count == expectedNames.count,
              Set(manifest.generatedFiles.map(\.name)).count == expectedNames.count else {
            throw MeasurementError.invalidInput("saved-prepacked manifest has an unexpected generated file set. Explicit regeneration with --action save is required.")
        }
        try validateManifestDirectoryContents(at: directory, expectedFileNames: expectedNames.union([manifestFilename]))
        for item in manifest.generatedFiles {
            let fileURL = directory.appendingPathComponent(item.name, isDirectory: false)
            do {
                try requireRegularNonSymlinkFile(at: fileURL, expectedParent: directory)
                let attributes = try itemAttributes(at: fileURL, description: "derived graph/data file")
                guard let count = attributes[.size] as? NSNumber,
                      count.int64Value == item.byteCount,
                      item.byteCount > 0 else {
                    throw MeasurementError.invalidInput("saved-prepacked byte count mismatch: \(fileURL.path)")
                }
                let digest = try FileSHA256.hexDigest(ofFileAt: fileURL)
                guard digest == item.sha256 else {
                    throw MeasurementError.invalidInput("saved-prepacked SHA-256 mismatch: \(fileURL.path)")
                }
            } catch {
                throw MeasurementError.invalidInput("saved-prepacked file validation failed for \(fileURL.path): \(error.localizedDescription). Explicit regeneration with --action save is required.")
            }
        }
        return manifest
    }

    private static func measure(
        engine: ONNXQwen3ASREngine,
        fixture: Fixture,
        calls: Int
    ) async throws -> CoreMeasurement {
        var beforeLoad: ProcessMemorySnapshot?
        var coldLoadSeconds: Double?
        var first: FirstTranscription?
        var warmSummary: WarmSummary?
        var afterPrepare: ProcessMemorySnapshot?
        var afterFirst: ProcessMemorySnapshot?
        var afterAll: ProcessMemorySnapshot?
        var operationError: Error?

        do {
            beforeLoad = try processMemorySnapshot()
            let prepareStarted = DispatchTime.now().uptimeNanoseconds
            try await engine.prepare()
            let prepareEnded = DispatchTime.now().uptimeNanoseconds
            coldLoadSeconds = try elapsedSeconds(start: prepareStarted, end: prepareEnded)
            afterPrepare = try processMemorySnapshot()

            let firstStarted = DispatchTime.now().uptimeNanoseconds
            let firstOutput = try await engine.transcribeWithTokens(fixture.audio)
            let firstEnded = DispatchTime.now().uptimeNanoseconds
            let firstSeconds = try elapsedSeconds(start: firstStarted, end: firstEnded)
            let firstRTF = firstSeconds / fixture.audioSeconds
            guard firstRTF.isFinite else {
                throw MeasurementError.invalidInput("first transcription RTF is not finite")
            }
            first = FirstTranscription(
                elapsedSeconds: firstSeconds,
                rtf: firstRTF,
                text: firstOutput.text,
                generatedIDs: firstOutput.generatedIDs
            )
            afterFirst = try processMemorySnapshot()

            let firstUTF8 = Array(firstOutput.text.utf8)
            var latencies: [Double] = []
            for callIndex in 0..<calls {
                let started = DispatchTime.now().uptimeNanoseconds
                let output = try await engine.transcribeWithTokens(fixture.audio)
                let ended = DispatchTime.now().uptimeNanoseconds
                let latency = try elapsedSeconds(start: started, end: ended)
                guard Array(output.text.utf8) == firstUTF8,
                      output.generatedIDs == firstOutput.generatedIDs else {
                    throw MeasurementError.invalidInput("transcription output changed on warm call \(callIndex + 1); exact UTF-8 bytes and generated IDs must match the first call")
                }
                latencies.append(latency)
            }
            afterAll = try processMemorySnapshot()
            let meanSeconds = latencies.reduce(0, +) / Double(latencies.count)
            let sortedLatencies = latencies.sorted()
            let p95Index = Int(ceil(0.95 * Double(sortedLatencies.count))) - 1
            guard p95Index >= 0, p95Index < sortedLatencies.count else {
                throw MeasurementError.invalidInput("nearest-rank p95 index is invalid")
            }
            let meanRTF = meanSeconds / fixture.audioSeconds
            guard meanRTF.isFinite else {
                throw MeasurementError.invalidInput("warm mean RTF is not finite")
            }
            let warmRTFs = latencies.map { $0 / fixture.audioSeconds }
            guard warmRTFs.allSatisfy(\.isFinite) else {
                throw MeasurementError.invalidInput("a warm per-call RTF is not finite")
            }
            warmSummary = WarmSummary(
                calls: calls,
                latencySeconds: latencies,
                rtf: warmRTFs,
                meanRTF: meanRTF,
                p95Seconds: sortedLatencies[p95Index]
            )
        } catch {
            operationError = error
        }

        await engine.unload()
        if let operationError { throw operationError }
        guard let beforeLoad, let coldLoadSeconds, let first, let warmSummary,
              let afterPrepare, let afterFirst, let afterAll else {
            throw MeasurementError.filesystem("measurement completed without all timer and memory snapshots")
        }
        return CoreMeasurement(
            coldProcessLoadSeconds: coldLoadSeconds,
            first: first,
            warm: warmSummary,
            memory: MemorySnapshots(
                beforeLoad: beforeLoad,
                afterPrepare: afterPrepare,
                afterFirstTranscribe: afterFirst,
                afterAllWarmCalls: afterAll
            )
        )
    }

    private static func makeMeasurementEngine(options: Options) throws -> ONNXQwen3ASREngine {
        switch options.mode {
        case .current:
            return ONNXQwen3ASREngine(
                modelDirectory: options.modelDirectory,
                size: options.modelSize,
                intraOpThreads: options.threads
            )
        case .externalMapped:
            return ONNXQwen3ASREngine.forCPUMeasurement(
                modelDirectory: options.modelDirectory,
                size: options.modelSize,
                intraOpThreads: options.threads,
                graphDirectory: options.modelDirectory,
                configEntriesByGraph: measurementConfigEntries(options.mode)
            )
        case .savedPrepacked:
            guard let graphDirectory = options.prepackDirectory else {
                throw MeasurementError.invalidArguments("saved-prepacked では --prepack-directory が必要です。")
            }
            return ONNXQwen3ASREngine.forCPUMeasurement(
                modelDirectory: options.modelDirectory,
                size: options.modelSize,
                intraOpThreads: options.threads,
                graphDirectory: graphDirectory,
                configEntriesByGraph: measurementConfigEntries(options.mode)
            )
        }
    }

    private static func measurementConfigEntries(_ mode: Mode) -> [String: [String: String]] {
        switch mode {
        case .current:
            return Dictionary(uniqueKeysWithValues: expectedGraphRoles.map { ($0, [:]) })
        case .externalMapped, .savedPrepacked:
            return Dictionary(uniqueKeysWithValues: expectedGraphRoles.map { ($0, externalMappedEntries) })
        }
    }

    private static func saveSessionEntries(
        options: Options,
        stagingDirectory: URL
    ) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: graphFiles(for: options.modelSize).map { role, file in
            var entries = externalMappedEntries
            entries["session.save_external_prepacked_constant_initializers"] = "1"
            entries["session.optimized_model_filepath"] = stagingDirectory.appendingPathComponent(file.name).path
            entries["session.optimized_model_external_initializers_file_name"] = "\(role).data"
            entries["session.optimized_model_external_initializers_min_size_in_bytes"] = "1024"
            return (role, entries)
        })
    }

    private static func recordedSaveSessionEntries(options: Options) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: graphFiles(for: options.modelSize).map { role, file in
            var entries = externalMappedEntries
            entries["session.save_external_prepacked_constant_initializers"] = "1"
            entries["session.optimized_model_filepath"] = "<staging>/\(file.name)"
            entries["session.optimized_model_external_initializers_file_name"] = "\(role).data"
            entries["session.optimized_model_external_initializers_min_size_in_bytes"] = "1024"
            return (role, entries)
        })
    }

    private static func graphFiles(for size: ASRModelSize) -> [(String, Qwen3ASRModelFile)] {
        expectedGraphRoles.map { role in
            guard let file = size.files.first(where: { $0.role.rawValue == role }) else {
                fatalError("Pinned ASR manifest is missing graph role \(role)")
            }
            return (role, file)
        }
    }

    private static func expectedGeneratedFileNames(modelSize: ASRModelSize) -> Set<String> {
        let graphs = graphFiles(for: modelSize)
        return Set(graphs.flatMap { role, file in [file.name, "\(role).data"] })
    }

    private static func hashGeneratedFiles(
        in directory: URL,
        modelSize: ASRModelSize
    ) throws -> [ArtifactFileIdentity] {
        let expected = expectedGeneratedFileNames(modelSize: modelSize)
        try validateManifestDirectoryContents(at: directory, expectedFileNames: expected)
        var result: [ArtifactFileIdentity] = []
        for name in expected.sorted() {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            try requireRegularNonSymlinkFile(at: url, expectedParent: directory)
            let attributes = try itemAttributes(at: url, description: "generated graph/data file")
            guard let count = attributes[.size] as? NSNumber, count.int64Value > 0 else {
                throw MeasurementError.filesystem("generated graph/data file is empty or has no size: \(url.path)")
            }
            result.append(ArtifactFileIdentity(
                name: name,
                sha256: try FileSHA256.hexDigest(ofFileAt: url),
                byteCount: count.int64Value
            ))
        }
        return result
    }

    private static func writeNewJSON<T: Encodable>(_ value: T, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value) + Data([0x0A])
        } catch {
            throw MeasurementError.filesystem("JSONをencodeできません: \(error.localizedDescription)")
        }
        try requireAbsent(at: destination, description: "JSON出力先")
        let temporaryURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        let canonicalTemporaryURL = canonicalURL(temporaryURL.path)
        guard samePath(temporaryURL, canonicalTemporaryURL),
              samePath(canonicalURL(temporaryURL.deletingLastPathComponent().path), temporaryURL.deletingLastPathComponent()) else {
            throw MeasurementError.filesystem("一時JSONパスのcanonical validationに失敗しました: \(temporaryURL.path)")
        }
        try requireAbsent(at: temporaryURL, description: "一時JSONファイル")

        var ownsTemporaryFile = false
        do {
            do {
                try data.write(to: temporaryURL, options: .withoutOverwriting)
                ownsTemporaryFile = true
            } catch {
                let writeError = error
                do {
                    if !isFileWriteFileExistsError(writeError) {
                        ownsTemporaryFile = try ownedTemporaryFileExists(
                            temporaryURL,
                            expected: canonicalTemporaryURL
                        )
                    }
                } catch {
                    throw MeasurementError.cleanup(
                        operation: "一時JSONファイルを書き込めません (\(temporaryURL.path)): \(writeError.localizedDescription)",
                        cleanup: error.localizedDescription
                    )
                }
                throw MeasurementError.filesystem(
                    "一時JSONファイルを書き込めません (\(temporaryURL.path)): \(writeError.localizedDescription)"
                )
            }

            try validateOwnedTemporaryFilePath(temporaryURL, expected: canonicalTemporaryURL)
            guard samePath(canonicalURL(destination.path), destination),
                  samePath(canonicalURL(destination.deletingLastPathComponent().path), destination.deletingLastPathComponent()) else {
                throw MeasurementError.filesystem("JSON出力先のcanonical validationに失敗しました: \(destination.path)")
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            ownsTemporaryFile = false
        } catch {
            let operation = error.localizedDescription
            if ownsTemporaryFile {
                do {
                    try removeOwnedTemporaryFile(temporaryURL, expected: canonicalTemporaryURL)
                } catch {
                    throw MeasurementError.cleanup(operation: operation, cleanup: error.localizedDescription)
                }
            }
            throw MeasurementError.filesystem(operation)
        }
    }

    private static func processMemorySnapshot() throws -> ProcessMemorySnapshot {
        var counters = PROCESS_MEMORY_COUNTERS_EX()
        let counterBufferSize = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
        counters.cb = counterBufferSize
        let succeeded = withUnsafeMutablePointer(to: &counters) { pointer in
            let baseCounters = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: PROCESS_MEMORY_COUNTERS.self)
            return K32GetProcessMemoryInfo(GetCurrentProcess(), baseCounters, counterBufferSize)
        }
        guard succeeded else {
            throw MeasurementError.filesystem("K32GetProcessMemoryInfo(PROCESS_MEMORY_COUNTERS_EX) failed (GetLastError=\(GetLastError()))")
        }
        return ProcessMemorySnapshot(
            peakWorkingSetBytes: UInt64(counters.PeakWorkingSetSize),
            workingSetBytes: UInt64(counters.WorkingSetSize),
            privateUsageBytes: UInt64(counters.PrivateUsage),
            peakPagefileUsageBytes: UInt64(counters.PeakPagefileUsage),
            pageFaultCount: UInt32(counters.PageFaultCount)
        )
    }

    private static func modeDescription(_ mode: Mode) -> String {
        switch mode {
        case .current:
            "Original ONNXQwen3ASREngine initializer; no explicit session config entries."
        case .externalMapped:
            "Control only: session.use_device_allocator_for_initializers=0 and session.disable_prepacking=0 are ONNX Runtime defaults; eligible CPU external data are already mapped, so this is not claimed as a new optimization."
        case .savedPrepacked:
            "Loads previously saved prepacked graphs with external-mapped session entries; the measurement never saves or regenerates files."
        }
    }

    private static func architectureISA() throws -> String {
        #if arch(arm64)
        return "arm64-neon"
        #elseif arch(x86_64)
        return "x64"
        #else
        throw MeasurementError.invalidInput("Windows CPU prepack measurement supports only arm64-neon or x64 compile-time architectures.")
        #endif
    }

    private static func elapsedSeconds(start: UInt64, end: UInt64) throws -> Double {
        guard end >= start else {
            throw MeasurementError.invalidInput("monotonic clock moved backwards")
        }
        let seconds = Double(end - start) / 1_000_000_000
        guard seconds.isFinite, seconds >= 0 else {
            throw MeasurementError.invalidInput("monotonic timer produced an invalid duration")
        }
        return seconds
    }

    private static func requireReadable(
        _ expectedType: FileAttributeType,
        at url: URL,
        description: String
    ) throws {
        let attributes = try itemAttributes(at: url, description: description)
        guard attributes[.type] as? FileAttributeType == expectedType else {
            throw MeasurementError.invalidInput("\(description) has the wrong file type: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MeasurementError.invalidInput("\(description) is not readable: \(url.path)")
        }
    }

    private static func requireDirectory(at url: URL, description: String) throws {
        let attributes = try itemAttributes(at: url, description: description)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MeasurementError.invalidInput("\(description) is not a directory: \(url.path)")
        }
    }

    private static func requireAbsent(at url: URL, description: String) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            if isMissingItemError(error) { return }
            throw MeasurementError.filesystem("\(description) cannot be inspected (\(url.path)): \(error.localizedDescription)")
        }
        throw MeasurementError.invalidInput("\(description) already exists: \(url.path)")
    }

    private static func itemAttributes(at url: URL, description: String) throws -> [FileAttributeKey: Any] {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw MeasurementError.invalidInput("\(description) cannot be inspected (\(url.path)): \(error.localizedDescription)")
        }
    }

    private static func isMissingItemError(_ error: Error) -> Bool {
        let fileError = error as NSError
        return fileError.domain == NSCocoaErrorDomain && fileError.code == NSFileReadNoSuchFileError
    }

    private static func isFileWriteFileExistsError(_ error: Error) -> Bool {
        let fileError = error as NSError
        return fileError.domain == NSCocoaErrorDomain
            && fileError.code == CocoaError.Code.fileWriteFileExists.rawValue
    }

    private static func validateManifestDirectoryContents(at directory: URL, expectedFileNames: Set<String>) throws {
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])
        } catch {
            throw MeasurementError.filesystem("ディレクトリ内容を列挙できません (\(directory.path)): \(error.localizedDescription)")
        }
        let names = Set(items.map(\.lastPathComponent))
        guard names == expectedFileNames, items.count == expectedFileNames.count else {
            throw MeasurementError.invalidInput("derived directory contains missing or unexpected files (\(directory.path)); explicit regeneration with --action save is required")
        }
    }

    private static func requireRegularNonSymlinkFile(at url: URL, expectedParent: URL) throws {
        let canonical = canonicalURL(url.path)
        let expected = expectedParent.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        guard samePath(canonical, expected) else {
            throw MeasurementError.invalidInput("derived file resolves outside its directory or is a symlink: \(url.path)")
        }
        let attributes = try itemAttributes(at: url, description: "derived file")
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw MeasurementError.invalidInput("derived file is not a readable regular file: \(url.path)")
        }
    }

    private static func validateOwnedStagingPath(_ url: URL, expected: URL) throws {
        guard samePath(url, expected), samePath(canonicalURL(url.path), expected),
              samePath(canonicalURL(url.deletingLastPathComponent().path), url.deletingLastPathComponent()) else {
            throw MeasurementError.filesystem("refusing to operate on staging path after canonical path validation failed: \(url.path)")
        }
    }

    private static func removeOwnedStaging(_ url: URL, expected: URL) throws {
        try validateOwnedStagingPath(url, expected: expected)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            if isMissingItemError(error) { return }
            throw MeasurementError.filesystem("owned staging path cannot be inspected for cleanup (\(url.path)): \(error.localizedDescription)")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeasurementError.filesystem("owned staging directory cleanup failed (\(url.path)): \(error.localizedDescription)")
        }
    }

    private static func validateOwnedTemporaryFilePath(_ url: URL, expected: URL) throws {
        guard samePath(url, expected), samePath(canonicalURL(url.path), expected),
              samePath(canonicalURL(url.deletingLastPathComponent().path), url.deletingLastPathComponent()) else {
            throw MeasurementError.filesystem("refusing to operate on temporary JSON after canonical path validation failed: \(url.path)")
        }
    }

    private static func ownedTemporaryFileExists(_ url: URL, expected: URL) throws -> Bool {
        try validateOwnedTemporaryFilePath(url, expected: expected)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch {
            if isMissingItemError(error) { return false }
            throw MeasurementError.filesystem("owned temporary JSON path cannot be inspected (\(url.path)): \(error.localizedDescription)")
        }
    }

    private static func removeOwnedTemporaryFile(_ url: URL, expected: URL) throws {
        try validateOwnedTemporaryFilePath(url, expected: expected)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            if isMissingItemError(error) { return }
            throw MeasurementError.filesystem("owned temporary JSON path cannot be inspected for cleanup (\(url.path)): \(error.localizedDescription)")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeasurementError.filesystem("temporary JSON cleanup failed (\(url.path)): \(error.localizedDescription)")
        }
    }

    private static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.path.caseInsensitiveCompare(second.path) == .orderedSame
    }

    private static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        if samePath(candidate, directory) { return true }
        let parentPath = normalizedWindowsPath(directory.path)
        let candidatePath = normalizedWindowsPath(candidate.path)
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func normalizedWindowsPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").lowercased()
    }
}
#endif
