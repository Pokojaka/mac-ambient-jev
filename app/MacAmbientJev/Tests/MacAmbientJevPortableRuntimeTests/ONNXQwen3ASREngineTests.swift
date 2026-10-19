import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import Testing
@testable import MacAmbientJevPortableRuntime

@Suite(.timeLimit(.minutes(1)))
struct ONNXQwen3ASREngineTests {
    @Test
    func provenanceIsExactForEveryModelSizeAndThreadCountBeforePreparation() {
        for size in Qwen3ASRModelSize.allCases {
            for intraOpThreads in [2, 7] {
                let engine = ONNXQwen3ASREngine(
                    modelDirectory: URL(fileURLWithPath: "/not-loaded/\(size.rawValue)"),
                    size: size,
                    intraOpThreads: intraOpThreads
                )
                let provenance = engine.provenance
                #expect(provenance.engine == "onnxruntime-qwen3-asr")
                #expect(provenance.model == "\(size.repository)@\(size.commit)")
                #expect(provenance.version == "onnxruntime-\(ONNXEnvironment.runtimeVersion)")
                #expect(provenance.configuration == expectedConfiguration(intraOpThreads: intraOpThreads))
            }
        }
    }

    @Test
    func injectedInitializerProvenanceIncludesActualThreadConfiguration() {
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .large,
            intraOpThreads: 7,
            loadModel: { _, _, _ in FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "unused") }
        )

        let provenance = engine.provenance
        #expect(provenance.engine == "onnxruntime-qwen3-asr")
        #expect(provenance.model == "\(Qwen3ASRModelSize.large.repository)@\(Qwen3ASRModelSize.large.commit)")
        #expect(provenance.version == "onnxruntime-\(ONNXEnvironment.runtimeVersion)")
        #expect(provenance.configuration == expectedConfiguration(intraOpThreads: 7))
    }

    private func expectedConfiguration(intraOpThreads: Int) -> [String: String] {
        [
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
    }

    @Test
    func sampleRateIsCheckedBeforePreparedStateAndEmptyInputIsNotPrepared() async throws {
        let engine = makeEngine(model: FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "unused"))

        do {
            _ = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 48_000))
            Issue.record("Noncanonical sample rate should fail before the prepared-state check")
        } catch let error as CanonicalAudioError {
            if case .noncanonicalFormat = error {
                // Expected.
            } else {
                Issue.record("Expected noncanonicalFormat, got \(error)")
            }
        } catch {
            Issue.record("Expected CanonicalAudioError, got \(error)")
        }

        await #expect(throws: ONNXQwen3ASREngineError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 16_000))
        }
    }

    @Test
    func shortPreparedInputSkipsInferenceAndExactMinimumRuns() async throws {
        let recorder = ModelCallRecorder()
        let engine = makeEngine(model: FakeQwen3ASRModel(recorder: recorder, text: "recognized"))
        try await engine.prepare()

        let empty = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 16_000))
        #expect(empty == ASRResult(text: "", detectedLanguage: nil))
        #expect(recorder.calls.isEmpty)

        let short = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 319), sampleRate: 16_000)
        )
        #expect(short == ASRResult(text: "", detectedLanguage: nil))
        #expect(recorder.calls.isEmpty)

        let exactMinimum = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000)
        )
        #expect(exactMinimum == ASRResult(text: "recognized", detectedLanguage: nil))
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].sampleCount == 320)
        #expect(recorder.calls[0].maxNewTokens == 448)
        #expect(recorder.calls[0].noRepeatNgramSize == nil)
    }

    @Test
    func internalTranscriptionPreservesGeneratedTokensAndSkipsShortInput() async throws {
        let recorder = ModelCallRecorder()
        let engine = makeEngine(model: FakeQwen3ASRModel(recorder: recorder, text: "recognized"))
        try await engine.prepare()

        let short = try await engine.transcribeWithTokens(
            ASRAudioInput(samples: Array(repeating: 0, count: 319), sampleRate: 16_000)
        )
        #expect(short == Qwen3ASRTranscription(text: "", generatedIDs: []))
        #expect(recorder.calls.isEmpty)

        let result = try await engine.transcribeWithTokens(
            ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000)
        )
        #expect(result == Qwen3ASRTranscription(text: "recognized", generatedIDs: [42, 151645]))
        #expect(recorder.calls.count == 1)
    }

    @Test
    func ngramRuleUsesStrictlyMoreThanFifteenSecondsAndForwardsTokenCap() async throws {
        let recorder = ModelCallRecorder()
        let engine = makeEngine(model: FakeQwen3ASRModel(recorder: recorder, text: "recognized"))
        try await engine.prepare()

        _ = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 15 * 16_000), sampleRate: 16_000)
        )
        _ = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 15 * 16_000 + 1), sampleRate: 16_000)
        )

        #expect(recorder.calls.map(\.sampleCount) == [240_000, 240_001])
        #expect(recorder.calls.map(\.maxNewTokens) == [448, 448])
        #expect(recorder.calls.map(\.noRepeatNgramSize) == [nil, 3])
        #expect(await engine.state == .ready)
    }

    @Test
    func concurrentPreparationSharesOneLoad() async throws {
        let recorder = ModelCallRecorder()
        let model = FakeQwen3ASRModel(recorder: recorder, text: "ready")
        let gate = ModelLoadGate()
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .small,
            intraOpThreads: 3,
            loadModel: { _, _, _ in try await gate.load() }
        )

        let first = Task { try await engine.prepare() }
        await gate.waitUntilStarted(count: 1)
        let second = Task { try await engine.prepare() }
        await Task.yield()
        await gate.succeedNext(with: model)

        try await first.value
        try await second.value
        #expect(await gate.startedCount() == 1)
        #expect(await engine.state == .ready)
    }

    @Test
    func preparationForwardsModelDirectorySizeAndThreadCount() async throws {
        let directory = URL(fileURLWithPath: "/configured/qwen3-asr", isDirectory: true)
        let arguments = ModelLoadArgumentsRecorder()
        let model = FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "loaded")
        let engine = ONNXQwen3ASREngine(
            modelDirectory: directory,
            size: .large,
            intraOpThreads: 7,
            loadModel: { passedDirectory, passedSize, passedThreadCount in
                await arguments.record(
                    ModelLoadArguments(
                        directory: passedDirectory,
                        size: passedSize,
                        intraOpThreads: passedThreadCount
                    )
                )
                return model
            }
        )

        try await engine.prepare()

        #expect(await arguments.values() == [ModelLoadArguments(
            directory: directory,
            size: .large,
            intraOpThreads: 7
        )])
    }

    @Test
    func unloadRevokesSuspendedPreparationAndWaitsForItsCompletion() async throws {
        let recorder = ModelCallRecorder()
        let model = FakeQwen3ASRModel(recorder: recorder, text: "must-not-install")
        let gate = ModelLoadGate()
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .large,
            intraOpThreads: 4,
            loadModel: { _, _, _ in try await gate.load() }
        )

        let preparation = Task { try await engine.prepare() }
        await gate.waitUntilStarted(count: 1)
        #expect(await engine.state == .loadingModel)

        let unloading = Task { await engine.unload() }
        while await engine.state != .stopped {
            await Task.yield()
        }
        await gate.succeedNext(with: model)
        await unloading.value

        await #expect(throws: CancellationError.self) {
            try await preparation.value
        }
        #expect(await engine.state == .stopped)
        await #expect(throws: ONNXQwen3ASREngineError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 16_000))
        }
        #expect(await gate.startedCount() == 1)
    }

    @Test
    func simultaneousUnloadsBothWaitForThePendingLoad() async throws {
        let model = FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "must-not-install")
        let gate = ModelLoadGate()
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .large,
            intraOpThreads: 4,
            loadModel: { _, _, _ in try await gate.load() }
        )
        let preparation = Task { try await engine.prepare() }
        await gate.waitUntilStarted(count: 1)

        let completions = UnloadCompletionRecorder()
        let firstUnload = Task {
            await engine.unload()
            await completions.recordCompletion()
        }
        while await engine.activeUnloadCountForTesting != 1 {
            await Task.yield()
        }
        let secondUnload = Task {
            await engine.unload()
            await completions.recordCompletion()
        }

        while true {
            let activeUnloads = await engine.activeUnloadCountForTesting
            let completedUnloads = await completions.count()
            if activeUnloads == 2 || completedUnloads > 0 {
                break
            }
            await Task.yield()
        }
        #expect(await engine.activeUnloadCountForTesting == 2)
        #expect(await completions.count() == 0)

        await gate.succeedNext(with: model)
        await firstUnload.value
        await secondUnload.value
        await #expect(throws: CancellationError.self) {
            try await preparation.value
        }
        #expect(await completions.count() == 2)
        #expect(await engine.state == .stopped)
    }

    @Test
    func failedPreparationCanBeRetried() async throws {
        let recorder = ModelCallRecorder()
        let model = FakeQwen3ASRModel(recorder: recorder, text: "retry")
        let loader = RetryModelLoader(model: model)
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .small,
            intraOpThreads: 1,
            loadModel: { _, _, _ in try await loader.load() }
        )

        do {
            try await engine.prepare()
            Issue.record("The first model load should fail")
        } catch RetryModelLoader.LoadError.firstAttempt {
            // Expected.
        } catch {
            Issue.record("Unexpected first preparation error: \(error)")
        }
        if case .failed = await engine.state {
            // Expected.
        } else {
            Issue.record("A failed preparation must expose failed state")
        }

        try await engine.prepare()
        #expect(await loader.callCount() == 2)
        #expect(await engine.state == .ready)
        let result = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000)
        )
        #expect(result.text == "retry")
    }

    @Test
    func inferenceFailureMarksFailedAndKeepsPreparedModelForRetry() async throws {
        let recorder = ModelCallRecorder()
        let model = RetryTranscriptionModel(recorder: recorder)
        let engine = makeEngine(model: model)
        try await engine.prepare()

        await #expect(throws: RetryTranscriptionModel.TranscriptionError.firstAttempt) {
            _ = try await engine.transcribe(
                ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000)
            )
        }
        if case .failed = await engine.state {
            // Expected.
        } else {
            Issue.record("An inference failure must expose failed state")
        }

        let result = try await engine.transcribe(
            ASRAudioInput(samples: Array(repeating: 0, count: 320), sampleRate: 16_000)
        )
        #expect(result.text == "retry")
        #expect(await engine.state == .ready)
        #expect(recorder.calls.count == 2)
    }

    @Test
    func unloadAfterPreparationMakesTranscriptionNotPrepared() async throws {
        let model = FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "unloaded")
        let engine = makeEngine(model: model)
        try await engine.prepare()

        await engine.unload()

        #expect(await engine.state == .stopped)
        await #expect(throws: ONNXQwen3ASREngineError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 16_000))
        }
    }

    @Test
    func unloadReleasesPreparedModel() async throws {
        var model: FakeQwen3ASRModel? = FakeQwen3ASRModel(
            recorder: ModelCallRecorder(),
            text: "weakly-held"
        )
        let weakReference = WeakFakeQwen3ASRModelReference(model)
        let engine = ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .small,
            intraOpThreads: 2,
            loadModel: { _, _, _ in
                guard let model = weakReference.model else {
                    throw WeakFakeQwen3ASRModelReference.Error.modelReleasedBeforeLoad
                }
                return model
            }
        )
        try await engine.prepare()
        #expect(weakReference.model != nil)

        model = nil
        await engine.unload()

        #expect(weakReference.model == nil)
    }

    @Test
    func unloadWhenUnpreparedLeavesStoppedState() async throws {
        let engine = makeEngine(model: FakeQwen3ASRModel(recorder: ModelCallRecorder(), text: "unused"))
        await engine.unload()
        #expect(await engine.state == .stopped)
        await #expect(throws: ONNXQwen3ASREngineError.notPrepared) {
            _ = try await engine.transcribe(ASRAudioInput(samples: [], sampleRate: 16_000))
        }
    }

    @Test
    func realLoaderReportsMissingEmptyAndTruncatedModelPaths() async throws {
        let directory = try makeTemporaryDirectory()
        verifyResolvedTemporaryPath(directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingDirectory = directory.appendingPathComponent("missing", isDirectory: true)
        verifyResolvedTemporaryPath(missingDirectory)
        #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))
        let missingMessage = await preparationError(
            for: ONNXQwen3ASREngine(modelDirectory: missingDirectory, size: .small, intraOpThreads: 1)
        )
        #expect(missingMessage.contains(missingDirectory.path))

        let emptyDirectory = directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: false)
        verifyResolvedTemporaryPath(emptyDirectory)
        let emptyFilePath = emptyDirectory.appendingPathComponent(Qwen3ASRModelSize.small.files[0].name).path
        let emptyMessage = await preparationError(
            for: ONNXQwen3ASREngine(modelDirectory: emptyDirectory, size: .small, intraOpThreads: 1)
        )
        #expect(emptyMessage.contains(emptyFilePath))

        let truncatedDirectory = directory.appendingPathComponent("truncated", isDirectory: true)
        try FileManager.default.createDirectory(at: truncatedDirectory, withIntermediateDirectories: false)
        verifyResolvedTemporaryPath(truncatedDirectory)
        let encoder = Qwen3ASRModelSize.small.files[0]
        let encoderURL = truncatedDirectory.appendingPathComponent(encoder.name)
        try Data([0]).write(to: encoderURL)
        let truncatedMessage = await preparationError(
            for: ONNXQwen3ASREngine(modelDirectory: truncatedDirectory, size: .small, intraOpThreads: 1)
        )
        #expect(truncatedMessage.contains(encoderURL.path))
        #expect(truncatedMessage.contains("期待値: \(encoder.byteCount) bytes"))
        #expect(truncatedMessage.contains("実際: 1 bytes"))
    }

    private func makeEngine(model: any Qwen3ASRTranscribingModel) -> ONNXQwen3ASREngine {
        ONNXQwen3ASREngine(
            modelDirectory: URL(fileURLWithPath: "/injected-model"),
            size: .small,
            intraOpThreads: 2,
            loadModel: { _, _, _ in model }
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONNXQwen3ASREngineTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func verifyResolvedTemporaryPath(_ url: URL) {
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(url.isFileURL)
        #expect(url.standardizedFileURL.path.hasPrefix(temporaryRoot + "/"))
    }

    private func preparationError(for engine: ONNXQwen3ASREngine) async -> String {
        do {
            try await engine.prepare()
            Issue.record("Preparation should fail for an invalid model directory")
            return ""
        } catch {
            return error.localizedDescription
        }
    }
}

private struct ModelLoadArguments: Sendable, Equatable {
    let directory: URL
    let size: Qwen3ASRModelSize
    let intraOpThreads: Int
}

private actor ModelLoadArgumentsRecorder {
    private var recorded: [ModelLoadArguments] = []

    func record(_ arguments: ModelLoadArguments) {
        recorded.append(arguments)
    }

    func values() -> [ModelLoadArguments] {
        recorded
    }
}

private actor UnloadCompletionRecorder {
    private var completions = 0

    func recordCompletion() {
        completions += 1
    }

    func count() -> Int {
        completions
    }
}

private final class WeakFakeQwen3ASRModelReference: @unchecked Sendable {
    enum Error: Swift.Error {
        case modelReleasedBeforeLoad
    }

    weak var model: FakeQwen3ASRModel?

    init(_ model: FakeQwen3ASRModel?) {
        self.model = model
    }
}

private struct TranscriptionCall: Sendable, Equatable {
    let sampleCount: Int
    let maxNewTokens: Int
    let noRepeatNgramSize: Int?
}

private final class ModelCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptionCall] = []

    var calls: [TranscriptionCall] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ call: TranscriptionCall) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(call)
    }
}

