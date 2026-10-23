import Foundation

public enum ClauseTaggerTokenizerError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case unrepresentableText

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            "トークナイザー設定が不正です: \(detail)"
        case .unrepresentableText:
            "入力テキストを語彙とバイトフォールバックで正確に表現できません。"
        }
    }
}

struct ClauseTaggerTokenizerConfiguration: Sendable {
    struct VocabularyEntry: Sendable {
        let token: String
        let score: Float
    }

    struct AddedToken: Sendable {
        let id: Int
        let content: String
    }

    let vocabulary: [VocabularyEntry]
    let unknownID: Int
    let addedTokens: [AddedToken]

    private struct Document: Decodable {
        let value: JSONValue

        init(from decoder: any Decoder) throws {
            value = try Self.shape.decode(from: decoder)
        }

        static let shape: JSONShape = .object([
            "version": .string,
            "truncation": .null,
            "padding": .null,
            "added_tokens": .array(.object([
                "id": .integer,
                "content": .string,
                "single_word": .boolean,
                "lstrip": .boolean,
                "rstrip": .boolean,
                "normalized": .boolean,
                "special": .boolean
            ])),
            "normalizer": .null,
            "pre_tokenizer": .object([
                "type": .string,
                "replacement": .string,
                "prepend_scheme": .string,
                "split": .boolean
            ]),
            "post_processor": JSONShape(expecting: ClauseTaggerTokenizerConfiguration.expectedPostProcessor),
            "decoder": JSONShape(expecting: ClauseTaggerTokenizerConfiguration.expectedDecoder),
            "model": .object([
                "type": .string,
                "unk_id": .integer,
                "vocab": .array(.tuple([.string, .number])),
                "byte_fallback": .boolean
            ])
        ])
    }

