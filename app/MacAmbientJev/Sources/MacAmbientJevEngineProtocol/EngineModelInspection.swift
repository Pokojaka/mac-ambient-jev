import Foundation

private func engineModelInspectionRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineModelInspectionRequireNonWhitespace(_ value: String, _ field: String) throws {
    try engineModelInspectionRequire(
        value.contains { !$0.isWhitespace },
        "\(field) must contain a non-whitespace character"
    )
}

private func engineModelInspectionRequireSHA256(_ value: String, _ field: String) throws {
    let bytes = value.utf8
    try engineModelInspectionRequire(
        bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) },
        "\(field) must be 64 lowercase hexadecimal characters"
    )
}

public struct EngineClauseTaggerIdentity: Codable, Equatable, Sendable {
    public let backend: String
    public let modelID: String
    public let revision: String
    public let tokenizerSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case backend
        case modelID = "model_id"
        case revision
        case tokenizerSHA256 = "tokenizer_sha256"
    }

    public init(backend: String, modelID: String, revision: String, tokenizerSHA256: String) throws {
        try engineModelInspectionRequireNonWhitespace(backend, "backend")
        try engineModelInspectionRequireNonWhitespace(modelID, "model_id")
        try engineModelInspectionRequireSHA256(revision, "revision")
        try engineModelInspectionRequireSHA256(tokenizerSHA256, "tokenizer_sha256")
        self.backend = backend
        self.modelID = modelID
        self.revision = revision
        self.tokenizerSHA256 = tokenizerSHA256
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            backend: container.decode(String.self, forKey: .backend),
            modelID: container.decode(String.self, forKey: .modelID),
            revision: container.decode(String.self, forKey: .revision),
            tokenizerSHA256: container.decode(String.self, forKey: .tokenizerSHA256)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(revision, forKey: .revision)
        try container.encode(tokenizerSHA256, forKey: .tokenizerSHA256)
    }
}

public enum EngineClauseTaggerInspection: Codable, Equatable, Sendable {
    case validated(EngineClauseTaggerIdentity)
    case invalid(EngineFailure)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case identity
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "validated":
            try engineModelInspectionRequire(!container.contains(.error), "validated clause tagger inspection must not contain error")
            self = .validated(try container.decode(EngineClauseTaggerIdentity.self, forKey: .identity))
        case "invalid":
            try engineModelInspectionRequire(!container.contains(.identity), "invalid clause tagger inspection must not contain identity")
            self = .invalid(try container.decode(EngineFailure.self, forKey: .error))
        default:
            throw EngineProtocolError.invalidJSON("unknown clause tagger inspection kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .validated(identity):
            try container.encode("validated", forKey: .kind)
            try container.encode(identity, forKey: .identity)
        case let .invalid(error):
            try container.encode("invalid", forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }
}

public struct EngineModelsInspection: Codable, Equatable, Sendable {
    public let clauseTagger: EngineClauseTaggerInspection

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clauseTagger = "clause_tagger"
    }

    public init(clauseTagger: EngineClauseTaggerInspection) {
        self.clauseTagger = clauseTagger
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(clauseTagger: try container.decode(EngineClauseTaggerInspection.self, forKey: .clauseTagger))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clauseTagger, forKey: .clauseTagger)
    }
}
