import CryptoKit
import Foundation
import Hub
import Tokenizers

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

public struct ClauseTaggerTokenizer: Sendable {
    private let tokenizer: PreTrainedTokenizer
    private let vocabularyIDs: [Data: Int]
    private let vocabularyScalars: Set<Unicode.Scalar>
    private let byteFallbackIDs: [UInt8: Int]
    private let addedTokens: [AddedToken]

    private struct AddedToken: Sendable {
        let content: String
        let scalars: [UInt32]
    }

    public init(tokenizerURL: URL, expectedSHA256: String) throws {
        let tokenizerBytes: Data
        do {
            tokenizerBytes = try Data(contentsOf: tokenizerURL)
        } catch {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json を読み込めません: \(error.localizedDescription)"
            )
        }

        let actualSHA256 = SHA256.hash(data: tokenizerBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == expectedSHA256 else {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json の SHA-256 がモデルメタデータと一致しません。"
            )
        }

        let document: TokenizerDocument
        do {
            document = try JSONDecoder().decode(TokenizerDocument.self, from: tokenizerBytes)
        } catch {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json を型付き JSON として解析できません: \(error.localizedDescription)"
            )
        }

        let model = document.model

        var vocabularyIDs: [Data: Int] = [:]
        var vocabularyScalars: Set<Unicode.Scalar> = []
        vocabularyIDs.reserveCapacity(model.vocab.count)

        for (id, entry) in model.vocab.enumerated() {
            let tokenBytes = Data(entry.token.utf8)
            vocabularyIDs[tokenBytes] = id
            vocabularyScalars.formUnion(entry.token.unicodeScalars)
        }

        var byteFallbackIDs: [UInt8: Int] = [:]
        byteFallbackIDs.reserveCapacity(256)
        for byte in 0..<256 {
            let token = Data(String(format: "<0x%02X>", byte).utf8)
            if let id = vocabularyIDs[token] {
                byteFallbackIDs[UInt8(byte)] = id
            }
        }

        let addedTokens = document.addedTokens
            .map { AddedToken(content: $0.content, scalars: $0.content.unicodeScalars.map(\.value)) }
            .sorted { $0.scalars.count > $1.scalars.count }

        let libraryVocabulary = model.vocab.map { entry in
            Config([
                Config(BinaryDistinctString(Array(entry.token.utf16))),
                Config(Float(entry.score))
            ])
        }
        let libraryData = Config([
            "model": Config([
                "type": Config("Unigram"),
                "unk_id": Config(model.unkID),
                "vocab": Config(libraryVocabulary)
            ])
        ])
        let tokenizerConfiguration = Config([
            "tokenizer_class": Config("XLMRobertaTokenizer"),
            "unk_token": Config("<unk>"),
            "eos_token": Config("</s>")
        ])

        do {
            tokenizer = try PreTrainedTokenizer(
                tokenizerConfig: tokenizerConfiguration,
                tokenizerData: libraryData
            )
        } catch {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "Unigram トークナイザーを構築できません: \(error.localizedDescription)"
            )
        }

        self.vocabularyIDs = vocabularyIDs
        self.vocabularyScalars = vocabularyScalars
        self.byteFallbackIDs = byteFallbackIDs
        self.addedTokens = addedTokens
    }

    public func encodePiece(_ text: String) throws -> [Int] {
        guard !text.isEmpty else { return [] }

        let scalars = Array(text.unicodeScalars)
        var result: [Int] = []
        var ordinaryRun: [Unicode.Scalar] = []
        var offset = 0

        while offset < scalars.count {
            if let addedToken = addedToken(matching: scalars, at: offset) {
                result += try encodeOrdinary(ordinaryRun)
                ordinaryRun.removeAll(keepingCapacity: true)

                result += try encodeKnownText(addedToken.content)
                offset += addedToken.scalars.count
            } else {
                ordinaryRun.append(scalars[offset])
                offset += 1
            }
        }

        result += try encodeOrdinary(ordinaryRun)
        return result
    }

    private func addedToken(matching scalars: [Unicode.Scalar], at offset: Int) -> AddedToken? {
        for token in addedTokens where offset + token.scalars.count <= scalars.count {
            var matches = true
            for (index, scalarValue) in token.scalars.enumerated() {
                if scalars[offset + index].value != scalarValue {
                    matches = false
                    break
                }
            }
            if matches { return token }
        }
        return nil
    }

    private func encodeOrdinary(_ scalars: [Unicode.Scalar]) throws -> [Int] {
        guard !scalars.isEmpty else { return [] }

        var result: [Int] = []
        var knownRun = String.UnicodeScalarView()

        func flushKnownRun() throws {
            guard !knownRun.isEmpty else { return }
            result += try encodeKnownText(String(knownRun))
            knownRun = String.UnicodeScalarView()
        }

        for scalar in scalars {
            let transformed = scalar.value == 0x20 ? Unicode.Scalar(0x2581)! : scalar
            if vocabularyScalars.contains(transformed) {
                knownRun.append(transformed)
            } else {
                try flushKnownRun()
                result += try encodeBytes(String(transformed).utf8)
            }
        }
        try flushKnownRun()
        return result
    }

    private func encodeKnownText(_ text: String) throws -> [Int] {
        let pieces = tokenizer.tokenize(text: text)
        var reconstructed = Data()
        for piece in pieces {
            reconstructed.append(contentsOf: piece.utf8)
        }
        guard reconstructed == Data(text.utf8) else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }

        var result: [Int] = []
        for piece in pieces {
            let bytes = Data(piece.utf8)
            if let id = vocabularyIDs[bytes] {
                result.append(id)
            } else {
                result += try encodeBytes(bytes)
            }
        }
        return result
    }

    private func encodeBytes<S: Sequence>(_ bytes: S) throws -> [Int] where S.Element == UInt8 {
        var result: [Int] = []
        for byte in bytes {
            guard let id = byteFallbackIDs[byte] else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            result.append(id)
        }
        return result
    }

    private struct TokenizerDocument: Decodable {
        let model: Model
        let addedTokens: [AddedTokenDocument]

        enum CodingKeys: String, CodingKey {
            case model
            case addedTokens = "added_tokens"
        }

        struct Model: Decodable {
            let unkID: Int
            let vocab: [VocabularyEntry]

            enum CodingKeys: String, CodingKey {
                case unkID = "unk_id"
                case vocab
            }
        }

        struct AddedTokenDocument: Decodable {
            let content: String
        }
    }

    private struct VocabularyEntry: Decodable {
        let token: String
        let score: Double

        init(from decoder: Swift.Decoder) throws {
            var container = try decoder.unkeyedContainer()
            token = try container.decode(String.self)
            score = try container.decode(Double.self)
        }
    }
}
