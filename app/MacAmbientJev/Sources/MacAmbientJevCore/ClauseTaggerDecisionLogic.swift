import Foundation

public enum ClauseTaggerDecisionLogic {
    public static func assessBoundaries(
        _ request: ClauseBoundaryRequest,
        tokenizer: ClauseTaggerTokenizer,
        predict: (_ inputIDs: [Int]) throws -> ClauseTaggerPrediction
    ) throws -> ClauseBoundaryResponse {
        try Task.checkCancellation()

        let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
            try tokenizer.encodePiece(piece)
        }

        let continuationInput: ClauseTaggerEncodedInput?
        if request.next == nil {
            continuationInput = nil
        } else {
            let encoded = try ClauseTaggerEncoding.continuationInput(request) { piece in
                try tokenizer.encodePiece(piece)
            }
            continuationInput = encoded
        }

        var candidateProbabilities: [String: Double] = [:]
        var spanPredictions: [(ordinal: Int, range: TextUTF16Range, probabilities: [Double])] = []
        var spanOrdinals = Set<Int>()
        for encoded in boundaryInputs {
            try Task.checkCancellation()
            let prediction = try predict(encoded.inputIDs)
            guard encoded.contentStartTokenIndex >= 0,
                  encoded.sourceTokenRanges.count == encoded.inputIDs.count,
                  prediction.spanProbabilities.count == encoded.inputIDs.count else {
                throw ClauseTaggerModelError.invalidOutput
            }
            for tokenIndex in encoded.spanTokenIndices {
                guard tokenIndex > 0,
                      encoded.inputIDs.indices.contains(tokenIndex),
                      encoded.sourceTokenRanges.indices.contains(tokenIndex),
                      prediction.spanProbabilities.indices.contains(tokenIndex),
                      let range = encoded.sourceTokenRanges[tokenIndex] else {
                    throw ClauseTaggerModelError.invalidOutput
                }
                let probabilities = prediction.spanProbabilities[tokenIndex]
                guard probabilities.count == 4 else {
                    throw ClauseTaggerModelError.invalidOutput
                }
                let (ordinal, overflow) = encoded.contentStartTokenIndex
                    .addingReportingOverflow(tokenIndex - 1)
                guard !overflow, spanOrdinals.insert(ordinal).inserted else {
                    throw ClauseTaggerModelError.invalidOutput
                }
                spanPredictions.append((ordinal: ordinal, range: range, probabilities: probabilities))
            }
            for candidate in request.candidates {
                guard let tokenIndex = encoded.candidateTokenIndices[candidate.offsetUTF16] else {
                    continue
                }
                guard prediction.boundaryProbabilities.indices.contains(tokenIndex) else {
                    throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
                }
                let probabilities = prediction.boundaryProbabilities[tokenIndex]
                guard probabilities.count == 2 else {
                    throw ClauseTaggerModelError.invalidOutput
                }
                candidateProbabilities[candidate.id] = probabilities[1]
            }
        }
        for candidate in request.candidates where candidateProbabilities[candidate.id] == nil {
            throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
        }

        spanPredictions.sort { $0.ordinal < $1.ordinal }
        let removalRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: request.text,
            tokenRanges: spanPredictions.map { $0.range },
            spanProbabilities: spanPredictions.map { $0.probabilities }
        )

        var continuationProbability: Double?
        if let encoded = continuationInput {
            try Task.checkCancellation()
            guard let junctionIndex = encoded.junctionIndex else {
                throw ClauseTaggerEncodingError.missingJunction
            }
            let prediction = try predict(encoded.inputIDs)
            guard prediction.boundaryProbabilities.indices.contains(junctionIndex) else {
                throw ClauseTaggerEncodingError.missingJunction
            }
            let probabilities = prediction.boundaryProbabilities[junctionIndex]
            guard probabilities.count == 2 else {
                throw ClauseTaggerModelError.invalidOutput
            }
            continuationProbability = 1 - probabilities[1]
        }

        let inputTokens = boundaryInputs.reduce(0) { $0 + $1.inputIDs.count }
            + (continuationInput?.inputIDs.count ?? 0)
        try Task.checkCancellation()
        return ClauseBoundaryResponse(
            probabilities: candidateProbabilities,
            continuationProbability: continuationProbability,
            fillerRanges: removalRanges,
            inputTokens: inputTokens
        )
    }

    public static func classifyPriorities(
        _ targets: [PriorityTextTarget],
        tokenizer: ClauseTaggerTokenizer,
        predict: (_ inputIDs: [Int]) throws -> ClauseTaggerPrediction
    ) throws -> PriorityBatchResponse {
        try Task.checkCancellation()

        guard (1...PriorityBatchPolicy.maximumTargets).contains(targets.count),
              Set(targets.map(\.key)).count == targets.count,
              targets.allSatisfy({
                  Self.isValidPriorityKey($0.key) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw ClauseValidationError.invalidTargets
        }

        let encodedInputs = try targets.map { target in
            try ClauseTaggerEncoding.encode(text: target.text) { piece in
                try tokenizer.encodePiece(piece)
            }
        }
        var decisions: [String: ContentPriorityDecision] = [:]
        var inputTokens = 0
        for (target, encoded) in zip(targets, encodedInputs) {
            try Task.checkCancellation()
            let prediction = try predict(encoded.inputIDs)
            guard prediction.priorityProbabilities.count == 2 else {
                throw ClauseTaggerModelError.invalidOutput
            }
            let primaryProbability = prediction.priorityProbabilities[0]
            let lowProbability = prediction.priorityProbabilities[1]
            let priority: ContentPriority = primaryProbability >= lowProbability ? .primary : .lowPriority
            let maximumProbability = max(primaryProbability, lowProbability)
            let decision = try ContentPriorityDecision(
                priority: priority,
                confidence: 2 * maximumProbability - 1,
                probabilities: [
                    "PRIMARY": primaryProbability,
                    "LOW_PRIORITY": lowProbability
                ]
            )
            decisions[target.key] = decision
            inputTokens += encoded.inputIDs.count
        }

        try Task.checkCancellation()
        return PriorityBatchResponse(decisions: decisions, inputTokens: inputTokens)
    }

    private static func isValidPriorityKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return bytes.count == 5 && bytes[0] == 117
            && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
            && bytes.dropFirst().contains(where: { $0 != 48 })
    }
}
