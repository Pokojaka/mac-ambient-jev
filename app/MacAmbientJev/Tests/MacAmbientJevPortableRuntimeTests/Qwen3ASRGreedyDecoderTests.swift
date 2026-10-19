import Testing
@testable import MacAmbientJevPortableRuntime

private final class ScriptedQwen3ASRModel: Qwen3ASRDecoderModel {
    struct StepCall: Equatable {
        let tokenID: Int64
        let position: Int64
        let cache: Int
    }

    enum ModelError: Error, Equatable {
        case prefillFailure
        case stepFailure
        case missingStepLogits
    }

    let prefillLogits: [Float]
    let stepLogits: [[Float]]
    let initialCache: Int
    let failPrefill: Bool
    let failAtStep: Int?

    private(set) var prefillCount = 0
    private(set) var receivedPromptIDs: [Int64]?
    private(set) var receivedAudioOffset: Int64?
    private(set) var steps: [StepCall] = []

    init(
        prefillLogits: [Float],
        stepLogits: [[Float]],
        initialCache: Int,
        failPrefill: Bool,
        failAtStep: Int?
    ) {
        self.prefillLogits = prefillLogits
        self.stepLogits = stepLogits
        self.initialCache = initialCache
        self.failPrefill = failPrefill
        self.failAtStep = failAtStep
    }

    func prefill(promptIDs: [Int64], audioOffset: Int64) throws -> (lastLogits: [Float], cache: Int) {
        prefillCount += 1
        receivedPromptIDs = promptIDs
        receivedAudioOffset = audioOffset
        if failPrefill { throw ModelError.prefillFailure }
        return (prefillLogits, initialCache)
    }

    func step(tokenID: Int64, position: Int64, cache: Int) throws -> (logits: [Float], cache: Int) {
        let index = steps.count
        steps.append(StepCall(tokenID: tokenID, position: position, cache: cache))
        if failAtStep == index { throw ModelError.stepFailure }
        guard stepLogits.indices.contains(index) else { throw ModelError.missingStepLogits }
        return (stepLogits[index], cache + 1)
    }
}

private final class Qwen3ASRCacheLifetimeEvents {
    private(set) var releasedCacheIDs: [Int] = []

    func recordRelease(of cacheID: Int) {
        releasedCacheIDs.append(cacheID)
    }
}

private final class TrackedQwen3ASRCache {
    let id: Int
    private let events: Qwen3ASRCacheLifetimeEvents

    init(id: Int, events: Qwen3ASRCacheLifetimeEvents) {
        self.id = id
        self.events = events
    }

    deinit {
        events.recordRelease(of: id)
    }
}

private final class WeakTrackedQwen3ASRCache {
    weak var value: TrackedQwen3ASRCache?

    init(_ value: TrackedQwen3ASRCache) {
        self.value = value
    }
}

private final class TrackedCacheQwen3ASRModel: Qwen3ASRDecoderModel {
    struct StepObservation: Equatable {
        let inputCacheID: Int
        let liveCacheIDs: [Int]
        let releasedCacheIDs: [Int]
    }

    enum ModelError: Error, Equatable {
        case stepFailure
        case missingStepLogits
    }

    let prefillLogits: [Float]
    let stepLogits: [[Float]]
    let failAtStep: Int?

    private let events = Qwen3ASRCacheLifetimeEvents()
    private var weakCaches: [WeakTrackedQwen3ASRCache] = []
    private var nextCacheID = 0
    private(set) var stepObservations: [StepObservation] = []

    init(prefillLogits: [Float], stepLogits: [[Float]], failAtStep: Int?) {
        self.prefillLogits = prefillLogits
        self.stepLogits = stepLogits
        self.failAtStep = failAtStep
    }

    var liveCacheIDs: [Int] {
        weakCaches.compactMap { $0.value?.id }
    }

    var releasedCacheIDs: [Int] {
        events.releasedCacheIDs
    }

    func prefill(promptIDs: [Int64], audioOffset: Int64) throws -> (lastLogits: [Float], cache: TrackedQwen3ASRCache) {
        (prefillLogits, makeCache())
    }

    func step(
        tokenID: Int64,
        position: Int64,
        cache: TrackedQwen3ASRCache
    ) throws -> (logits: [Float], cache: TrackedQwen3ASRCache) {
        let stepIndex = stepObservations.count
        stepObservations.append(StepObservation(
            inputCacheID: cache.id,
            liveCacheIDs: liveCacheIDs,
            releasedCacheIDs: events.releasedCacheIDs
        ))
        if failAtStep == stepIndex { throw ModelError.stepFailure }
        guard stepLogits.indices.contains(stepIndex) else { throw ModelError.missingStepLogits }
        return (stepLogits[stepIndex], makeCache())
    }

