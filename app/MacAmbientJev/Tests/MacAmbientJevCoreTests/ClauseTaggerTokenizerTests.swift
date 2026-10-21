import Foundation
import Testing
import MacAmbientJevClauseTaggerFixtures
@testable import MacAmbientJevCore

private let releaseTokenizerSHA256 = "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"

private struct TokenizerFixtureDocument: Decodable {
    let schemaVersion: Int
    let tokenizerBackend: String
    let tokenizerSHA256: String
    let cases: [TokenizerFixtureCase]
    let syntheticTokenizers: [TokenizerSynthetic]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tokenizerBackend = "tokenizer_backend"
        case tokenizerSHA256 = "tokenizer_sha256"
        case cases
        case syntheticTokenizers = "synthetic_tokenizers"
    }
}

private struct TokenizerFixtureCase: Decodable {
    let name: String
    let tokenizer: String
    let text: String
    let next: String?
    let pieces: [TokenizerFixturePiece]
}

private struct TokenizerFixturePiece: Decodable {
    let text: String
    let tokenIDs: [Int]
    let ranges: [TextUTF16Range]

    enum CodingKeys: String, CodingKey {
        case text
        case tokenIDs = "token_ids"
        case ranges
    }
}

private struct TokenizerSynthetic: Decodable {
    let name: String
    let sha256: String
    let tokenizerJSON: JSONValue

    enum CodingKeys: String, CodingKey {
        case name
        case sha256
        case tokenizerJSON = "tokenizer_json"
    }
}

