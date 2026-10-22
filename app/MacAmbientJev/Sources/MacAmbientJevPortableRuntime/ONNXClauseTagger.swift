import Foundation
import MacAmbientJevCore

/// The portable clause tagger: the pinned ONNX graph on ONNX Runtime CPU, behind the same decision logic as Core ML.
public actor ONNXClauseTagger: DecisionProvider {
    public static let backendName = "onnx-clause-tagger"

    public nonisolated let identity: ClauseTaggerModelIdentity

    private let tokenizer: ClauseTaggerTokenizer
    private let model: ONNXClauseTaggerModel

    /// `modelDirectory` holds the files that `scripts/fetch_clause_tagger.py` prints the directory of.
    public init(modelDirectory: URL, intraOpThreads: Int) throws {
        guard intraOpThreads > 0 else {
            throw ClauseTaggerModelError.unavailable("ONNX Runtime の演算スレッド数は正の整数である必要があります（指定: \(intraOpThreads)）。")
        }
        let assets = try ClauseTaggerAssets(modelDirectory: modelDirectory)
        tokenizer = try ClauseTaggerTokenizer(
            tokenizerURL: assets.tokenizerURL,
            expectedSHA256: assets.identity.tokenizerSHA256
        )
        model = try ONNXClauseTaggerModel(assets: assets, intraOpThreads: intraOpThreads)
        identity = assets.identity
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
