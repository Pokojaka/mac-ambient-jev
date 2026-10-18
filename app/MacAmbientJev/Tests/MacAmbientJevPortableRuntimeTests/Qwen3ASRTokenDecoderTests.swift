import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

private struct GoldenFixture: Decodable {
    struct Decoded: Decodable {
        let name: String
        let ids: [Int64]
        let text: String
    }

    struct Invalid: Decodable {
        let name: String
        let ids: [Int64]
    }

    let tokenizerSha256: String
    let decodeCases: [Decoded]
    let invalidUtf8Cases: [Invalid]
    let transcriptCases: [Decoded]

    private enum CodingKeys: String, CodingKey {
        case tokenizerSha256 = "tokenizer_sha256"
        case decodeCases = "decode_cases"
        case invalidUtf8Cases = "invalid_utf8_cases"
        case transcriptCases = "transcript_cases"
    }
}

private enum Qwen3TokenizerTestInputs {
    static func tokenizerURL() throws -> URL {
        let variable = "MAC_AMBIENT_JEV_QWEN3_TOKENIZER"
        let fetch = {
            #if os(Windows)
            "python scripts/fetch_qwen3_asr_tokenizer.py"
            #else
            "python3 scripts/fetch_qwen3_asr_tokenizer.py"
            #endif
        }()
        let hint = "\(fetch)を実行し、取得されたtokenizer.jsonの絶対パスを環境変数\(variable)に設定してください。"
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw FixtureError("環境変数\(variable)が未設定または空です。\(hint)")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw FixtureError("指定されたtokenizer.jsonが存在しないか、通常ファイルではありません: \(url.path)。\(hint)")
        }
        return url
    }

    static func golden() throws -> GoldenFixture {
        guard let url = Bundle.module.url(
            forResource: "qwen3_tokenizer_golden", withExtension: "json", subdirectory: "Resources"
        ) else {
            throw FixtureError("Resources/qwen3_tokenizer_golden.jsonが見つかりません。")
        }
        return try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct Qwen3ASRTokenDecoderGoldenTests {
    private let decoder: Qwen3ASRTokenDecoder
    private let golden: GoldenFixture

    init() throws {
        decoder = try Qwen3ASRTokenDecoder(contentsOf: Qwen3TokenizerTestInputs.tokenizerURL())
        golden = try Qwen3TokenizerTestInputs.golden()
    }

    @Test
    func decodesLikeTheTokenizersPackage() throws {
        #expect(golden.decodeCases.count >= 8)
        for fixture in golden.decodeCases {
            #expect(try decoder.decode(fixture.ids) == fixture.text, "\(fixture.name)")
        }
    }

    @Test
    func invalidUTF8FromPartialCharactersFails() {
        #expect(!golden.invalidUtf8Cases.isEmpty)
        for fixture in golden.invalidUtf8Cases {
            #expect(throws: Qwen3ASRError.invalidUTF8, "\(fixture.name)") {
                try decoder.decode(fixture.ids)
            }
        }
    }

    @Test
    func transcriptMatchesTheReferenceRules() throws {
        #expect(golden.transcriptCases.count >= 8)
        for fixture in golden.transcriptCases {
            #expect(try decoder.transcript(generatedIDs: fixture.ids, endedAtTokenCap: false) == fixture.text, "\(fixture.name)")
        }
    }

    @Test
    func idOutsideTheVocabularyFails() {
        #expect(throws: Qwen3ASRError.unknownTokenID(151_999)) { try decoder.decode([9707, 151_999]) }
        #expect(throws: Qwen3ASRError.unknownTokenID(-1)) { try decoder.decode([-1]) }
    }

    @Test
    func goldenFixtureWasMadeFromThePinnedFile() throws {
        #expect(golden.tokenizerSha256 == "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92")
    }
}

