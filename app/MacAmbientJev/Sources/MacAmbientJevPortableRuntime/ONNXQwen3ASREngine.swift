import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX

internal enum ONNXQwen3ASREngineError: Error, LocalizedError, Equatable {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "ONNX Qwen3-ASR エンジンは準備されていません。先に prepare() を実行してください。"
        }
    }
}

public actor ONNXQwen3ASREngine: ASREngine {
    private nonisolated let provenanceValue: RunProvenance
    private let modelDirectory: URL
    private let size: ASRModelSize
    private let intraOpThreads: Int
    private let fixedDecoding: (maxNewTokens: Int, noRepeatNgramSize: Int?)?
    private let loadModel: @Sendable (URL, ASRModelSize, Int) async throws -> any Qwen3ASRTranscribingModel

    private var model: (any Qwen3ASRTranscribingModel)?
    private var preparationTask: Task<Void, Error>?
    private var preparationGeneration: UUID?
    private var unloadCount = 0
    internal var activeUnloadCountForTesting: Int { unloadCount }
    public private(set) var state: ASREngineState = .stopped

    public nonisolated var provenance: RunProvenance {
        provenanceValue
    }

    public init(modelDirectory: URL, size: ASRModelSize, intraOpThreads: Int) {
        self.modelDirectory = modelDirectory
        self.size = size
        self.intraOpThreads = intraOpThreads
        self.fixedDecoding = nil
        self.loadModel = { directory, modelSize, threadCount in
            try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                try Qwen3ASRONNXModel(
                    modelDirectory: directory,
                    size: modelSize,
                    intraOpThreads: threadCount
                )
            }.value
        }
        self.provenanceValue = Self.makeProvenance(size: size, intraOpThreads: intraOpThreads)
    }

    public init(modelDirectory: URL, size: ASRModelSize, intraOpThreads: Int,
                device: ONNXProviderDevice, language: String, maxNewTokens: Int,
                noRepeatNgramSize: Int?) throws {
        guard language == "ja" else { throw Qwen3ASRModelError.invalid("Unsupported Qwen3-ASR language '\(language)'; the pinned prompt supports only 'ja'.") }
        guard maxNewTokens > 0 else { throw Qwen3ASRModelError.invalid("maxNewTokens must be positive: \(maxNewTokens)") }
        if let noRepeatNgramSize, noRepeatNgramSize <= 0 {
            throw Qwen3ASRModelError.invalid("noRepeatNgramSize must be positive when specified: \(noRepeatNgramSize)")
        }
        self.modelDirectory = modelDirectory
        self.size = size
        self.intraOpThreads = intraOpThreads
        self.fixedDecoding = (maxNewTokens, noRepeatNgramSize)
        self.loadModel = { directory, modelSize, threadCount in
            try await Task.detached(executorPreference: BlockingIOExecutor.shared) {
                try Qwen3ASRONNXModel(modelDirectory: directory, size: modelSize, intraOpThreads: threadCount, device: device)
            }.value
        }
        let base = Self.makeProvenance(size: size, intraOpThreads: intraOpThreads)
        var configuration = base.configuration
        configuration.updateValue(device.epName, forKey: "execution_provider")
        configuration.updateValue(device.deviceKey, forKey: "device")
        configuration.updateValue("cpu_arena_disabled_strict_ep", forKey: "memory_policy")
        configuration.updateValue(language, forKey: "language")
        configuration.updateValue(String(maxNewTokens), forKey: "max_new_tokens")
        configuration.updateValue(noRepeatNgramSize.map { String($0) } ?? "disabled", forKey: "no_repeat_ngram")
        self.provenanceValue = RunProvenance(engine: base.engine, model: base.model, version: base.version, configuration: configuration)
    }

    internal init(
        modelDirectory: URL,
        size: ASRModelSize,
        intraOpThreads: Int,
        loadModel: @escaping @Sendable (URL, ASRModelSize, Int) async throws -> any Qwen3ASRTranscribingModel
    ) {
        self.modelDirectory = modelDirectory
        self.size = size
        self.intraOpThreads = intraOpThreads
        self.fixedDecoding = nil
        self.loadModel = loadModel
        self.provenanceValue = Self.makeProvenance(size: size, intraOpThreads: intraOpThreads)
    }

    public func prepare() async throws {
        guard unloadCount == 0 else {
            throw CancellationError()
        }
        if model != nil {
            state = .ready
            return
        }

        if let preparationTask {
            try await preparationTask.value
            return
        }

        let generation = UUID()
        preparationGeneration = generation
        state = .loadingModel

        let task = Task<Void, Error> {
            try Task.checkCancellation()
            let loadedModel = try await loadModel(modelDirectory, size, intraOpThreads)
            guard preparationGeneration == generation else {
                throw CancellationError()
            }
            model = loadedModel
            state = .ready
        }
        preparationTask = task

        do {
            try await task.value
            if preparationGeneration == generation {
                preparationTask = nil
                preparationGeneration = nil
            }
        } catch {
            if preparationGeneration == generation {
                preparationTask = nil
                preparationGeneration = nil
                state = .failed(message: error.localizedDescription)
            }
            throw error
        }
    }

    public func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        let output = try await transcribeWithTokens(input)
        return ASRResult(text: output.text, detectedLanguage: nil)
    }

    internal func transcribeWithTokens(_ input: ASRAudioInput) async throws -> Qwen3ASRTranscription {
        guard input.sampleRate == Int(CanonicalAudio.sampleRate) else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        guard let model else {
            throw ONNXQwen3ASREngineError.notPrepared
        }
        guard !input.isShorterThanMinimumASRDuration else {
            return Qwen3ASRTranscription(text: "", generatedIDs: [])
        }

        state = .transcribing(segmentID: "")
        do {
            let maxNewTokens: Int
            let noRepeatNgramSize: Int?
            if let fixedDecoding {
                maxNewTokens = fixedDecoding.maxNewTokens
                noRepeatNgramSize = fixedDecoding.noRepeatNgramSize
            } else {
                maxNewTokens = 448
                noRepeatNgramSize = input.samples.count > 15 * Int(CanonicalAudio.sampleRate) ? 3 : nil
            }
            let output = try model.transcribe(
                samples: input.samples,
                maxNewTokens: maxNewTokens,
                noRepeatNgramSize: noRepeatNgramSize
            )
            state = .ready
            return output
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    public func unload() async {
        unloadCount += 1
        defer { unloadCount -= 1 }

        let pendingTask = preparationTask
        preparationGeneration = nil
        model = nil
        state = .stopped

        guard let pendingTask else { return }
        pendingTask.cancel()
        do {
            try await pendingTask.value
        } catch {
            // Unload owns cleanup; callers awaiting preparation still receive its error.
        }
        preparationTask = nil
    }

    private nonisolated static func makeProvenance(
        size: ASRModelSize,
        intraOpThreads: Int
    ) -> RunProvenance {
        RunProvenance(
            engine: "onnxruntime-qwen3-asr",
            model: "\(size.repository)@\(size.commit)",
            version: "onnxruntime-\(ONNXEnvironment.runtimeVersion)",
            configuration: [
                "asr_size": size.rawValue,
                "execution_provider": "cpu",
                "device": "cpu",
                "gpu_name": nil,
                "driver_version": nil,
                "adapter_id": nil,
                "device_id": nil,
                "ep_package_hash": nil,
                "ep_library_hash": nil,
                "verification_id": nil,
                "calibration_id": nil,
                "memory_policy": "cpu_arena_disabled",
                "language": "ja",
                "minimum_input_seconds": String(ASRAudioInput.minimumDurationSeconds),
                "quantization": "int4",
                "mel_variant": "whisper-slaney-128-nfft400-hop160-reflect-global-log10",
                "max_new_tokens": "448",
                "no_repeat_ngram": "3 when input_seconds > 15; disabled otherwise",
                "intra_op_threads": String(intraOpThreads),
                "inter_op_threads": String(ONNXSession.interOpThreads),
                "cpu_memory_arena": String(Qwen3ASRONNXModel.cpuMemoryArenaEnabled),
            ]
        )
    }
}
