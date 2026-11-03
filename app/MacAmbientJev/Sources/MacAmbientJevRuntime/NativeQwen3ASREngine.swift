import MLX
import MacAmbientJevCore
@preconcurrency import Qwen3ASR

enum NativeQwen3ASREngineError: Error {
    case notPrepared
}

actor NativeQwen3ASREngine: ASREngine {
    static let engineName = "qwen3-asr-swift"
    static let version = "speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003"
    static let language = "Japanese"

    nonisolated var provenance: RunProvenance {
        RunProvenance(
            engine: Self.engineName,
            model: models.entry(.asr).repository,
            version: Self.version,
            configuration: [
                "language": Self.language,
                "minimum_input_seconds": String(ASRAudioInput.minimumDurationSeconds),
            ]
        )
    }

    private let models: MacModelStore
    private var model: Qwen3ASRModel?
    private var preparationTask: Task<Void, Error>?
    private(set) var state: ASREngineState = .stopped

    init(models: MacModelStore) {
        self.models = models
    }

    func prepare() async throws {
        try await prepare(onProgress: { _, _ in })
    }

    func prepare(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else {
            state = .ready
            onProgress(1, "Ready")
            return
        }

        if let preparationTask {
            try await preparationTask.value
            onProgress(1, "Ready")
            return
        }

        state = .loadingModel

        let task = Task {
            let directory = try await models.verifiedDirectory(.asr)
            model = try await Qwen3ASRModel.fromPretrained(
                modelId: models.entry(.asr).repository,
                cacheDir: directory,
                offlineMode: true,
                progressHandler: onProgress
            )
            state = .ready
        }
        preparationTask = task

        do {
            try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard input.sampleRate == Int(CanonicalAudio.sampleRate) else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        guard let model else {
            throw NativeQwen3ASREngineError.notPrepared
        }

        guard !input.isShorterThanMinimumASRDuration else {
            return ASRResult(text: "", detectedLanguage: nil)
        }

        state = .transcribing(segmentID: "")
        let text = model.transcribe(
            audio: input.samples,
            sampleRate: Int(CanonicalAudio.sampleRate),
            language: Self.language
        )
        state = .ready

        return ASRResult(text: text, detectedLanguage: nil)
    }

    func unload() async {
        guard let model else { return }
        model.unload()
        self.model = nil
        Memory.clearCache()
        state = .stopped
    }
}
