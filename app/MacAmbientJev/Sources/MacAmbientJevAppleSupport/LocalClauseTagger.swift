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
        try ClauseTaggerDecisionLogic.assessBoundaries(request, tokenizer: tokenizer) {
            try model.predict(inputIDs: $0)
        }
    }

    public func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        try ClauseTaggerDecisionLogic.classifyPriorities(targets, tokenizer: tokenizer) {
            try model.predict(inputIDs: $0)
        }
    }
}
