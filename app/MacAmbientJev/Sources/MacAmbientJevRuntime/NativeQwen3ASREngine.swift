import MacAmbientJevCore
@preconcurrency import Qwen3ASR

enum NativeQwen3ASREngineError: Error {
    case notPrepared
}

actor NativeQwen3ASREngine: ASREngine {
    private let modelStore: ModelStore
    private var model: Qwen3ASRModel?
    private(set) var state: ASREngineState = .stopped

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func prepare() async throws {
        guard model == nil else {
            state = .ready
            return
        }

        state = .loadingModel

        do {
            let cacheDirectory = try modelStore.prepareQwen3ASRDirectory()
            model = try await Qwen3ASRModel.fromPretrained(
                modelId: ModelStore.qwen3ASRModelID,
                cacheDir: cacheDirectory
            )
            state = .ready
        } catch {
            state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard let model else {
            throw NativeQwen3ASREngineError.notPrepared
        }

        state = .transcribing(segmentID: "")
        let text = model.transcribe(
            audio: input.samples,
            sampleRate: input.sampleRate
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