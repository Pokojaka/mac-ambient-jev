import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX

internal struct LoadedHaasModel {
    let graphs: HaasONNXGraphs
    let tokenizer: SentencePieceDecoder
}

/// 最大時間を超える音声入力は拒否し、分割して処理しません。
public actor HaasASREngine: ASREngine {
    public static let macIntraOpThreads = 4

    private nonisolated let provenanceValue: RunProvenance
    private let intraOpThreads: Int
    private let locateModel: @Sendable () async throws -> HaasASRModelFiles
    private var loaded: LoadedHaasModel?
    private var preparationTask: Task<Void, Error>?
    private var preparationGeneration: UUID?
    private var unloadCount = 0
    public private(set) var state: ASREngineState = .stopped

    public nonisolated var provenance: RunProvenance { provenanceValue }

    public init(
        intraOpThreads: Int,
        locateModel: @escaping @Sendable () async throws -> HaasASRModelFiles
    ) {
        self.intraOpThreads = intraOpThreads
        self.locateModel = locateModel
        self.provenanceValue = RunProvenance(
            engine: "onnxruntime-haas-tdt",
            model: "Sanami/haas-ja-onnx/int8dyn",
            version: "haas-ja-v1.0@354baedfd9612b00e74cc1ae87dff7f2c558db6f+onnxruntime@1.31.0",
            configuration: [
                "language": "ja",
                "decoding": "tdt-greedy",
                "max_symbols_per_frame": String(TDTGreedyDecoder.maxSymbolsPerFrame),
                "intra_op_threads": String(intraOpThreads),
                "minimum_input_seconds": String(ASRAudioInput.minimumDurationSeconds),
                "maximum_input_seconds": String(ASRAudioInput.maximumDurationSeconds),
            ]
        )
    }

    public func prepare() async throws {
        guard unloadCount == 0 else { throw CancellationError() }
        if loaded != nil {
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
            let files = try await locateModel()
            try Task.checkCancellation()
            let graphs = try HaasONNXGraphs(
                files: files,
                environment: ONNXEnvironment.shared(),
                intraOpThreads: intraOpThreads
            )
            let tokenizer = try SentencePieceDecoder(modelData: Data(contentsOf: files.tokenizer))
            guard preparationGeneration == generation else { throw CancellationError() }
            loaded = LoadedHaasModel(graphs: graphs, tokenizer: tokenizer)
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

    internal func transcribeWithTokens(_ input: ASRAudioInput) async throws -> (text: String, tokenIDs: [Int]) {
        guard input.sampleRate == Int(CanonicalAudio.sampleRate) else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        guard input.samples.count <= Int(ASRAudioInput.maximumDurationSeconds * CanonicalAudio.sampleRate) else {
            throw HaasASRError.inputTooLong(seconds: Double(input.samples.count) / CanonicalAudio.sampleRate)
        }
        guard !input.isShorterThanMinimumASRDuration else { return ("", []) }
        guard let loaded else { throw HaasASRError.notPrepared }

        state = .transcribing(segmentID: "")
        do {
            let features = HaasMelFrontend.features(of: input.samples)
            let encoded = try loaded.graphs.encode(features)
            let tokenIDs = try TDTGreedyDecoder.decode(
                frameCount: encoded.frameCount,
                joint: loaded.graphs.joint(encoded)
            )
            let text = loaded.tokenizer.decode(tokenIDs)
            state = .ready
            return (text, tokenIDs)
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
        loaded = nil
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
}