    private func makeCache() -> TrackedQwen3ASRCache {
        let cache = TrackedQwen3ASRCache(id: nextCacheID, events: events)
        nextCacheID += 1
        weakCaches.append(WeakTrackedQwen3ASRCache(cache))
        return cache
    }
}

struct Qwen3ASRGreedyDecoderTests {
    private func logits(winning tokenID: Int, count: Int) -> [Float] {
        var scores = [Float](repeating: 0, count: count)
        scores[tokenID] = 1
        return scores
    }

    private func model(
        prefill: [Float],
        steps: [[Float]],
        cache: Int,
        failPrefill: Bool,
        failAtStep: Int?
    ) -> ScriptedQwen3ASRModel {
        ScriptedQwen3ASRModel(
            prefillLogits: prefill,
            stepLogits: steps,
            initialCache: cache,
            failPrefill: failPrefill,
            failAtStep: failAtStep
        )
    }

    @Test
    func validatesAllInputsBeforePrefill() {
        let fake = model(prefill: [1], steps: [], cache: 0, failPrefill: false, failAtStep: nil)
        let decoder = Qwen3ASRGreedyDecoder(model: fake)

        #expect(throws: Qwen3ASRGenerationError.emptyPrompt) {
            try decoder.generate(promptIDs: [], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil)
        }
        #expect(throws: Qwen3ASRGenerationError.invalidAudioOffset(-1)) {
            try decoder.generate(promptIDs: [1], audioOffset: -1, maxNewTokens: 1, noRepeatNgramSize: nil)
        }
        #expect(throws: Qwen3ASRGenerationError.invalidAudioOffset(1)) {
            try decoder.generate(promptIDs: [1], audioOffset: 1, maxNewTokens: 1, noRepeatNgramSize: nil)
        }
        #expect(throws: Qwen3ASRGenerationError.invalidTokenCap(0)) {
            try decoder.generate(promptIDs: [1], audioOffset: 0, maxNewTokens: 0, noRepeatNgramSize: nil)
        }
        #expect(throws: Qwen3ASRGenerationError.invalidTokenCap(-2)) {
            try decoder.generate(promptIDs: [1], audioOffset: 0, maxNewTokens: -2, noRepeatNgramSize: nil)
        }
        #expect(throws: Qwen3ASRGenerationError.unsupportedNgramSize(2)) {
            try decoder.generate(promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: 2)
        }
        #expect(throws: Qwen3ASRGenerationError.unsupportedNgramSize(0)) {
            try decoder.generate(promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: 0)
        }
        #expect(throws: Qwen3ASRGenerationError.positionOverflow) {
            try decoder.generate(promptIDs: [1, 2], audioOffset: 0, maxNewTokens: Int.max, noRepeatNgramSize: nil)
        }
        #expect(fake.prefillCount == 0)
    }

    @Test
    func passesPromptOffsetPositionsAndCacheThroughEachStep() throws {
        let fake = model(
            prefill: logits(winning: 2, count: 5),
            steps: [logits(winning: 3, count: 5), logits(winning: 4, count: 5)],
            cache: 41,
            failPrefill: false,
            failAtStep: nil
        )
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [10, 11, 12, 13], audioOffset: 2, maxNewTokens: 3, noRepeatNgramSize: nil
        )

        #expect(result == Qwen3ASRGenerationResult(generatedIDs: [2, 3, 4], end: .tokenCap))
        #expect(result.endedAtTokenCap)
        #expect(fake.prefillCount == 1)
        #expect(fake.receivedPromptIDs == [10, 11, 12, 13])
        #expect(fake.receivedAudioOffset == 2)
        #expect(fake.steps == [
            .init(tokenID: 2, position: 4, cache: 41),
            .init(tokenID: 3, position: 5, cache: 42),
        ])
    }

    @Test
    func eitherStopTokenEndsImmediatelyAndWinsAtTheCap() throws {
        for stopID in [Qwen3ASRToken.imEnd, Qwen3ASRToken.endOfText] {
            let fake = model(
                prefill: logits(winning: Int(stopID), count: 151_646),
                steps: [],
                cache: 0,
                failPrefill: false,
                failAtStep: nil
            )
            let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
                promptIDs: [10, 11], audioOffset: 1, maxNewTokens: 1, noRepeatNgramSize: nil
            )
            #expect(result.generatedIDs == [stopID])
            #expect(result.end == .stopToken(stopID))
            #expect(!result.endedAtTokenCap)
            #expect(fake.steps.isEmpty)
        }
    }

    @Test
    func eitherStopTokenAfterAStepIsIncludedWithoutAnotherStep() throws {
        for stopID in [Qwen3ASRToken.imEnd, Qwen3ASRToken.endOfText] {
            let fake = model(
                prefill: logits(winning: 7, count: 8),
                steps: [logits(winning: Int(stopID), count: 151_646)],
                cache: 12,
                failPrefill: false,
                failAtStep: nil
            )
            let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
                promptIDs: [10, 11], audioOffset: 1, maxNewTokens: 2, noRepeatNgramSize: nil
            )
            #expect(result.generatedIDs == [7, stopID])
            #expect(result.end == .stopToken(stopID))
            #expect(fake.steps.count == 1)
        }
    }

    @Test
    func tokenCapOneReturnsTheFirstTokenWithoutStepping() throws {
        let fake = model(prefill: [0, 4], steps: [], cache: 0, failPrefill: false, failAtStep: nil)
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [5], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil
        )
        #expect(result.generatedIDs == [1])
        #expect(result.end == .tokenCap)
        #expect(result.endedAtTokenCap)
        #expect(fake.steps.isEmpty)
    }

    @Test
    func argmaxKeepsTheLowestIndexForTiesIncludingInfinities() throws {
        let scoreCases: [[Float]] = [
            [2, 2, 1],
            [.infinity, .infinity],
            [-.infinity, -.infinity, -.infinity],
        ]
        for scores in scoreCases {
            let fake = model(prefill: scores, steps: [], cache: 0, failPrefill: false, failAtStep: nil)
            let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil
            )
            #expect(result.generatedIDs == [0])
        }
    }

    @Test
    func emptyAndNaNLogitsFailWithTheirIndices() {
        let emptyFake = model(prefill: [], steps: [], cache: 0, failPrefill: false, failAtStep: nil)
        #expect(throws: Qwen3ASRGenerationError.emptyLogits) {
            try Qwen3ASRGreedyDecoder(model: emptyFake).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil
            )
        }
        let nanFake = model(prefill: [0, .nan, 3], steps: [], cache: 0, failPrefill: false, failAtStep: nil)
        #expect(throws: Qwen3ASRGenerationError.nanLogit(1)) {
            try Qwen3ASRGreedyDecoder(model: nanFake).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil
            )
        }
    }

    @Test
    func NaNIsRejectedBeforeTrigramMasking() {
        let fake = model(
            prefill: logits(winning: 1, count: 5),
            steps: [
                logits(winning: 2, count: 5),
                logits(winning: 3, count: 5),
                logits(winning: 1, count: 5),
                logits(winning: 2, count: 5),
                [0, 0, 0, .nan, 9],
            ],
            cache: 0,
            failPrefill: false,
            failAtStep: nil
        )
        #expect(throws: Qwen3ASRGenerationError.nanLogit(3)) {
            try Qwen3ASRGreedyDecoder(model: fake).generate(
                promptIDs: [8], audioOffset: 0, maxNewTokens: 6, noRepeatNgramSize: 3
            )
        }
    }

    @Test
    func generatedThreeGramIsMaskedBeforeArgmax() throws {
        let fake = model(
            prefill: logits(winning: 1, count: 5),
            steps: [
                logits(winning: 2, count: 5),
                logits(winning: 3, count: 5),
                logits(winning: 1, count: 5),
                logits(winning: 2, count: 5),
                [0, 0, 0, 9, 8],
            ],
            cache: 0,
            failPrefill: false,
            failAtStep: nil
        )
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [9], audioOffset: 0, maxNewTokens: 6, noRepeatNgramSize: 3
        )
        #expect(result.generatedIDs == [1, 2, 3, 1, 2, 4])
    }

    @Test
    func nilNgramOptionDoesNotMaskRepeatedThreeGram() throws {
        let fake = model(
            prefill: logits(winning: 1, count: 5),
            steps: [
                logits(winning: 2, count: 5),
                logits(winning: 3, count: 5),
                logits(winning: 1, count: 5),
                logits(winning: 2, count: 5),
                [0, 0, 0, 9, 8],
            ],
            cache: 0,
            failPrefill: false,
            failAtStep: nil
        )
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [9], audioOffset: 0, maxNewTokens: 6, noRepeatNgramSize: nil
        )
        #expect(result.generatedIDs == [1, 2, 3, 1, 2, 3])
    }

    @Test
    func promptTokensDoNotParticipateInTheTrigramMask() throws {
        let fake = model(
            prefill: logits(winning: 1, count: 4),
            steps: [logits(winning: 2, count: 4), logits(winning: 3, count: 4)],
            cache: 0,
            failPrefill: false,
            failAtStep: nil
        )
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [1, 2, 3, 1, 2], audioOffset: 0, maxNewTokens: 3, noRepeatNgramSize: 3
        )
        #expect(result.generatedIDs == [1, 2, 3])
    }

    @Test
    func overlappingTrigramIsMasked() throws {
        let fake = model(
            prefill: logits(winning: 1, count: 3),
            steps: [logits(winning: 1, count: 3), logits(winning: 1, count: 3), [0, 9, 8]],
            cache: 0,
            failPrefill: false,
            failAtStep: nil
        )
        let result = try Qwen3ASRGreedyDecoder(model: fake).generate(
            promptIDs: [7], audioOffset: 0, maxNewTokens: 4, noRepeatNgramSize: 3
        )
        #expect(result.generatedIDs == [1, 1, 1, 2])
    }

    @Test
    func supersededReferenceCachesAreReleasedDuringAndAfterGeneration() throws {
        let stopID = Qwen3ASRToken.imEnd
        let stopModel = TrackedCacheQwen3ASRModel(
            prefillLogits: logits(winning: 1, count: 4),
            stepLogits: [logits(winning: 2, count: 4), logits(winning: Int(stopID), count: 151_646)],
            failAtStep: nil
        )
        let stopResult = try Qwen3ASRGreedyDecoder(model: stopModel).generate(
            promptIDs: [1], audioOffset: 0, maxNewTokens: 4, noRepeatNgramSize: nil
        )
        #expect(stopResult == Qwen3ASRGenerationResult(
            generatedIDs: [1, 2, stopID], end: .stopToken(stopID)
        ))
        #expect(stopModel.stepObservations == [
            .init(inputCacheID: 0, liveCacheIDs: [0], releasedCacheIDs: []),
            .init(inputCacheID: 1, liveCacheIDs: [1], releasedCacheIDs: [0]),
        ])
        #expect(stopModel.liveCacheIDs.isEmpty)
        #expect(stopModel.releasedCacheIDs == [0, 1, 2])

        let capModel = TrackedCacheQwen3ASRModel(
            prefillLogits: logits(winning: 1, count: 5),
            stepLogits: [
                logits(winning: 2, count: 5),
                logits(winning: 3, count: 5),
                logits(winning: 4, count: 5),
            ],
            failAtStep: nil
        )
        let capResult = try Qwen3ASRGreedyDecoder(model: capModel).generate(
            promptIDs: [1], audioOffset: 0, maxNewTokens: 4, noRepeatNgramSize: nil
        )
        #expect(capResult == Qwen3ASRGenerationResult(generatedIDs: [1, 2, 3, 4], end: .tokenCap))
        #expect(capModel.stepObservations == [
            .init(inputCacheID: 0, liveCacheIDs: [0], releasedCacheIDs: []),
            .init(inputCacheID: 1, liveCacheIDs: [1], releasedCacheIDs: [0]),
            .init(inputCacheID: 2, liveCacheIDs: [2], releasedCacheIDs: [0, 1]),
        ])
        #expect(capModel.liveCacheIDs.isEmpty)
        #expect(capModel.releasedCacheIDs == [0, 1, 2, 3])

        let failingModel = TrackedCacheQwen3ASRModel(
            prefillLogits: logits(winning: 1, count: 4),
            stepLogits: [logits(winning: 2, count: 4)],
            failAtStep: 1
        )
        #expect(throws: TrackedCacheQwen3ASRModel.ModelError.stepFailure) {
            try Qwen3ASRGreedyDecoder(model: failingModel).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 4, noRepeatNgramSize: nil
            )
        }
        #expect(failingModel.stepObservations == [
            .init(inputCacheID: 0, liveCacheIDs: [0], releasedCacheIDs: []),
            .init(inputCacheID: 1, liveCacheIDs: [1], releasedCacheIDs: [0]),
        ])
        #expect(failingModel.liveCacheIDs.isEmpty)
        #expect(failingModel.releasedCacheIDs == [0, 1])
    }

    @Test
    func modelErrorsArePropagatedUnchanged() {
        let prefillFailure = model(prefill: [1], steps: [], cache: 0, failPrefill: true, failAtStep: nil)
        #expect(throws: ScriptedQwen3ASRModel.ModelError.prefillFailure) {
            try Qwen3ASRGreedyDecoder(model: prefillFailure).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 1, noRepeatNgramSize: nil
            )
        }

        let stepFailure = model(prefill: [0, 1], steps: [], cache: 0, failPrefill: false, failAtStep: 0)
        #expect(throws: ScriptedQwen3ASRModel.ModelError.stepFailure) {
            try Qwen3ASRGreedyDecoder(model: stepFailure).generate(
                promptIDs: [1], audioOffset: 0, maxNewTokens: 2, noRepeatNgramSize: nil
            )
        }
    }
}
