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

    internal init(
        modelDirectory: URL,
        size: ASRModelSize,
        intraOpThreads: Int,
        loadModel: @escaping @Sendable (URL, ASRModelSize, Int) async throws -> any Qwen3ASRTranscribingModel
    ) {
        self.modelDirectory = modelDirectory
        self.size = size
        self.intraOpThreads = intraOpThreads
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
            let output = try model.transcribe(
                samples: input.samples,
                maxNewTokens: 448,
                noRepeatNgramSize: input.samples.count > 15 * Int(CanonicalAudio.sampleRate) ? 3 : nil
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
