protocol Qwen3ASRDecoderModel {
    associatedtype Cache

    /// Prefills the prompt at positions `0..<promptIDs.count`; `positionIDs` are not passed separately.
    func prefill(promptIDs: [Int64], audioOffset: Int64) throws -> (lastLogits: [Float], cache: Cache)

    /// Looks up the token embedding for `tokenID` before running the one-token decoder step.
    func step(tokenID: Int64, position: Int64, cache: Cache) throws -> (logits: [Float], cache: Cache)
}

enum Qwen3ASRGenerationEnd: Equatable {
    case stopToken(Int64)
    case tokenCap
}

struct Qwen3ASRGenerationResult: Equatable {
    let generatedIDs: [Int64]
    let end: Qwen3ASRGenerationEnd

    var endedAtTokenCap: Bool {
        end == .tokenCap
    }
}

enum Qwen3ASRGenerationError: Error, Equatable, CustomStringConvertible {
    case emptyPrompt
    case invalidAudioOffset(Int64)
    case invalidTokenCap(Int)
    case unsupportedNgramSize(Int)
    case emptyLogits
    case nanLogit(Int)
    case positionOverflow

    var description: String {
        switch self {
        case .emptyPrompt:
            "decoder prompt must not be empty"
        case let .invalidAudioOffset(offset):
            "audio offset must be within the prompt: \(offset)"
        case let .invalidTokenCap(cap):
            "maximum new-token count must be positive: \(cap)"
        case let .unsupportedNgramSize(size):
            "no-repeat n-gram size is unsupported: \(size)"
        case .emptyLogits:
            "decoder returned an empty logits vector"
        case let .nanLogit(index):
            "decoder returned NaN at logits index \(index)"
        case .positionOverflow:
            "decoder token position overflows Int64"
        }
    }
}

struct Qwen3ASRGreedyDecoder<Model: Qwen3ASRDecoderModel> {
    let model: Model

    init(model: Model) {
        self.model = model
    }

    func generate(
        promptIDs: [Int64],
        audioOffset: Int64,
        maxNewTokens: Int,
        noRepeatNgramSize: Int?
    ) throws -> Qwen3ASRGenerationResult {
        guard !promptIDs.isEmpty else { throw Qwen3ASRGenerationError.emptyPrompt }
        guard let promptCount = Int64(exactly: promptIDs.count),
              audioOffset >= 0, audioOffset < promptCount
        else {
            throw Qwen3ASRGenerationError.invalidAudioOffset(audioOffset)
        }
        guard maxNewTokens > 0 else { throw Qwen3ASRGenerationError.invalidTokenCap(maxNewTokens) }
        if let noRepeatNgramSize, noRepeatNgramSize != 3 {
            throw Qwen3ASRGenerationError.unsupportedNgramSize(noRepeatNgramSize)
        }
        let (_, positionOverflow) = promptCount.addingReportingOverflow(Int64(maxNewTokens - 1))
        guard !positionOverflow else { throw Qwen3ASRGenerationError.positionOverflow }

        var (logits, cache) = try model.prefill(promptIDs: promptIDs, audioOffset: audioOffset)
        var generatedIDs: [Int64] = []

        for _ in 0..<maxNewTokens {
            let tokenID = try Self.argmax(logits, generatedIDs: generatedIDs, noRepeatTrigram: noRepeatNgramSize == 3)
            generatedIDs.append(tokenID)

            if Qwen3ASRToken.stopTokens.contains(tokenID) {
                return Qwen3ASRGenerationResult(generatedIDs: generatedIDs, end: .stopToken(tokenID))
            }
            if generatedIDs.count == maxNewTokens {
                return Qwen3ASRGenerationResult(generatedIDs: generatedIDs, end: .tokenCap)
            }

            let position = promptCount + Int64(generatedIDs.count - 1)
            (logits, cache) = try model.step(tokenID: tokenID, position: position, cache: cache)
        }

        preconditionFailure("generation loop ended without reaching a stop token or the token cap")
    }

    private static func argmax(
        _ logits: [Float],
        generatedIDs: [Int64],
        noRepeatTrigram: Bool
    ) throws -> Int64 {
        guard !logits.isEmpty else { throw Qwen3ASRGenerationError.emptyLogits }
        for (index, logit) in logits.enumerated() where logit.isNaN {
            throw Qwen3ASRGenerationError.nanLogit(index)
        }

        var scores = logits
        if noRepeatTrigram, generatedIDs.count >= 3 {
            let prefixFirst = generatedIDs[generatedIDs.count - 2]
            let prefixSecond = generatedIDs[generatedIDs.count - 1]
            for index in 0...(generatedIDs.count - 3) {
                guard generatedIDs[index] == prefixFirst,
                      generatedIDs[index + 1] == prefixSecond,
                      let maskedIndex = Int(exactly: generatedIDs[index + 2]),
                      scores.indices.contains(maskedIndex)
                else {
                    continue
                }
                scores[maskedIndex] = -.infinity
            }
        }

        var bestIndex = 0
        var bestScore = scores[0]
        for index in 1..<scores.count where scores[index] > bestScore {
            bestIndex = index
            bestScore = scores[index]
        }
        return Int64(bestIndex)
    }
}
