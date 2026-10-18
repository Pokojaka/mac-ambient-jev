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
