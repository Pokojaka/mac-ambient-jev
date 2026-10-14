import Foundation
import MacAmbientJevCore

public actor LocalClauseTagger: DecisionProvider {
    public nonisolated let identity: ClauseTaggerModelIdentity

    private let tokenizer: ClauseTaggerTokenizer
    private let model: ClauseTaggerModel

    public init(modelDirectory: URL) throws {
        let tokenizerURL = modelDirectory.appending(path: "tokenizer.json")
        let packageURL = modelDirectory.appending(path: "ClauseTagger.mlpackage", directoryHint: .isDirectory)
        let loadedModel = try ClauseTaggerModel(packageURL: packageURL)
        let loadedTokenizer = try ClauseTaggerTokenizer(
            tokenizerURL: tokenizerURL,
            expectedSHA256: loadedModel.identity.tokenizerSHA256
        )
        tokenizer = loadedTokenizer
        model = loadedModel
        identity = loadedModel.identity
    }

    /// The model inside the app bundle, where `scripts/build_app.sh` places the pinned release asset.
    public static func bundledModelDirectory() throws -> URL {
        guard let resources = Bundle.main.resourceURL else {
            throw ClauseTaggerModelError.unavailable("アプリの Resources フォルダーを特定できません。")
        }
        return resources.appending(path: "clause-tagger", directoryHint: .isDirectory)
    }

    public func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        guard !request.candidates.isEmpty || request.next != nil else {
            throw ClauseValidationError.invalidTargets
        }

        let boundaryInputs: [ClauseTaggerEncodedInput]
        if request.candidates.isEmpty {
            boundaryInputs = []
        } else {
            boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
                try tokenizer.encodePiece(piece)
            }
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
        for encoded in boundaryInputs {
            try Task.checkCancellation()
            let prediction = try model.predict(inputIDs: encoded.inputIDs)
            for candidate in request.candidates {
                guard let tokenIndex = encoded.candidateTokenIndices[candidate.offsetUTF16] else {
                    continue
                }
                guard prediction.boundaryProbabilities.indices.contains(tokenIndex) else {
                    throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
                }
                candidateProbabilities[candidate.id] = prediction.boundaryProbabilities[tokenIndex][1]
            }
        }
        for candidate in request.candidates where candidateProbabilities[candidate.id] == nil {
            throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
        }

        var continuationProbability: Double?
        if let encoded = continuationInput {
            try Task.checkCancellation()
            guard let junctionIndex = encoded.junctionIndex else {
                throw ClauseTaggerEncodingError.missingJunction
            }
            let prediction = try model.predict(inputIDs: encoded.inputIDs)
            guard prediction.boundaryProbabilities.indices.contains(junctionIndex) else {
                throw ClauseTaggerEncodingError.missingJunction
            }
            continuationProbability = 1 - prediction.boundaryProbabilities[junctionIndex][1]
        }

        let inputTokens = boundaryInputs.reduce(0) { $0 + $1.inputIDs.count }
            + (continuationInput?.inputIDs.count ?? 0)
        try Task.checkCancellation()
        return ClauseBoundaryResponse(
            probabilities: candidateProbabilities,
            continuationProbability: continuationProbability,
            inputTokens: inputTokens
        )
    }

    public func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
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
            let prediction = try model.predict(inputIDs: encoded.inputIDs)
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