private indirect enum JSONValue: Codable {
    case null
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            self.intValue = intValue
            stringValue = String(intValue)
        }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var object: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                object[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !unkeyed.isAtEnd {
                array.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }

        let scalar = try decoder.singleValueContainer()
        if scalar.decodeNil() {
            self = .null
        } else if let value = try? scalar.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? scalar.decode(String.self) {
            self = .string(value)
        } else if let value = try? scalar.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .number(try scalar.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var scalar = encoder.singleValueContainer()
            try scalar.encodeNil()
        case .boolean(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .integer(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .number(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .string(let value):
            var scalar = encoder.singleValueContainer()
            try scalar.encode(value)
        case .array(let values):
            var array = encoder.unkeyedContainer()
            for value in values {
                try array.encode(value)
            }
        case .object(let values):
            var object = encoder.container(keyedBy: DynamicKey.self)
            for (name, value) in values {
                guard let key = DynamicKey(stringValue: name) else {
                    throw TokenizerTestError.invalidJSONKey(name)
                }
                try object.encode(value, forKey: key)
            }
        }
    }
}

private enum JSONPathComponent {
    case key(String)
    case index(Int)
}

private enum JSONEditOperation {
    case set(JSONValue)
    case remove
}

private struct JSONEdit {
    let path: [JSONPathComponent]
    let operation: JSONEditOperation
}

private struct TokenizerMutation {
    let name: String
    let expectedPath: String
    let edits: [JSONEdit]

    static func set(
        _ name: String,
        path: [JSONPathComponent],
        to value: JSONValue,
        expectedPath: String
    ) -> TokenizerMutation {
        TokenizerMutation(name: name, expectedPath: expectedPath, edits: [JSONEdit(path: path, operation: .set(value))])
    }

    static func remove(_ name: String, path: [JSONPathComponent], expectedPath: String) -> TokenizerMutation {
        TokenizerMutation(name: name, expectedPath: expectedPath, edits: [JSONEdit(path: path, operation: .remove)])
    }
}

private enum TokenizerTestError: Error {
    case invalidJSONKey(String)
    case invalidPath(String)
    case invalidFixture(String)
    case unsafeTemporaryPath(String)
}

private struct TemporaryTokenizerDirectory {
    let url: URL
    private let expectedResolvedURL: URL
    private let expectedResolvedParent: URL

    init() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let childName = "ClauseTaggerTokenizerTests-\(UUID().uuidString)"
        let child = parent.appendingPathComponent(childName, isDirectory: true).standardizedFileURL
        let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedChild.deletingLastPathComponent().path == parent.path,
              resolvedChild.lastPathComponent == childName,
              !fileManager.fileExists(atPath: child.path) else {
            throw TokenizerTestError.unsafeTemporaryPath(
                "child=\(child.path), resolved=\(resolvedChild.path), parent=\(parent.path), exists=\(fileManager.fileExists(atPath: child.path))"
            )
        }
        try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        guard child.resolvingSymlinksInPath().standardizedFileURL.path == resolvedChild.path else {
            throw TokenizerTestError.unsafeTemporaryPath(child.path)
        }
        url = child
        expectedResolvedURL = resolvedChild
        expectedResolvedParent = parent
    }

    func fileURL(named name: String) throws -> URL {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != ".." else {
            throw TokenizerTestError.unsafeTemporaryPath(name)
        }
        let child = url.appendingPathComponent(name).standardizedFileURL
        guard child.deletingLastPathComponent().path == url.standardizedFileURL.path else {
            throw TokenizerTestError.unsafeTemporaryPath(child.path)
        }
        return child
    }

    func cleanup() throws {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.path == expectedResolvedURL.path,
              resolvedURL.deletingLastPathComponent().path == expectedResolvedParent.path,
              resolvedURL.lastPathComponent.hasPrefix("ClauseTaggerTokenizerTests-") else {
            throw TokenizerTestError.unsafeTemporaryPath(resolvedURL.path)
        }
        try FileManager.default.removeItem(at: url)
    }
}

private struct ActualTokenizerPiece {
    let text: String
    let tokens: [ClauseTaggerToken]
}

@Suite
struct ClauseTaggerTokenizerTests {
    @Test
    func bundledFixtureMatchesPublicTokenizerAndOriginalEncoding() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.tokenizerBackend == "swift-transformers-1.3.4")
        #expect(fixture.tokenizerSHA256 == releaseTokenizerSHA256)
        #expect(fixture.cases.count == 47)
        let storedPieceCount = fixture.cases.reduce(0) { $0 + $1.pieces.count }
        #expect(storedPieceCount == 106)
        #expect(fixture.syntheticTokenizers.count == 2)
        #expect(Set(fixture.syntheticTokenizers.map(\.name)) == Set(["ties-forward", "ties-reversed"]))
        for synthetic in fixture.syntheticTokenizers {
            #expect(isLowercaseSHA256(synthetic.sha256), "synthetic \(synthetic.name) SHA is provenance only")
        }

        let temporary = try makeTemporaryDirectory()
        defer { cleanup(temporary) }
        let tokenizerURL = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerTokenizer")
        let bundledSHA256 = try FileSHA256.hexDigest(ofFileAt: tokenizerURL)
        #expect(bundledSHA256 == fixture.tokenizerSHA256)
        #expect(bundledSHA256 == releaseTokenizerSHA256)
        let releaseTokenizer = try ClauseTaggerTokenizer(
            tokenizerURL: tokenizerURL,
            expectedSHA256: fixture.tokenizerSHA256
        )

        var syntheticTokenizers: [String: ClauseTaggerTokenizer] = [:]
        for synthetic in fixture.syntheticTokenizers {
            let serialized = try JSONEncoder().encode(synthetic.tokenizerJSON)
            let syntheticURL = try temporary.fileURL(named: "\(synthetic.name).json")
            try serialized.write(to: syntheticURL)
            let serializedSHA256 = try FileSHA256.hexDigest(ofFileAt: syntheticURL)
            syntheticTokenizers[synthetic.name] = try ClauseTaggerTokenizer(
                tokenizerURL: syntheticURL,
                expectedSHA256: serializedSHA256
            )
        }
        #expect(syntheticTokenizers["ties-forward"] != nil)
        #expect(syntheticTokenizers["ties-reversed"] != nil)

        var tieCaseCount = 0
        for (caseIndex, fixtureCase) in fixture.cases.enumerated() {
            let tokenizer: ClauseTaggerTokenizer
            if fixtureCase.tokenizer == "release" {
                tokenizer = releaseTokenizer
            } else {
                guard let syntheticTokenizer = syntheticTokenizers[fixtureCase.tokenizer] else {
                    Issue.record("case \(caseIndex) '\(fixtureCase.name)' names unknown tokenizer '\(fixtureCase.tokenizer)'")
                    continue
                }
                tokenizer = syntheticTokenizer
            }
            if fixtureCase.tokenizer == "ties-forward" || fixtureCase.tokenizer == "ties-reversed" {
                tieCaseCount += 1
            }
            for (pieceIndex, expected) in fixtureCase.pieces.enumerated() {
                let storedPieceTokens = try tokenizer.encodePiece(expected.text)
                assertTokens(
                    storedPieceTokens,
                    match: expected,
                    context: "case \(caseIndex) '\(fixtureCase.name)' piece \(pieceIndex)"
                )
            }

            if fixtureCase.name.hasPrefix("original-") {
                var actualPieces: [ActualTokenizerPiece] = []
                _ = try ClauseTaggerEncoding.encode(text: fixtureCase.text, next: fixtureCase.next) { pieceText in
                    let tokens = try tokenizer.encodePiece(pieceText)
                    actualPieces.append(ActualTokenizerPiece(text: pieceText, tokens: tokens))
                    return tokens
                }
                #expect(
                    actualPieces.count == fixtureCase.pieces.count,
                    "case \(caseIndex) '\(fixtureCase.name)' piece count"
                )
                guard actualPieces.count == fixtureCase.pieces.count else { continue }
                for pieceIndex in fixtureCase.pieces.indices {
                    let expected = fixtureCase.pieces[pieceIndex]
                    let actual = actualPieces[pieceIndex]
                    let context = "case \(caseIndex) '\(fixtureCase.name)' piece \(pieceIndex)"
                    #expect(
                        Data(actual.text.utf8) == Data(expected.text.utf8),
                        "\(context) text must match byte-for-byte"
                    )
                    assertTokens(actual.tokens, match: expected, context: context)
                }
            } else {
                #expect(
                    fixtureCase.pieces.count == 1,
                    "case \(caseIndex) '\(fixtureCase.name)' must store one direct piece"
                )
                guard fixtureCase.pieces.count == 1 else { continue }
                let expected = fixtureCase.pieces[0]
                #expect(
                    Data(expected.text.utf8) == Data(fixtureCase.text.utf8),
                    "case \(caseIndex) '\(fixtureCase.name)' direct piece must equal input bytes"
                )
                let actual = try tokenizer.encodePiece(fixtureCase.text)
                assertTokens(actual, match: expected, context: "case \(caseIndex) '\(fixtureCase.name)' piece 0")
            }
        }
        #expect(tieCaseCount == 8)
        for expectedName in ["ties-forward-ab", "ties-forward-aba", "ties-forward-abab", "ties-forward-baba",
                             "ties-reversed-ab", "ties-reversed-aba", "ties-reversed-abab", "ties-reversed-baba"] {
            #expect(fixture.cases.contains { $0.name == expectedName }, "missing expected fixture lookup name \(expectedName)")
        }
        print("ClauseTagger tokenizer fixture: cases=\(fixture.cases.count), pieces=\(storedPieceCount), ties=\(tieCaseCount)")
    }

    @Test
    func publicInitializerReportsHashReadAndTypedParseFailures() throws {
        let fixture = try loadFixture()
        let releaseURL = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerTokenizer")
        let actualSHA256 = try FileSHA256.hexDigest(ofFileAt: releaseURL)
        let temporary = try makeTemporaryDirectory()
        defer { cleanup(temporary) }

        let wrongHashDetail = invalidConfigurationDetail {
            _ = try ClauseTaggerTokenizer(
                tokenizerURL: releaseURL,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        }
        #expect(wrongHashDetail.contains("SHA-256"))
        #expect(wrongHashDetail.contains("expected: \(String(repeating: "0", count: 64))"))
        #expect(wrongHashDetail.contains("actual: \(actualSHA256)"))
        #expect(actualSHA256 == fixture.tokenizerSHA256)

        let missingURL = try temporary.fileURL(named: "missing-tokenizer.json")
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))
        let missingDetail = invalidConfigurationDetail {
            _ = try ClauseTaggerTokenizer(tokenizerURL: missingURL, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(missingDetail.contains("tokenizer.json を読み込めません"))
        #expect(!missingDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let malformedURL = try temporary.fileURL(named: "malformed-tokenizer.json")
        let malformedBytes = Data("{not-json".utf8)
        try malformedBytes.write(to: malformedURL)
        let malformedSHA256 = try FileSHA256.hexDigest(ofFileAt: malformedURL)
        let malformedDetail = invalidConfigurationDetail {
            _ = try ClauseTaggerTokenizer(tokenizerURL: malformedURL, expectedSHA256: malformedSHA256)
        }
        #expect(malformedDetail.contains("tokenizer.json"))
        #expect(malformedDetail.contains("JSON" ) || malformedDetail.contains("json"))
        #expect(!malformedDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test
    func embeddedSyntheticConfigurationRejectsEveryPinnedMutation() throws {
        let fixture = try loadFixture()
        let firstSynthetic = try requireSynthetic(fixture.syntheticTokenizers.first, name: "first synthetic tokenizer")
        let mutations = try negativeMutations(from: firstSynthetic.tokenizerJSON)
        let temporary = try makeTemporaryDirectory()
        defer { cleanup(temporary) }

        for (index, mutation) in mutations.enumerated() {
            var configuration = firstSynthetic.tokenizerJSON
            for edit in mutation.edits {
                try apply(edit, to: &configuration)
            }
            let bytes = try JSONEncoder().encode(configuration)
            let url = try temporary.fileURL(named: "mutation-\(index).json")
            try bytes.write(to: url)
            let expectedSHA256 = try FileSHA256.hexDigest(ofFileAt: url)
            let detail = invalidConfigurationDetail {
                _ = try ClauseTaggerTokenizer(tokenizerURL: url, expectedSHA256: expectedSHA256)
            }
            #expect(
                detail.contains(mutation.expectedPath),
                "mutation \(index) '\(mutation.name)' should identify \(mutation.expectedPath); got: \(detail)"
            )
            let reason = detail.replacingOccurrences(of: mutation.expectedPath, with: "")
            #expect(
                !reason.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":"))).isEmpty,
                "mutation \(index) '\(mutation.name)' should include a nonempty validation reason"
            )
        }
        print("ClauseTagger tokenizer invalid-configuration mutations: \(mutations.count)")
    }

    @Test
    func syntheticSemanticWitnessesPreserveUnicodeFloatTiesAndFallback() throws {
        let fixture = try loadFixture()
        let firstSynthetic = try requireSynthetic(fixture.syntheticTokenizers.first, name: "first synthetic tokenizer")
        let temporary = try makeTemporaryDirectory()
        defer { cleanup(temporary) }

        let syntheticPrefix = try vocabularyPrefix(firstSynthetic.tokenizerJSON, count: 276)
        let canonicalVariants = try appendingVocabulary(
            [("é", -1), ("e\u{301}", -1)],
            to: syntheticPrefix
        )
        let canonicalTokenizer = try makeTokenizer(canonicalVariants, named: "canonical", in: temporary)
        let composed = try canonicalTokenizer.encodePiece("é")
        let decomposed = try canonicalTokenizer.encodePiece("e\u{301}")
        #expect(composed.map(\.id) == [276])
        #expect(composed.map(\.range) == [try TextUTF16Range(start: 0, end: 1)])
        #expect(decomposed.map(\.id) == [277])
        #expect(decomposed.map(\.range) == [try TextUTF16Range(start: 0, end: 2)])

        let floatTieConfiguration = try appendingVocabulary(
            [("a", 1), ("b", 0), ("ab", 0), ("c", -33_554_432)],
            to: syntheticPrefix
        )
        let floatTieTokenizer = try makeTokenizer(floatTieConfiguration, named: "float-tie", in: temporary)
        let floatTie = try floatTieTokenizer.encodePiece("abc")
        #expect(floatTie.map(\.id) == [278, 279])
        #expect(floatTie.map(\.range) == [
            try TextUTF16Range(start: 0, end: 2),
            try TextUTF16Range(start: 2, end: 3)
        ])

        let scalarLatticeConfiguration = try appendingVocabulary(
            [("xy", -1)],
            to: syntheticPrefix
        )
        let scalarLatticeTokenizer = try makeTokenizer(scalarLatticeConfiguration, named: "scalar-lattice", in: temporary)
        let fallback = try scalarLatticeTokenizer.encodePiece("y")
        #expect(fallback.map(\.id) == [136])
        #expect(fallback.map(\.range) == [try TextUTF16Range(start: 0, end: 1)])
        // Adjacent unknown lattice pieces cannot satisfy the byte-exact reconstruction contract.
        for text in ["yy", "yx"] {
            do {
                _ = try scalarLatticeTokenizer.encodePiece(text)
                Issue.record("Expected unrepresentableText for \(text)")
            } catch let error as ClauseTaggerTokenizerError {
                guard case .unrepresentableText = error else {
                    Issue.record("Unexpected ClauseTaggerTokenizerError for \(text): \(error)")
                    continue
                }
            } catch {
                Issue.record("Unexpected error for \(text): \(error)")
            }
        }
        let separatedUnknowns = try scalarLatticeTokenizer.encodePiece("yxy")
        #expect(separatedUnknowns.map(\.id) == [136, 276])
        #expect(separatedUnknowns.map(\.range) == [
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 3)
        ])

        let releaseURL = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerTokenizer")
        let releaseSHA256 = try FileSHA256.hexDigest(ofFileAt: releaseURL)
        let releaseTokenizer = try ClauseTaggerTokenizer(tokenizerURL: releaseURL, expectedSHA256: releaseSHA256)
        #expect(try releaseTokenizer.encodePiece("" ).isEmpty)
        let literalCLS = try releaseTokenizer.encodePiece("<cls>")
        #expect(literalCLS.map(\.id) == [6])
        #expect(!literalCLS.contains { [1, 2, 4, 6].contains($0.id) && $0.id != 6 })
    }

    @Test
    func tokenizerPreservesVocabularyAndByteFallbackTokenRanges() throws {
        let fixture = try loadFixture()
        let firstSynthetic = try requireSynthetic(fixture.syntheticTokenizers.first, name: "first synthetic tokenizer")
        let syntheticPrefix = try vocabularyPrefix(firstSynthetic.tokenizerJSON, count: 276)
        let byteOrderMark = "\u{FEFF}"
        let vocabularyWithByteOrderMark = try appendingVocabulary([(byteOrderMark, -1)], to: syntheticPrefix)
        let temporary = try makeTemporaryDirectory()
        defer { cleanup(temporary) }
        let tokenizer = try makeTokenizer(vocabularyWithByteOrderMark, named: "token-ranges", in: temporary)

        let encodedByteOrderMark = try tokenizer.encodePiece(byteOrderMark)
        #expect(encodedByteOrderMark.map(\.id) == [276])
        #expect(encodedByteOrderMark.map(\.range) == [try TextUTF16Range(start: 0, end: 1)])

        let encodedSpacesAndEmoji = try tokenizer.encodePiece(" 😀 ")
        #expect(encodedSpacesAndEmoji.map(\.id) == [271, 255, 174, 167, 143, 271])
        #expect(encodedSpacesAndEmoji.map(\.range) == [
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 3),
            try TextUTF16Range(start: 1, end: 3),
            try TextUTF16Range(start: 1, end: 3),
            try TextUTF16Range(start: 1, end: 3),
            try TextUTF16Range(start: 3, end: 4)
        ])

        let encodedRepeatedEmoji = try tokenizer.encodePiece("😀😀")
        #expect(encodedRepeatedEmoji.map(\.id) == [255, 174, 167, 143, 255, 174, 167, 143])
        #expect(encodedRepeatedEmoji.map(\.range) == Array(repeating: try TextUTF16Range(start: 0, end: 4), count: 8))

        let encodedSeparatedUnknownRuns = try tokenizer.encodePiece(" 😀😀 😀 ")
        #expect(encodedSeparatedUnknownRuns.map(\.id) == [
            271, 255, 174, 167, 143, 255, 174, 167, 143, 271, 255, 174, 167, 143, 271
        ])
        #expect(encodedSeparatedUnknownRuns.map(\.range) == [
            try TextUTF16Range(start: 0, end: 1),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 1, end: 5),
            try TextUTF16Range(start: 5, end: 6),
            try TextUTF16Range(start: 6, end: 8),
            try TextUTF16Range(start: 6, end: 8),
            try TextUTF16Range(start: 6, end: 8),
            try TextUTF16Range(start: 6, end: 8),
            try TextUTF16Range(start: 8, end: 9)
        ])
    }
}

