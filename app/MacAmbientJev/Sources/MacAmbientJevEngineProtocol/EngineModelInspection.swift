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

    internal enum Kind: String, Codable, CaseIterable, Sendable {
        case validated
        case invalid

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw EngineProtocolError.invalidJSON("unknown clause tagger inspection kind")
            }
            self = value
        }
    }

    internal var kind: Kind {
        switch self {
        case .validated:
            .validated
        case .invalid:
            .invalid
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case identity
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .validated:
            try engineModelInspectionRequire(!container.contains(.error), "validated clause tagger inspection must not contain error")
            self = .validated(try container.decode(EngineClauseTaggerIdentity.self, forKey: .identity))
        case .invalid:
            try engineModelInspectionRequire(!container.contains(.identity), "invalid clause tagger inspection must not contain identity")
            self = .invalid(try container.decode(EngineFailure.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .validated(identity):
            try container.encode(identity, forKey: .identity)
        case let .invalid(error):
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

public enum EngineModelState: String, Codable, CaseIterable, Equatable, Sendable {
    case installed
    case missing
    case corrupt

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown model state")
        }
        self = value
    }
}

private func engineModelStateRequire(_ state: EngineModelState, _ message: String?) throws {
    if state == .installed {
        try engineModelInspectionRequire(message == nil, "installed model status must not have a message")
    } else {
        try engineModelInspectionRequire(message?.isEmpty == false, "\(state.rawValue) model status needs a message")
    }
}

/// The installed state of the VAD, one ASR size and diarization. `message` is nil exactly when `state` is `installed`.
public struct EngineASRProfileStatus: Codable, Equatable, Sendable {
    public let asrSize: EngineASRSize
    public let state: EngineModelState
    @EngineNullable public private(set) var message: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case asrSize = "asr_size"
        case state
        case message
    }

    public init(asrSize: EngineASRSize, state: EngineModelState, message: String?) throws {
        try engineModelStateRequire(state, message)
        self.asrSize = asrSize
        self.state = state
        _message = EngineNullable(wrappedValue: message)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            asrSize: container.decode(EngineASRSize.self, forKey: .asrSize),
            state: container.decode(EngineModelState.self, forKey: .state),
            message: container.decode(EngineNullable<String>.self, forKey: .message).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asrSize, forKey: .asrSize)
        try container.encode(state, forKey: .state)
        try container.encode(_message, forKey: .message)
    }
}

/// The installed state of the clause tagger, with the same message rule as `EngineASRProfileStatus`.
public struct EngineClauseTaggerStatus: Codable, Equatable, Sendable {
    public let state: EngineModelState
    @EngineNullable public private(set) var message: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case state
        case message
    }

    public init(state: EngineModelState, message: String?) throws {
        try engineModelStateRequire(state, message)
        self.state = state
        _message = EngineNullable(wrappedValue: message)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            state: container.decode(EngineModelState.self, forKey: .state),
            message: container.decode(EngineNullable<String>.self, forKey: .message).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(_message, forKey: .message)
    }
}

public struct EngineModelsStatus: Codable, Equatable, Sendable {
    public let asrProfiles: [EngineASRProfileStatus]
    public let clauseTagger: EngineClauseTaggerStatus

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case asrProfiles = "asr_profiles"
        case clauseTagger = "clause_tagger"
    }

    public init(asrProfiles: [EngineASRProfileStatus], clauseTagger: EngineClauseTaggerStatus) throws {
        try engineModelInspectionRequire(!asrProfiles.isEmpty, "asr_profiles must not be empty")
        var seen = Set<EngineASRSize>()
        for profile in asrProfiles {
            try engineModelInspectionRequire(seen.insert(profile.asrSize).inserted, "asr_profiles must be unique")
        }
        self.asrProfiles = asrProfiles
        self.clauseTagger = clauseTagger
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            asrProfiles: container.decode([EngineASRProfileStatus].self, forKey: .asrProfiles),
            clauseTagger: container.decode(EngineClauseTaggerStatus.self, forKey: .clauseTagger)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asrProfiles, forKey: .asrProfiles)
        try container.encode(clauseTagger, forKey: .clauseTagger)
    }
}
