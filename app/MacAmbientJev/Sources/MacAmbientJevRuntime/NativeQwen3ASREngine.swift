import MacAmbientJevCore
@preconcurrency import Qwen3ASR

enum NativeQwen3ASREngineError: Error {
    case notPrepared
}

actor NativeQwen3ASREngine: ASREngine {
    static let engineName = "qwen3-asr-swift"
    static let version = "speech-swift@c4c2fabbe825a9290c19e2f45d54ca3eae96b003"
    static let language = "ja"

    nonisolated var provenance: RunProvenance {
        RunProvenance(
            engine: Self.engineName,
            model: ModelStore.qwen3ASRModelID,
            version: Self.version,
            configuration: [
                "language": Self.language,
                "minimum_input_seconds": String(ASRAudioInput.minimumDurationSeconds),
            ]
        )
    }

    private let modelStore: ModelStore
    private var model: Qwen3ASRModel?
    private var preparationTask: Task<Void, Error>?
    private(set) var state: ASREngineState = .stopped

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
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
            let cacheDirectory = try modelStore.prepareQwen3ASRDirectory()
            model = try await Qwen3ASRModel.fromPretrained(
                modelId: ModelStore.qwen3ASRModelID,
                cacheDir: cacheDirectory,
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
        guard let model else {
            throw NativeQwen3ASREngineError.notPrepared
        }

        guard !input.isShorterThanMinimumASRDuration else {
            return ASRResult(text: "")
        }

        state = .transcribing(segmentID: "")
        let text = model.transcribe(
            audio: input.samples,
            sampleRate: input.sampleRate,
            language: Self.language
        )
        state = .ready

        return ASRResult(text: text, detectedLanguage: nil)
    }

    func unload() async {
        model?.unload()
        model = nil
        state = .stopped
    }
}