struct Qwen3ASRTokenizerFileTests {
    // "!" is byte 0x21 and "Ġ" (U+0120) is byte 0x20 in the byte-level alphabet.
    private func tokenizerJSON(
        modelType: String = "BPE",
        decoderType: String = "ByteLevel",
        vocab: String = #"{"!": 0, "Ġa": 1, "ã": 2, "ģ": 3}"#,
        addedTokens: String = #"[{"id": 10, "content": "<|stop|>", "special": true}, {"id": 11, "content": "<tag>", "special": false}]"#
    ) -> Data {
        Data(#"""
        {"added_tokens": \#(addedTokens), "decoder": {"type": "\#(decoderType)"},
         "model": {"type": "\#(modelType)", "vocab": \#(vocab)}}
        """#.utf8)
    }

    @Test
    func decodesBytesSkipsSpecialAndKeepsAddedTextLiterally() throws {
        let decoder = try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON())
        #expect(try decoder.decode([0, 1, 10, 11]) == "! a<tag>")
        #expect(try decoder.decode([]) == "")
    }

    @Test
    func vocabularyCharacterOutsideTheByteAlphabetFails() {
        #expect(throws: Qwen3ASRError.self) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(vocab: #"{"あ": 0}"#))
        }
    }

    @Test
    func malformedJSONFails() {
        #expect(throws: Qwen3ASRError.self) { try Qwen3ASRTokenDecoder(tokenizerJSON: Data("{".utf8)) }
        #expect(throws: Qwen3ASRError.self) { try Qwen3ASRTokenDecoder(tokenizerJSON: Data("{}".utf8)) }
    }

    @Test
    func nonBPEModelFails() {
        #expect(throws: Qwen3ASRError.tokenizerUnsupported("model type Unigram is not BPE")) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(modelType: "Unigram"))
        }
    }

    @Test
    func nonByteLevelDecoderFails() {
        #expect(throws: Qwen3ASRError.tokenizerUnsupported("decoder type Metaspace is not ByteLevel")) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(decoderType: "Metaspace"))
        }
    }

    @Test
    func duplicateIdsFail() {
        #expect(throws: Qwen3ASRError.duplicateTokenID(1)) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(vocab: #"{"!": 1, "Ġa": 1}"#))
        }
        #expect(throws: Qwen3ASRError.duplicateTokenID(1)) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(
                addedTokens: #"[{"id": 1, "content": "<x>", "special": true}]"#
            ))
        }
        #expect(throws: Qwen3ASRError.duplicateTokenID(10)) {
            try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(
                addedTokens: #"[{"id": 10, "content": "<x>", "special": true}, {"id": 10, "content": "<y>", "special": false}]"#
            ))
        }
    }

    @Test
    func missingFileFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathComponent("tokenizer.json")
        #expect(throws: Qwen3ASRError.self) { try Qwen3ASRTokenDecoder(contentsOf: missing) }
    }

    @Test
    func invalidUTF8AcrossTokensFailsAndCompleteSequenceDecodes() throws {
        // "ã", U+0123 and U+0124 are the bytes 0xE3, 0x81 and 0x82; 0xE3 0x81 alone is an incomplete character.
        let decoder = try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(
            vocab: #"{"ã": 0, "ģ": 1, "Ĥ": 2}"#
        ))
        #expect(throws: Qwen3ASRError.invalidUTF8) { try decoder.decode([0, 1]) }
        #expect(try decoder.decode([0, 1, 2]) == "\u{3042}")
    }

    @Test
    func transcriptKeepsTheTextAfterTheLastMarkerAndTrimsIt() throws {
        let decoder = try Qwen3ASRTokenDecoder(tokenizerJSON: tokenizerJSON(
            vocab: #"{"a": 0, "Ċ": 1, "Ġ": 2}"#,
            addedTokens: #"[{"id": 151643, "content": "<|endoftext|>", "special": true}, {"id": 151645, "content": "<|im_end|>", "special": true}, {"id": 151704, "content": "<asr_text>", "special": false}]"#
        ))
        #expect(try decoder.transcript(generatedIDs: [2, 1, 0, 2, 151_645], endedAtTokenCap: false) == "a")
        #expect(try decoder.transcript(generatedIDs: [0, 151_704, 1, 0, 151_704, 2, 0, 1, 151_643], endedAtTokenCap: false) == "a")
        #expect(try decoder.transcript(generatedIDs: [151_704, 151_645], endedAtTokenCap: false) == "")
        #expect(try decoder.transcript(generatedIDs: [], endedAtTokenCap: false) == "")
    }
}

struct Qwen3ASRTokenDecoderCapTests {
    private let decoder: Qwen3ASRTokenDecoder

    init() throws {
        let printable: [UInt8] = Array(33...126) + Array(161...172) + Array(174...255)
        var vocabulary: [String: Int] = [:]
        var nextScalar: UInt32 = 256
        for byte in UInt8.min...UInt8.max {
            let scalar: Unicode.Scalar
            if printable.contains(byte) {
                scalar = Unicode.Scalar(byte)
            } else {
                scalar = Unicode.Scalar(nextScalar)!
                nextScalar += 1
            }
            vocabulary[String(scalar)] = Int(byte)
        }
        let addedTokens: [[String: Any]] = [
            ["id": Qwen3ASRToken.imEnd, "content": "<|im_end|>", "special": true],
            ["id": Qwen3ASRToken.endOfText, "content": "<|endoftext|>", "special": true],
            ["id": Qwen3ASRToken.asrText, "content": "<asr_text>", "special": false],
            ["id": 151_650, "content": "<|special|>", "special": true],
        ]
        let tokenizer: [String: Any] = [
            "added_tokens": addedTokens,
            "decoder": ["type": "ByteLevel"],
            "model": ["type": "BPE", "vocab": vocabulary],
        ]
        decoder = try Qwen3ASRTokenDecoder(tokenizerJSON: JSONSerialization.data(withJSONObject: tokenizer))
    }

    private func tokenIDs(_ bytes: [UInt8]) -> [Int64] {
        bytes.map { Int64($0) }
    }

    @Test
    func dropsOnlyValidIncompleteTwoThreeAndFourByteSuffixesAtCap() throws {
        let incompleteSequences: [[UInt8]] = [[0xC3], [0xE3, 0x81], [0xF0, 0x9F, 0x98]]
        for sequence in incompleteSequences {
            #expect(try decoder.transcript(generatedIDs: tokenIDs([0x41] + sequence), endedAtTokenCap: true) == "A")
            #expect(try decoder.transcript(generatedIDs: tokenIDs(sequence), endedAtTokenCap: true) == "")
            #expect(throws: Qwen3ASRError.invalidUTF8) {
                try decoder.transcript(generatedIDs: tokenIDs(sequence), endedAtTokenCap: false)
            }
            #expect(throws: Qwen3ASRError.invalidUTF8) { try decoder.decode(tokenIDs(sequence)) }
        }
    }

    @Test
    func retainsCompleteMultibyteTextAsciiAndEmptyTextAtCap() throws {
        #expect(try decoder.transcript(generatedIDs: tokenIDs([0xC3, 0xA9]), endedAtTokenCap: true) == "é")
        #expect(try decoder.transcript(generatedIDs: tokenIDs([0xE3, 0x81, 0x82]), endedAtTokenCap: true) == "あ")
        #expect(try decoder.transcript(generatedIDs: tokenIDs([0xF0, 0x9F, 0x98, 0x80]), endedAtTokenCap: true) == "😀")
        #expect(try decoder.transcript(generatedIDs: tokenIDs([0x41, 0x42]), endedAtTokenCap: true) == "AB")
        #expect(try decoder.transcript(generatedIDs: [], endedAtTokenCap: true) == "")
    }

    @Test
    func malformedBytesStillFailAtCap() {
        let malformedSequences: [[UInt8]] = [
            [0xFF], [0x80], [0xC0], [0xC1], [0xF5], [0xE0, 0x80], [0xED, 0xA0],
            [0xF0, 0x80], [0xF4, 0x90], [0xE3, 0x41], [0x41, 0xFF, 0x42],
        ]
        for sequence in malformedSequences {
            #expect(throws: Qwen3ASRError.invalidUTF8) {
                try decoder.transcript(generatedIDs: tokenIDs(sequence), endedAtTokenCap: true)
            }
        }
        #expect(throws: Qwen3ASRError.invalidUTF8) {
            try decoder.transcript(generatedIDs: tokenIDs([0xFF, 0xE3, 0x81]), endedAtTokenCap: true)
        }
    }

    @Test
    func retainsTranscriptMarkerStopSpecialAndWhitespaceRules() throws {
        let ids: [Int64] = [
            0x78, Qwen3ASRToken.asrText, 0x20, 0x41, 151_650, Qwen3ASRToken.imEnd,
            0x0A, 0x42, Qwen3ASRToken.endOfText, 0x20, 0x0A,
        ]
        #expect(try decoder.transcript(generatedIDs: ids, endedAtTokenCap: true) == "A\nB")
    }

    @Test
    func unknownIDsStillFailAtCap() {
        #expect(throws: Qwen3ASRError.unknownTokenID(151_999)) {
            try decoder.transcript(generatedIDs: [151_999], endedAtTokenCap: true)
        }
    }
}