private final class FakeQwen3ASRModel: Qwen3ASRTranscribingModel, @unchecked Sendable {
    private let recorder: ModelCallRecorder
    private let text: String

    init(recorder: ModelCallRecorder, text: String) {
        self.recorder = recorder
        self.text = text
    }

    func transcribe(samples: [Float], maxNewTokens: Int, noRepeatNgramSize: Int?) throws -> Qwen3ASRTranscription {
        recorder.append(
            TranscriptionCall(
                sampleCount: samples.count,
                maxNewTokens: maxNewTokens,
                noRepeatNgramSize: noRepeatNgramSize
            )
        )
        return Qwen3ASRTranscription(text: text, generatedIDs: [42, 151645])
    }
}

private actor ModelLoadGate {
    private var pending: [CheckedContinuation<any Qwen3ASRTranscribingModel, any Error>] = []
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var loadCount = 0

    func load() async throws -> any Qwen3ASRTranscribingModel {
        loadCount += 1
        resumeStartedWaiters()
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any Qwen3ASRTranscribingModel, any Error>) in
            pending.append(continuation)
        }
    }

    func waitUntilStarted(count: Int) async {
        if loadCount >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func succeedNext(with model: any Qwen3ASRTranscribingModel) {
        let continuation = pending.removeFirst()
        continuation.resume(returning: model)
    }

    func startedCount() -> Int {
        loadCount
    }

    private func resumeStartedWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in startWaiters {
            if loadCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        startWaiters = remaining
    }
}

