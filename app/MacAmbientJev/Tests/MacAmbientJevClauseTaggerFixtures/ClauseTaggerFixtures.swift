import Foundation

public struct ClauseTaggerFixtureDocument: Decodable, Sendable {
    public let modelID: String
    public let modelRevision: String
    public let trainingStatus: String
    public let tokenizerSHA256: String
    public let unitPolicy: String
    public let encodingRevision: String
    public let clsTokenID: Int
    public let sepTokenID: Int
    public let commaTokenID: Int
    public let fixtures: [ClauseTaggerFixture]

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case trainingStatus = "training_status"
        case tokenizerSHA256 = "tokenizer_sha256"
        case unitPolicy = "unit_policy"
        case encodingRevision = "encoding_revision"
        case clsTokenID = "cls_token_id"
        case sepTokenID = "sep_token_id"
        case commaTokenID = "comma_token_id"
        case fixtures
    }
}

public struct ClauseTaggerFixture: Decodable, Sendable {
    public let text: String
    public let inputIDs: [Int]
    public let boundaryProbabilities: [[Double]]
    public let spanProbabilities: [[Double]]
    public let priorityProbabilities: [Double]
    public let candidateTokenIndices: [String: Int]
    public let coreMLMaxAbsDiff: Double
    public let next: String?
    public let junctionIndex: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case inputIDs = "input_ids"
        case boundaryProbabilities = "boundary_probs"
        case spanProbabilities = "span_probs"
        case priorityProbabilities = "priority_probs"
        case candidateTokenIndices = "candidate_token_indices"
        case coreMLMaxAbsDiff = "coreml_max_abs_diff"
        case next
        case junctionIndex = "junction_index"
    }
}

public enum ClauseTaggerFixturesError: Error, LocalizedError {
    case missingResource(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name):
            "ClauseTagger fixture resource is missing: \(name).json in Resources."
        }
    }
}

public enum ClauseTaggerFixtures {
    public static func resourceURL(named name: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw ClauseTaggerFixturesError.missingResource(name)
        }
        return url
    }

    public static func loadOriginal() throws -> ClauseTaggerFixtureDocument {
        let data = try Data(contentsOf: resourceURL(named: "ClauseTaggerFixtures"))
        return try JSONDecoder().decode(ClauseTaggerFixtureDocument.self, from: data)
    }
}