    init(data: Data) throws {
        let document: JSONValue
        do {
            document = try JSONDecoder().decode(Document.self, from: data).value
        } catch let error as DecodingError {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json\(Self.decodingPath(for: error)): \(Self.decodingDescription(for: error))"
            )
        } catch {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json: JSON decoding failed: \(String(describing: error))"
            )
        }

        let root = try Self.object(
            document,
            at: "$",
            exactly: [
                "version", "truncation", "padding", "added_tokens", "normalizer",
                "pre_tokenizer", "post_processor", "decoder", "model"
            ]
        )
        try Self.requireString(root["version"]!, equals: "1.0", at: "$.version")
        try Self.requireNull(root["truncation"]!, at: "$.truncation")
        try Self.requireNull(root["padding"]!, at: "$.padding")
        try Self.requireNull(root["normalizer"]!, at: "$.normalizer")
        try Self.validatePreTokenizer(root["pre_tokenizer"]!)
        try Self.validatePinned(
            root["post_processor"]!,
            expected: Self.expectedPostProcessor,
            at: "$.post_processor"
        )
        try Self.validatePinned(
            root["decoder"]!,
            expected: Self.expectedDecoder,
            at: "$.decoder"
        )

        let model = try Self.object(
            root["model"]!,
            at: "$.model",
            exactly: ["type", "unk_id", "vocab", "byte_fallback"]
        )
        try Self.requireString(model["type"]!, equals: "Unigram", at: "$.model.type")
        let decodedUnknownID = try Self.integer(model["unk_id"]!, at: "$.model.unk_id")
        guard decodedUnknownID == 0 else {
            throw Self.failure("$.model.unk_id", "must be 0")
        }
        try Self.requireBoolean(model["byte_fallback"]!, equals: true, at: "$.model.byte_fallback")

        let vocabularyValues = try Self.array(model["vocab"]!, at: "$.model.vocab")
        guard (276...102_400).contains(vocabularyValues.count) else {
            throw Self.failure("$.model.vocab", "must contain between 276 and 102400 entries; found \(vocabularyValues.count)")
        }

        var decodedVocabulary: [VocabularyEntry] = []
        decodedVocabulary.reserveCapacity(vocabularyValues.count)
        var vocabularyBytes = Set<Data>()
        vocabularyBytes.reserveCapacity(vocabularyValues.count)
        for (id, value) in vocabularyValues.enumerated() {
            let path = "$.model.vocab[\(id)]"
            let pair = try Self.array(value, at: path)
            guard pair.count == 2 else {
                throw Self.failure(path, "must be a two-element [String, Double] pair; found \(pair.count) elements")
            }
            let token = try Self.string(pair[0], at: "\(path)[0]")
            guard !token.isEmpty else {
                throw Self.failure("\(path)[0]", "vocabulary token must not be empty")
            }
            let tokenBytes = Data(token.utf8)
            guard vocabularyBytes.insert(tokenBytes).inserted else {
                throw Self.failure("\(path)[0]", "duplicate vocabulary token by UTF-8 bytes")
            }

            let scoreDouble = try Self.double(pair[1], at: "\(path)[1]")
            guard scoreDouble.isFinite else {
                throw Self.failure("\(path)[1]", "score must be finite as Double")
            }
            let score = Float(scoreDouble)
            guard score.isFinite else {
                throw Self.failure("\(path)[1]", "score must remain finite when converted to Float")
            }
            decodedVocabulary.append(VocabularyEntry(token: token, score: score))
        }

        try Self.validateFixedVocabulary(decodedVocabulary)
        let minimumScore = decodedVocabulary.reduce(Float(999)) { min($0, $1.score) }
        guard (minimumScore - 10).isFinite else {
            throw Self.failure("$.model.vocab", "minimum Float score minus 10 must remain finite")
        }

        let decodedAddedTokens = try Self.decodeAddedTokens(
            root["added_tokens"]!,
            vocabulary: decodedVocabulary
        )

        vocabulary = decodedVocabulary
        unknownID = decodedUnknownID
        addedTokens = decodedAddedTokens
    }

    private static func validateFixedVocabulary(_ vocabulary: [VocabularyEntry]) throws {
        let fixedTokens = [
            "<unk>", "<s>", "</s>", "<pad>", "<sep>", "<mask>", "<cls>",
            "<|system|>", "<|assistant|>", "<|user|>", "<|available_tools|>",
            "<|tool_calls|>", "<|tool_results|>", "<|code|>", "<|file|>"
        ]
        for (id, expected) in fixedTokens.enumerated() {
            guard Self.sameUTF8(vocabulary[id].token, expected) else {
                throw Self.failure("$.model.vocab[\(id)][0]", "must spell \(String(reflecting: expected)) byte-for-byte")
            }
        }
        for byte in 0..<256 {
            let id = 15 + byte
            let expected = String(format: "<0x%02X>", byte)
            guard Self.sameUTF8(vocabulary[id].token, expected) else {
                throw Self.failure("$.model.vocab[\(id)][0]", "must spell byte fallback token \(expected) byte-for-byte")
            }
        }
        guard Self.sameUTF8(vocabulary[275].token, "、") else {
            throw Self.failure("$.model.vocab[275][0]", "must spell \(String(reflecting: "、")) byte-for-byte")
        }
    }

    private static func decodeAddedTokens(
        _ value: JSONValue,
        vocabulary: [VocabularyEntry]
    ) throws -> [AddedToken] {
        let values = try array(value, at: "$.added_tokens")
        var ids = Set<Int>()
        var contents = Set<Data>()
        var result: [AddedToken] = []
        result.reserveCapacity(values.count)

        for (index, value) in values.enumerated() {
            let path = "$.added_tokens[\(index)]"
            let object = try object(
                value,
                at: path,
                exactly: ["id", "content", "single_word", "lstrip", "rstrip", "normalized", "special"]
            )
            let id = try integer(object["id"]!, at: "\(path).id")
            guard vocabulary.indices.contains(id) else {
                throw failure("\(path).id", "must reference a vocabulary index; found \(id)")
            }
            let content = try string(object["content"]!, at: "\(path).content")
            guard !content.isEmpty else {
                throw failure("\(path).content", "added-token content must not be empty")
            }
            let contentBytes = Data(content.utf8)
            guard contentBytes == Data(vocabulary[id].token.utf8) else {
                throw failure("\(path).content", "UTF-8 bytes must exactly match vocabulary entry \(id)")
            }
            guard ids.insert(id).inserted else {
                throw failure("\(path).id", "duplicate added-token ID \(id)")
            }
            guard contents.insert(contentBytes).inserted else {
                throw failure("\(path).content", "duplicate added-token content by UTF-8 bytes")
            }

            for flag in ["single_word", "lstrip", "rstrip", "normalized"] {
                try requireBoolean(object[flag]!, equals: false, at: "\(path).\(flag)")
            }
            try requireBoolean(object["special"]!, equals: id <= 6, at: "\(path).special")
            result.append(AddedToken(id: id, content: content))
        }

        for id in 0...14 where !ids.contains(id) {
            throw failure("$.added_tokens", "required added-token ID \(id) is missing")
        }
        return result
    }

    private static func validatePreTokenizer(_ value: JSONValue) throws {
        let object = try object(
            value,
            at: "$.pre_tokenizer",
            exactly: ["type", "replacement", "prepend_scheme", "split"]
        )
        try requireString(object["type"]!, equals: "Metaspace", at: "$.pre_tokenizer.type")
        try requireString(object["replacement"]!, equals: "▁", at: "$.pre_tokenizer.replacement")
        try requireString(object["prepend_scheme"]!, equals: "never", at: "$.pre_tokenizer.prepend_scheme")
        try requireBoolean(object["split"]!, equals: false, at: "$.pre_tokenizer.split")
    }

    private static let expectedPostProcessor: JSONValue = .object([
        "type": .string("TemplateProcessing"),
        "single": .array([
            .object(["SpecialToken": .object(["id": .string("<s>"), "type_id": .integer(0)])]),
            .object(["Sequence": .object(["id": .string("A"), "type_id": .integer(0)])]),
            .object(["SpecialToken": .object(["id": .string("</s>"), "type_id": .integer(0)])])
        ]),
        "pair": .array([
            .object(["SpecialToken": .object(["id": .string("<s>"), "type_id": .integer(0)])]),
            .object(["Sequence": .object(["id": .string("A"), "type_id": .integer(0)])]),
            .object(["SpecialToken": .object(["id": .string("</s>"), "type_id": .integer(0)])]),
            .object(["SpecialToken": .object(["id": .string("<s>"), "type_id": .integer(1)])]),
            .object(["Sequence": .object(["id": .string("B"), "type_id": .integer(1)])]),
            .object(["SpecialToken": .object(["id": .string("</s>"), "type_id": .integer(1)])])
        ]),
        "special_tokens": .object([
            "</s>": .object([
                "id": .string("</s>"),
                "ids": .array([.integer(2)]),
                "tokens": .array([.string("</s>")])
            ]),
            "<s>": .object([
                "id": .string("<s>"),
                "ids": .array([.integer(1)]),
                "tokens": .array([.string("<s>")])
            ])
        ])
    ])

    private static let expectedDecoder: JSONValue = .object([
        "type": .string("Sequence"),
        "decoders": .array([
            .object([
                "type": .string("Replace"),
                "pattern": .object(["String": .string("▁")]),
                "content": .string(" ")
            ]),
            .object(["type": .string("ByteFallback")]),
            .object(["type": .string("Fuse")])
        ])
    ])

    private static func validatePinned(_ actual: JSONValue, expected: JSONValue, at path: String) throws {
        guard jsonValuesEqual(actual, expected) else {
            throw failure(path, "does not exactly match the pinned tokenizer configuration")
        }
    }

    private static func jsonValuesEqual(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case let (.boolean(left), .boolean(right)):
            left == right
        case let (.integer(left), .integer(right)):
            left == right
        case let (.number(left), .number(right)):
            left == right
        case let (.string(left), .string(right)):
            sameUTF8(left, right)
        case let (.array(left), .array(right)):
            left.count == right.count && zip(left, right).allSatisfy(jsonValuesEqual)
        case let (.object(left), .object(right)):
            left.count == right.count && left.allSatisfy { key, value in
                guard let rightValue = right[key] else { return false }
                return jsonValuesEqual(value, rightValue)
            }
        default:
            false
        }
    }

    private static func object(
        _ value: JSONValue,
        at path: String,
        exactly expectedKeys: Set<String>
    ) throws -> [String: JSONValue] {
        guard case let .object(object) = value else {
            throw failure(path, "expected an object")
        }
        if let unknown = object.keys.filter({ !expectedKeys.contains($0) }).sorted().first {
            throw failure("\(path).\(unknown)", "unknown key")
        }
        if let missing = expectedKeys.filter({ object[$0] == nil }).sorted().first {
            throw failure("\(path).\(missing)", "required key is missing")
        }
        return object
    }

    private static func array(_ value: JSONValue, at path: String) throws -> [JSONValue] {
        guard case let .array(array) = value else {
            throw failure(path, "expected an array")
        }
        return array
    }

    private static func string(_ value: JSONValue, at path: String) throws -> String {
        guard case let .string(string) = value else {
            throw failure(path, "expected a string")
        }
        return string
    }

    private static func double(_ value: JSONValue, at path: String) throws -> Double {
        switch value {
        case let .integer(integer):
            Double(integer)
        case let .number(number):
            number
        default:
            throw failure(path, "expected a JSON number")
        }
    }

    private static func integer(_ value: JSONValue, at path: String) throws -> Int {
        switch value {
        case let .integer(integer):
            return integer
        case let .number(number):
            guard let integer = Int(exactly: number) else {
                throw failure(path, "expected an integer JSON number")
            }
            return integer
        default:
            throw failure(path, "expected an integer JSON number")
        }
    }

    private static func requireString(_ value: JSONValue, equals expected: String, at path: String) throws {
        let actual = try string(value, at: path)
        guard sameUTF8(actual, expected) else {
            throw failure(path, "must be \(String(reflecting: expected))")
        }
    }

    private static func requireBoolean(_ value: JSONValue, equals expected: Bool, at path: String) throws {
        guard case let .boolean(actual) = value else {
            throw failure(path, "expected a Boolean")
        }
        guard actual == expected else {
            throw failure(path, "must be \(expected)")
        }
    }

    private static func requireNull(_ value: JSONValue, at path: String) throws {
        guard case .null = value else {
            throw failure(path, "must be explicitly null")
        }
    }

    private static func sameUTF8(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8) == Data(rhs.utf8)
    }

    private static func failure(_ path: String, _ reason: String) -> ClauseTaggerTokenizerError {
        .invalidConfiguration("\(path): \(reason)")
    }

    private static func decodingPath(for error: DecodingError) -> String {
        func path(_ codingPath: [any CodingKey]) -> String {
            guard !codingPath.isEmpty else { return " at $" }
            return " at $" + codingPath.map { key in
                if let index = key.intValue {
                    "[\(index)]"
                } else {
                    ".\(key.stringValue)"
                }
            }.joined()
        }

        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            return path(context.codingPath)
        case let .keyNotFound(key, context):
            return path(context.codingPath + [key])
        @unknown default:
            return " at $"
        }
    }

    private static func decodingDescription(for error: DecodingError) -> String {
        switch error {
        case let .typeMismatch(type, context):
            "type mismatch for \(type): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            "missing value for \(type): \(context.debugDescription)"
        case let .keyNotFound(key, context):
            "missing key \(key.stringValue): \(context.debugDescription)"
        case let .dataCorrupted(context):
            context.debugDescription
        @unknown default:
            String(describing: error)
        }
    }
}

