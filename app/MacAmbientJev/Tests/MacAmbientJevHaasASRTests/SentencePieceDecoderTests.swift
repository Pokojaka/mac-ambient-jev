import Foundation
import Testing
@testable import MacAmbientJevHaasASR

private struct GoldenFile: Decodable { let cases: [GoldenCase] }
private struct GoldenCase: Decodable { let ids: [Int]; let expected: String }

private func decoder() throws -> SentencePieceDecoder {
    let url = try #require(Bundle.module.url(forResource: "tokenizer", withExtension: "model", subdirectory: "Resources"))
    return try SentencePieceDecoder(modelData: Data(contentsOf: url))
}

struct SentencePieceDecoderTests {
    @Test
    func matchesReferenceGolden() throws {
        let goldenURL = try #require(Bundle.module.url(forResource: "haas_spm_golden", withExtension: "json", subdirectory: "Resources"))
        let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: goldenURL))
        #expect(golden.cases.count == 3575)
        let tokenizer = try decoder()
        for item in golden.cases {
            let actual = tokenizer.decode(item.ids)
            #expect(actual.utf8.elementsEqual(item.expected.utf8))
        }
        print("SentencePieceDecoderTests matched 3575 cases")
    }

    @Test
    func rejectsTruncatedTokenizer() throws {
        let url = try #require(Bundle.module.url(forResource: "tokenizer", withExtension: "model", subdirectory: "Resources"))
        let model = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { try SentencePieceDecoder(modelData: Data(model.prefix(1))) }
        #expect(throws: (any Error).self) { try SentencePieceDecoder(modelData: Data(model.dropLast())) }
    }

    @Test
    func rejectsWrongPieceCount() {
        let oneNormalPiece: [UInt8] = [0x0a, 0x03, 0x0a, 0x01, 0x61]
        #expect(throws: (any Error).self) { try SentencePieceDecoder(modelData: Data(oneNormalPiece)) }
    }

    @Test(arguments: [
        ([UInt8](arrayLiteral: 0xe2, 0x82), "��"),
        ([UInt8](arrayLiteral: 0xf0, 0x9f), "��"),
        ([UInt8](arrayLiteral: 0xed, 0xa0, 0x80), "���"),
        ([UInt8](arrayLiteral: 0xc0, 0xaf), "��"),
        ([UInt8](arrayLiteral: 0xf4, 0x90, 0x80, 0x80), "����")
    ])
    func invalidByteRunsConsumeOneBytePerReplacement(_ bytes: [UInt8], _ expected: String) throws {
        let actual = try decoder().decode(bytes.map { Int($0) + 1 })
        #expect(actual.utf8.elementsEqual(expected.utf8))
    }

    @Test
    func dummyPrefixHandlingMatchesReferenceProbes() throws {
        let tokenizer = try decoder()
        #expect(tokenizer.decode([]).utf8.elementsEqual("".utf8))
        #expect(tokenizer.decode([587, 587]).utf8.elementsEqual(" ".utf8))
        #expect(tokenizer.decode([33, 587]).utf8.elementsEqual("  ".utf8))
        #expect(tokenizer.decode([0, 587]).utf8.elementsEqual(" ⁇  ".utf8))
    }
}
