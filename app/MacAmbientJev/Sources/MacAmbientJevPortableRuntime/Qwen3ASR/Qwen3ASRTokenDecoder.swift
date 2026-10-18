import Foundation

/// Turns Qwen3-ASR token ids back into text. It reads only what decoding needs from the Hugging
/// Face `tokenizer.json`: the byte-level BPE vocabulary and the added tokens.
struct Qwen3ASRTokenDecoder {
    private enum Entry {
        case bytes([UInt8])
        case special
    }

    private let entries: [Int64: Entry]

    init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Qwen3ASRError.tokenizerFileUnreadable("\(url.path): \(error)")
        }
        try self.init(tokenizerJSON: data)
    }

    init(tokenizerJSON data: Data) throws {
        let file: TokenizerFile
        do {
            file = try JSONDecoder().decode(TokenizerFile.self, from: data)
        } catch {
            throw Qwen3ASRError.tokenizerMalformed("\(error)")
        }
        guard file.model.type == "BPE" else {
            throw Qwen3ASRError.tokenizerUnsupported("model type \(file.model.type) is not BPE")
        }
        guard file.decoder.type == "ByteLevel" else {
            throw Qwen3ASRError.tokenizerUnsupported("decoder type \(file.decoder.type) is not ByteLevel")
        }

        var entries: [Int64: Entry] = [:]
        entries.reserveCapacity(file.model.vocab.count + file.addedTokens.count)
        for (token, id) in file.model.vocab {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(token.utf8.count)
            for scalar in token.unicodeScalars {
                guard let byte = Self.byteForScalar[scalar] else {
                    throw Qwen3ASRError.tokenizerMalformed("vocabulary token has a character outside the byte-level alphabet: \(token)")
                }
                bytes.append(byte)
            }
            guard entries.updateValue(.bytes(bytes), forKey: id) == nil else {
                throw Qwen3ASRError.duplicateTokenID(id)
            }
        }
        for added in file.addedTokens {
            // An added token's content is literal text, not byte-level encoded.
            let entry: Entry = added.special ? .special : .bytes(Array(added.content.utf8))
            guard entries.updateValue(entry, forKey: added.id) == nil else {
                throw Qwen3ASRError.duplicateTokenID(added.id)
            }
        }
        self.entries = entries
    }

    /// Special tokens produce no text. An id the tokenizer does not know, or bytes that are not
    /// valid UTF-8 together, fail.
    func decode(_ ids: [Int64]) throws -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let entry = entries[id] else { throw Qwen3ASRError.unknownTokenID(id) }
            if case let .bytes(tokenBytes) = entry { bytes.append(contentsOf: tokenBytes) }
        }
        guard let text = String(validating: bytes, as: UTF8.self) else { throw Qwen3ASRError.invalidUTF8 }
        return text
    }

    /// The text of one generation: the ids after the last `<asr_text>` marker, without stop
    /// tokens, trimmed. The marker is matched by id because `<asr_text>` is not a special token
    /// and would otherwise decode to literal text.
    func transcript(generatedIDs: [Int64]) throws -> String {
        let afterMarker: ArraySlice<Int64>
        if let marker = generatedIDs.lastIndex(of: Qwen3ASRToken.asrText) {
            afterMarker = generatedIDs[(marker + 1)...]
        } else {
            afterMarker = generatedIDs[...]
        }
        let spoken = afterMarker.filter { !Qwen3ASRToken.stopTokens.contains($0) }
        return try decode(spoken).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GPT-2 `bytes_to_unicode`: printable Latin-1 bytes map to themselves, the rest to U+0100 upward.
    private static let byteForScalar: [Unicode.Scalar: UInt8] = {
        let printable: [UInt8] = Array(33...126) + Array(161...172) + Array(174...255)
        var table: [Unicode.Scalar: UInt8] = [:]
        for byte in printable { table[Unicode.Scalar(byte)] = byte }
        var next: UInt32 = 256
        for byte in UInt8.min...UInt8.max where !printable.contains(byte) {
            table[Unicode.Scalar(next)!] = byte
            next += 1
        }
        return table
    }()
}

private struct TokenizerFile: Decodable {
    struct Model: Decodable {
        let type: String
        let vocab: [String: Int64]
    }

    struct Decoder: Decodable {
        let type: String
    }

    struct AddedToken: Decodable {
        let id: Int64
        let content: String
        let special: Bool
    }

    let model: Model
    let decoder: Decoder
    let addedTokens: [AddedToken]

    private enum CodingKeys: String, CodingKey {
        case model
        case decoder
        case addedTokens = "added_tokens"
    }
}