private indirect enum JSONValue {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

private indirect enum JSONShape: Sendable {
    case null
    case boolean
    case integer
    case number
    case string
    case array(JSONShape)
    case tuple([JSONShape])
    case object([String: JSONShape])

    init(expecting value: JSONValue) {
        switch value {
        case .null:
            self = .null
        case .boolean:
            self = .boolean
        case .integer:
            self = .integer
        case .number:
            self = .number
        case .string:
            self = .string
        case let .array(values):
            self = .tuple(values.map { JSONShape(expecting: $0) })
        case let .object(values):
            self = .object(values.mapValues { JSONShape(expecting: $0) })
        }
    }

    func decode(from decoder: any Decoder) throws -> JSONValue {
        switch self {
        case .null:
            let container = try decoder.singleValueContainer()
            guard container.decodeNil() else {
                throw DecodingError.typeMismatch(
                    NSNull.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "expected null")
                )
            }
            return .null
        case .boolean:
            return .boolean(try decoder.singleValueContainer().decode(Bool.self))
        case .integer:
            return .integer(try decoder.singleValueContainer().decode(Int.self))
        case .number:
            return .number(try decoder.singleValueContainer().decode(Double.self))
        case .string:
            return .string(try decoder.singleValueContainer().decode(String.self))
        case let .array(elementShape):
            var container = try decoder.unkeyedContainer()
            var values: [JSONValue] = []
            while !container.isAtEnd {
                values.append(try elementShape.decode(from: container.superDecoder()))
            }
            return .array(values)
        case let .tuple(expectedShapes):
            var container = try decoder.unkeyedContainer()
            guard container.count == expectedShapes.count else {
                let foundCount = container.count.map { String($0) } ?? "unknown"
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "expected tuple with \(expectedShapes.count) elements; found \(foundCount)"
                    )
                )
            }
            var values: [JSONValue] = []
            values.reserveCapacity(expectedShapes.count)
            for shape in expectedShapes {
                values.append(try shape.decode(from: container.superDecoder()))
            }
            return .array(values)
        case let .object(expectedFields):
            let container = try decoder.container(keyedBy: DynamicKey.self)
            let keys = container.allKeys
            let actualKeys = Set(keys.map(\.stringValue))
            if let unknown = actualKeys.subtracting(expectedFields.keys).sorted().first {
                let key = DynamicKey(stringValue: unknown)!
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "unknown key"
                    )
                )
            }
            if let missing = Set(expectedFields.keys).subtracting(actualKeys).sorted().first {
                let key = DynamicKey(stringValue: missing)!
                throw DecodingError.keyNotFound(
                    key,
                    .init(codingPath: decoder.codingPath, debugDescription: "required key is missing")
                )
            }
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(keys.count)
            for key in keys {
                let shape = expectedFields[key.stringValue]!
                values[key.stringValue] = try shape.decode(from: container.superDecoder(forKey: key))
            }
            return .object(values)
        }
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