private actor RetryModelLoader {
    enum LoadError: Error {
        case firstAttempt
    }

    private let model: any Qwen3ASRTranscribingModel
    private var attempts = 0

    init(model: any Qwen3ASRTranscribingModel) {
        self.model = model
    }

    func load() throws -> any Qwen3ASRTranscribingModel {
        attempts += 1
        if attempts == 1 {
            throw LoadError.firstAttempt
        }
        return model
    }

    func callCount() -> Int {
        attempts
    }
}

private final class RetryTranscriptionModel: Qwen3ASRTranscribingModel, @unchecked Sendable {
    enum TranscriptionError: Error {
        case firstAttempt
    }

    private let recorder: ModelCallRecorder
    private let lock = NSLock()
    private var attempts = 0

    init(recorder: ModelCallRecorder) {
        self.recorder = recorder
    }

    func transcribe(samples: [Float], maxNewTokens: Int, noRepeatNgramSize: Int?) throws -> Qwen3ASRTranscription {
        recorder.append(
            TranscriptionCall(
                sampleCount: samples.count,
                maxNewTokens: maxNewTokens,
                noRepeatNgramSize: noRepeatNgramSize
            )
        )
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        if attempts == 1 {
            throw TranscriptionError.firstAttempt
        }
        return Qwen3ASRTranscription(text: "retry", generatedIDs: [43, 151645])
    }
}
