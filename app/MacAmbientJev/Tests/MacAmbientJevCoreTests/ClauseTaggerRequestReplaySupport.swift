import Foundation
import MacAmbientJevCore
import MacAmbientJevClauseTaggerFixtures

enum ClauseTaggerRequestReplaySupport {
    struct Document: Decodable {
        let schemaVersion: Int
        let modelID: String
        let modelRevision: String
        let tokenizerSHA256: String
        let backend: String
        let computeUnits: String
        let computePrecision: String
        let encodingRevision: String
        let boundaryCases: [BoundaryCase]
        let priorityBatches: [PriorityBatch]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case tokenizerSHA256 = "tokenizer_sha256"
            case backend
            case computeUnits = "compute_units"
            case computePrecision = "compute_precision"
            case encodingRevision = "encoding_revision"
            case boundaryCases = "boundary_cases"
            case priorityBatches = "priority_batches"
        }
    }

    struct BoundaryCase: Decodable {
        let name: String
        let request: Request
        let calls: [Call]
        let response: BoundaryResponse
        let projectedText: String

        enum CodingKeys: String, CodingKey {
            case name, request, calls, response
            case projectedText = "projected_text"
        }
    }

    struct Request: Decodable {
        let source: SegmentTextReference
        let text: String
        let candidates: [ClauseBoundaryCandidate]
        let next: NextSegmentHead?

        func makeRequest() throws -> ClauseBoundaryRequest {
            try ClauseBoundaryRequest(source: source, text: text, candidates: candidates, next: next)
        }
    }

    struct BoundaryResponse: Decodable {
        let probabilities: [String: Double]
        let continuationProbability: Double?
        let fillerRanges: [TextUTF16Range]
        let inputTokens: Int

        enum CodingKeys: String, CodingKey {
            case probabilities
            case continuationProbability = "continuation_probability"
            case fillerRanges = "filler_ranges"
            case inputTokens = "input_tokens"
        }
    }

    struct PriorityBatch: Decodable {
        let name: String
        let targets: [Target]
        let calls: [Call]
        let response: PriorityResponse
    }

    struct Target: Decodable {
        let key: String
        let text: String
    }

    struct PriorityResponse: Decodable {
        let decisions: [String: ContentPriorityDecision]
        let inputTokens: Int

        enum CodingKeys: String, CodingKey {
            case decisions
            case inputTokens = "input_tokens"
        }
    }

    struct Call: Decodable {
        let purpose: String
        let targetKey: String?
        let inputIDs: [Int]
        let contentStartTokenIndex: Int
        let sourceTokenRanges: [TextUTF16Range?]
        let candidateTokenIndices: [String: Int]
        let junctionIndex: Int?
        let spanTokenIndices: [Int]
        let boundaryProbabilities: [[Double]]
        let spanProbabilities: [[Double]]
        let priorityProbabilities: [Double]

        enum CodingKeys: String, CodingKey {
            case purpose
            case targetKey = "target_key"
            case inputIDs = "input_ids"
            case contentStartTokenIndex = "content_start_token_index"
            case sourceTokenRanges = "source_token_ranges"
            case candidateTokenIndices = "candidate_token_indices"
            case junctionIndex = "junction_index"
            case spanTokenIndices = "span_token_indices"
            case boundaryProbabilities = "boundary_probs"
            case spanProbabilities = "span_probs"
            case priorityProbabilities = "priority_probs"
        }
    }

    enum ReplayError: Error, LocalizedError {
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .mismatch(let detail): "ClauseTagger request replay mismatch: \(detail)"
            }
        }
    }

    final class Replay {
        private let calls: [Call]
        private(set) var nextCallIndex = 0

        init(calls: [Call]) {
            self.calls = calls
        }

        func predict(_ inputIDs: [Int]) throws -> ClauseTaggerPrediction {
            guard calls.indices.contains(nextCallIndex) else {
                throw ReplayError.mismatch("unexpected extra call at index \(nextCallIndex)")
            }
            let callIndex = nextCallIndex
            let call = calls[callIndex]
            guard inputIDs == call.inputIDs else {
                throw ReplayError.mismatch(
                    "call \(callIndex) purpose=\(call.purpose) target_key=\(call.targetKey ?? "<none>") input_ids differ"
                )
            }

            try validate(call, at: callIndex)
            nextCallIndex += 1
            return ClauseTaggerPrediction(
                boundaryProbabilities: call.boundaryProbabilities,
                spanProbabilities: call.spanProbabilities,
                priorityProbabilities: call.priorityProbabilities
            )
        }

        func requireComplete() throws {
            guard nextCallIndex == calls.count else {
                throw ReplayError.mismatch(
                    "consumed \(nextCallIndex) of \(calls.count) expected calls; next is call \(nextCallIndex)"
                )
            }
        }

        private func validate(_ call: Call, at callIndex: Int) throws {
            let context = "call \(callIndex) purpose=\(call.purpose) target_key=\(call.targetKey ?? "<none>")"
            guard call.boundaryProbabilities.count == call.inputIDs.count,
                  call.spanProbabilities.count == call.inputIDs.count,
                  call.priorityProbabilities.count == 2 else {
                throw ReplayError.mismatch("\(context) head counts do not match input length \(call.inputIDs.count)")
            }
            for (headName, rows, expectedWidth) in [
                ("boundary", call.boundaryProbabilities, 2),
                ("span", call.spanProbabilities, 4)
            ] {
                for (rowIndex, row) in rows.enumerated() {
                    guard row.count == expectedWidth,
                          row.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                          abs(row.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
                        throw ReplayError.mismatch(
                            "\(context) \(headName) probability row \(rowIndex) is invalid"
                        )
                    }
                }
            }
            guard call.priorityProbabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  abs(call.priorityProbabilities.reduce(0, +) - 1) <= taggerProbabilitySumTolerance else {
                throw ReplayError.mismatch("\(context) priority probabilities are invalid")
            }
        }
    }

    static func load() throws -> Document {
        let url = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerRequestFixtures")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Document.self, from: data)
    }

    static func tokenizer(document: Document) throws -> ClauseTaggerTokenizer {
        let url = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerTokenizer")
        return try ClauseTaggerTokenizer(tokenizerURL: url, expectedSHA256: document.tokenizerSHA256)
    }
}