private func loadFixture() throws -> TokenizerFixtureDocument {
    let url = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerTokenizerFixtures")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TokenizerFixtureDocument.self, from: data)
}

private func assertTokens(
    _ actual: [ClauseTaggerToken],
    match expected: TokenizerFixturePiece,
    context: String
) {
    #expect(actual.count == expected.tokenIDs.count, "\(context) token ID count")
    #expect(actual.count == expected.ranges.count, "\(context) range count")
    guard actual.count == expected.tokenIDs.count, actual.count == expected.ranges.count else { return }
    #expect(actual.map(\.id) == expected.tokenIDs, "\(context) token IDs")
    #expect(actual.map(\.range) == expected.ranges, "\(context) UTF-16 ranges")
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

private func makeTemporaryDirectory() throws -> TemporaryTokenizerDirectory {
    try TemporaryTokenizerDirectory()
}

private func cleanup(_ temporary: TemporaryTokenizerDirectory) {
    do {
        try temporary.cleanup()
    } catch {
        Issue.record("Could not safely clean tokenizer test directory: \(error)")
    }
}

private func invalidConfigurationDetail(
    _ operation: () throws -> Void
) -> String {
    do {
        try operation()
        Issue.record("Expected ClauseTaggerTokenizerError.invalidConfiguration, but initialization succeeded.")
    } catch let error as ClauseTaggerTokenizerError {
        switch error {
        case .invalidConfiguration(let detail):
            return detail
        case .unrepresentableText:
            Issue.record("Expected invalidConfiguration, got unrepresentableText.")
        }
    } catch {
        Issue.record("Expected ClauseTaggerTokenizerError.invalidConfiguration, got \(error).")
    }
    return ""
}

private func requireSynthetic(_ value: TokenizerSynthetic?, name: String) throws -> TokenizerSynthetic {
    guard let value else { throw TokenizerTestError.invalidFixture("Missing \(name).") }
    return value
}

private func negativeMutations(from base: JSONValue) throws -> [TokenizerMutation] {
    let topLevelFields = [
        "version", "truncation", "padding", "added_tokens", "normalizer",
        "pre_tokenizer", "post_processor", "decoder", "model"
    ]
    var mutations = topLevelFields.map { key in
        TokenizerMutation.remove("missing top-level \(key)", path: path(.key(key)), expectedPath: "$.\(key)")
    }
    mutations.append(.set(
        "unknown top-level key",
        path: path(.key("unrecognized")),
        to: .boolean(true),
        expectedPath: "$.unrecognized"
    ))
    mutations.append(.set("wrong version", path: path(.key("version")), to: .string("2.0"), expectedPath: "$.version"))
    for key in ["truncation", "padding", "normalizer"] {
        mutations.append(.set(
            "nonnull \(key)",
            path: path(.key(key)),
            to: .object([:]),
            expectedPath: "$.\(key)"
        ))
    }

    let vocabulary = try jsonArray(at: path(.key("model"), .key("vocab")), in: base)
    guard vocabulary.count >= 277 else {
        throw TokenizerTestError.invalidFixture("Synthetic vocabulary needs at least 277 entries; found \(vocabulary.count).")
    }
    let firstToken = try jsonString(at: path(.key("model"), .key("vocab"), .index(0), .index(0)), in: base)
    let pair276 = try jsonArray(at: path(.key("model"), .key("vocab"), .index(276)), in: base)
    let pair276WithExtra = pair276 + [.null]
    mutations.append(.set("model is not an object", path: path(.key("model")), to: .string("Unigram"), expectedPath: "$.model"))
    mutations.append(.set("model type is wrong", path: path(.key("model"), .key("type")), to: .string("BPE"), expectedPath: "$.model.type"))
    for key in ["byte_fallback", "unk_id", "vocab"] {
        mutations.append(.remove(
            "missing model \(key)",
            path: path(.key("model"), .key(key)),
            expectedPath: "$.model.\(key)"
        ))
    }
    mutations.append(.set(
        "byte fallback disabled",
        path: path(.key("model"), .key("byte_fallback")),
        to: .boolean(false),
        expectedPath: "$.model.byte_fallback"
    ))
    mutations.append(.set("negative unknown ID", path: path(.key("model"), .key("unk_id")), to: .integer(-1), expectedPath: "$.model.unk_id"))
    mutations.append(.set("nonzero unknown ID", path: path(.key("model"), .key("unk_id")), to: .integer(1), expectedPath: "$.model.unk_id"))
    mutations.append(.set(
        "vocabulary too short",
        path: path(.key("model"), .key("vocab")),
        to: .array(Array(vocabulary.prefix(275))),
        expectedPath: "$.model.vocab"
    ))
    mutations.append(.set(
        "empty vocabulary token",
        path: path(.key("model"), .key("vocab"), .index(10), .index(0)),
        to: .string(""),
        expectedPath: "$.model.vocab[10][0]"
    ))
    mutations.append(.set(
        "byte-identical duplicate vocabulary token",
        path: path(.key("model"), .key("vocab"), .index(276), .index(0)),
        to: .string(firstToken),
        expectedPath: "$.model.vocab[276][0]"
    ))
    mutations.append(.set(
        "vocabulary tuple has extra element",
        path: path(.key("model"), .key("vocab"), .index(276)),
        to: .array(pair276WithExtra),
        expectedPath: "$.model.vocab[276]"
    ))
    mutations.append(.set(
        "vocabulary score is not numeric",
        path: path(.key("model"), .key("vocab"), .index(276), .index(1)),
        to: .string("not-a-score"),
        expectedPath: "$.model.vocab[276][1]"
    ))
    mutations.append(.set(
        "vocabulary score overflows Float",
        path: path(.key("model"), .key("vocab"), .index(276), .index(1)),
        to: .number(1e100),
        expectedPath: "$.model.vocab[276][1]"
    ))
    for id in [0, 1, 2, 3, 4, 5, 6, 275] {
        mutations.append(.set(
            "wrong fixed vocabulary spelling at \(id)",
            path: path(.key("model"), .key("vocab"), .index(id), .index(0)),
            to: .string("<wrong-fixed-\(id)>"),
            expectedPath: "$.model.vocab[\(id)][0]"
        ))
    }
    for id in [15, 270] {
        var shortened = vocabulary
        shortened.remove(at: id)
        mutations.append(.set(
            "missing byte token at \(id)",
            path: path(.key("model"), .key("vocab")),
            to: .array(shortened),
            expectedPath: "$.model.vocab[\(id)][0]"
        ))
        mutations.append(.set(
            "misspelled byte token at \(id)",
            path: path(.key("model"), .key("vocab"), .index(id), .index(0)),
            to: .string("<not-byte-token-\(id)>"),
            expectedPath: "$.model.vocab[\(id)][0]"
        ))
    }

    for (key, value) in [
        ("type", JSONValue.string("ByteLevel")),
        ("replacement", JSONValue.string("x")),
        ("prepend_scheme", JSONValue.string("always")),
        ("split", JSONValue.boolean(true))
    ] {
        mutations.append(.set(
            "wrong Metaspace \(key)",
            path: path(.key("pre_tokenizer"), .key(key)),
            to: value,
            expectedPath: "$.pre_tokenizer.\(key)"
        ))
        mutations.append(.remove(
            "missing Metaspace \(key)",
            path: path(.key("pre_tokenizer"), .key(key)),
            expectedPath: "$.pre_tokenizer.\(key)"
        ))
    }

    let single = try jsonArray(at: path(.key("post_processor"), .key("single")), in: base)
    let postSpecialID = path(.key("post_processor"), .key("single"), .index(0), .key("SpecialToken"), .key("id"))
    let postTypeID = path(.key("post_processor"), .key("single"), .index(0), .key("SpecialToken"), .key("type_id"))
    mutations.append(.set("null post_processor", path: path(.key("post_processor")), to: .null, expectedPath: "$.post_processor"))
    mutations.append(.set(
        "wrong template sequence element",
        path: path(.key("post_processor"), .key("single"), .index(1)),
        to: .null,
        expectedPath: "$.post_processor"
    ))
    mutations.append(.set(
        "wrong template sequence order",
        path: path(.key("post_processor"), .key("single")),
        to: .array(Array(single.reversed())),
        expectedPath: "$.post_processor"
    ))
    mutations.append(.set("wrong template type_id", path: postTypeID, to: .integer(1), expectedPath: "$.post_processor"))
    mutations.append(.set("wrong template special ID", path: postSpecialID, to: .string("</s>"), expectedPath: "$.post_processor"))
    mutations.append(.set(
        "wrong special-token ID list",
        path: path(.key("post_processor"), .key("special_tokens"), .key("<s>"), .key("ids")),
        to: .array([.integer(99)]),
        expectedPath: "$.post_processor"
    ))
    mutations.append(.set(
        "extra post_processor key",
        path: path(.key("post_processor"), .key("unexpected")),
        to: .boolean(true),
        expectedPath: "$.post_processor"
    ))

    let decoders = try jsonArray(at: path(.key("decoder"), .key("decoders")), in: base)
    mutations.append(.set("null decoder", path: path(.key("decoder")), to: .null, expectedPath: "$.decoder"))
    mutations.append(.set(
        "wrong Replace pattern",
        path: path(.key("decoder"), .key("decoders"), .index(0), .key("pattern")),
        to: .object(["String": .string("x")]),
        expectedPath: "$.decoder"
    ))
    mutations.append(.set(
        "wrong Replace content",
        path: path(.key("decoder"), .key("decoders"), .index(0), .key("content")),
        to: .string("x"),
        expectedPath: "$.decoder"
    ))
    mutations.append(.set(
        "wrong decoder order",
        path: path(.key("decoder"), .key("decoders")),
        to: .array([decoders[1], decoders[0], decoders[2]]),
        expectedPath: "$.decoder"
    ))
    var withoutByteFallback = decoders
    withoutByteFallback.remove(at: 1)
    mutations.append(.set(
        "missing ByteFallback decoder",
        path: path(.key("decoder"), .key("decoders")),
        to: .array(withoutByteFallback),
        expectedPath: "$.decoder"
    ))
    var withoutFuse = decoders
    withoutFuse.remove(at: 2)
    mutations.append(.set(
        "missing Fuse decoder",
        path: path(.key("decoder"), .key("decoders")),
        to: .array(withoutFuse),
        expectedPath: "$.decoder"
    ))

    let addedTokens = try jsonArray(at: path(.key("added_tokens")), in: base)
    guard addedTokens.count > 7 else {
        throw TokenizerTestError.invalidFixture("Synthetic configuration must retain added-token IDs 0 through 7.")
    }
    let addedZeroContent = try jsonString(at: path(.key("added_tokens"), .index(0), .key("content")), in: base)
    mutations.append(.set(
        "added_tokens is not an array",
        path: path(.key("added_tokens")),
        to: .string("wrong"),
        expectedPath: "$.added_tokens"
    ))
    mutations.append(.set(
        "added-token ID outside vocabulary",
        path: path(.key("added_tokens"), .index(0), .key("id")),
        to: .integer(100_000),
        expectedPath: "$.added_tokens[0].id"
    ))
    mutations.append(.remove(
        "added-token id field missing",
        path: path(.key("added_tokens"), .index(0), .key("id")),
        expectedPath: "$.added_tokens[0].id"
    ))
    var withoutRequiredID = addedTokens
    withoutRequiredID.remove(at: 1)
    mutations.append(.set(
        "required added-token ID missing",
        path: path(.key("added_tokens")),
        to: .array(withoutRequiredID),
        expectedPath: "$.added_tokens"
    ))
    mutations.append(TokenizerMutation(
        name: "duplicate added-token ID",
        expectedPath: "$.added_tokens[1].id",
        edits: [
            JSONEdit(path: path(.key("added_tokens"), .index(1), .key("id")), operation: .set(.integer(0))),
            JSONEdit(path: path(.key("added_tokens"), .index(1), .key("content")), operation: .set(.string(addedZeroContent)))
        ]
    ))
    mutations.append(.set(
        "added-token content mismatch",
        path: path(.key("added_tokens"), .index(0), .key("content")),
        to: .string("not-the-vocabulary-token"),
        expectedPath: "$.added_tokens[0].content"
    ))
    for flag in ["single_word", "lstrip", "rstrip", "normalized"] {
        mutations.append(.set(
            "added-token \(flag) enabled",
            path: path(.key("added_tokens"), .index(0), .key(flag)),
            to: .boolean(true),
            expectedPath: "$.added_tokens[0].\(flag)"
        ))
        mutations.append(.remove(
            "added-token \(flag) missing",
            path: path(.key("added_tokens"), .index(0), .key(flag)),
            expectedPath: "$.added_tokens[0].\(flag)"
        ))
    }
    mutations.append(.set(
        "special added-token flag wrong",
        path: path(.key("added_tokens"), .index(0), .key("special")),
        to: .boolean(false),
        expectedPath: "$.added_tokens[0].special"
    ))
    mutations.append(.set(
        "non-special added-token flag wrong",
        path: path(.key("added_tokens"), .index(7), .key("special")),
        to: .boolean(true),
        expectedPath: "$.added_tokens[7].special"
    ))
    return mutations
}

private func vocabularyPrefix(_ base: JSONValue, count: Int) throws -> JSONValue {
    var configuration = base
    let vocabulary = try jsonArray(at: path(.key("model"), .key("vocab")), in: base)
    guard vocabulary.count >= count else {
        throw TokenizerTestError.invalidFixture("Synthetic vocabulary has fewer than \(count) prefix entries.")
    }
    try apply(
        JSONEdit(
            path: path(.key("model"), .key("vocab")),
            operation: .set(.array(Array(vocabulary.prefix(count))))
        ),
        to: &configuration
    )
    return configuration
}

private func appendingVocabulary(_ entries: [(String, Double)], to base: JSONValue) throws -> JSONValue {
    var configuration = base
    var vocabulary = try jsonArray(at: path(.key("model"), .key("vocab")), in: base)
    vocabulary.append(contentsOf: entries.map { token, score in
        .array([.string(token), .number(score)])
    })
    try apply(
        JSONEdit(
            path: path(.key("model"), .key("vocab")),
            operation: .set(.array(vocabulary))
        ),
        to: &configuration
    )
    return configuration
}

private func makeTokenizer(
    _ configuration: JSONValue,
    named name: String,
    in temporary: TemporaryTokenizerDirectory
) throws -> ClauseTaggerTokenizer {
    let bytes = try JSONEncoder().encode(configuration)
    let url = try temporary.fileURL(named: "\(name).json")
    try bytes.write(to: url)
    let expectedSHA256 = try FileSHA256.hexDigest(ofFileAt: url)
    return try ClauseTaggerTokenizer(tokenizerURL: url, expectedSHA256: expectedSHA256)
}

private func path(_ components: JSONPathComponent...) -> [JSONPathComponent] {
    components
}

private func apply(_ edit: JSONEdit, to value: inout JSONValue) throws {
    try apply(edit.operation, along: ArraySlice(edit.path), to: &value)
}

private func apply(
    _ operation: JSONEditOperation,
    along components: ArraySlice<JSONPathComponent>,
    to value: inout JSONValue
) throws {
    guard let first = components.first else {
        guard case .set(let replacement) = operation else {
            throw TokenizerTestError.invalidPath("Cannot remove the JSON document root.")
        }
        value = replacement
        return
    }
    let remaining = components.dropFirst()
    switch first {
    case .key(let key):
        guard case .object(var object) = value else {
            throw TokenizerTestError.invalidPath("Expected an object while editing key \(key).")
        }
        if remaining.isEmpty {
            switch operation {
            case .set(let replacement):
                object[key] = replacement
            case .remove:
                guard object.removeValue(forKey: key) != nil else {
                    throw TokenizerTestError.invalidPath("Missing object key \(key).")
                }
            }
        } else {
            guard var child = object[key] else {
                throw TokenizerTestError.invalidPath("Missing object key \(key).")
            }
            try apply(operation, along: remaining, to: &child)
            object[key] = child
        }
        value = .object(object)
    case .index(let index):
        guard case .array(var array) = value, array.indices.contains(index) else {
            throw TokenizerTestError.invalidPath("Missing array index \(index).")
        }
        if remaining.isEmpty {
            switch operation {
            case .set(let replacement):
                array[index] = replacement
            case .remove:
                array.remove(at: index)
            }
        } else {
            var child = array[index]
            try apply(operation, along: remaining, to: &child)
            array[index] = child
        }
        value = .array(array)
    }
}

private func jsonValue(at path: [JSONPathComponent], in root: JSONValue) throws -> JSONValue {
    var current = root
    for component in path {
        switch component {
        case .key(let key):
            guard case .object(let object) = current, let child = object[key] else {
                throw TokenizerTestError.invalidPath("Missing object key \(key).")
            }
            current = child
        case .index(let index):
            guard case .array(let array) = current, array.indices.contains(index) else {
                throw TokenizerTestError.invalidPath("Missing array index \(index).")
            }
            current = array[index]
        }
    }
    return current
}

private func jsonArray(at path: [JSONPathComponent], in root: JSONValue) throws -> [JSONValue] {
    guard case .array(let array) = try jsonValue(at: path, in: root) else {
        throw TokenizerTestError.invalidFixture("Expected an array at \(pathDescription(path)).")
    }
    return array
}

private func jsonString(at path: [JSONPathComponent], in root: JSONValue) throws -> String {
    guard case .string(let string) = try jsonValue(at: path, in: root) else {
        throw TokenizerTestError.invalidFixture("Expected a string at \(pathDescription(path)).")
    }
    return string
}

private func pathDescription(_ path: [JSONPathComponent]) -> String {
    path.reduce("$") { result, component in
        switch component {
        case .key(let key): "\(result).\(key)"
        case .index(let index): "\(result)[\(index)]"
        }
    }
}
