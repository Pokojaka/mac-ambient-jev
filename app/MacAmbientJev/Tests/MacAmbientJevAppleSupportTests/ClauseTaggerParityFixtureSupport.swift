import CoreFoundation
import CryptoKit
import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport
import MacAmbientJevClauseTaggerFixtures

internal enum ClauseTaggerParityFixtureSupport {
    static let tokenizerFixtureName = "ClauseTaggerTokenizerFixtures"
    static let requestFixtureName = "ClauseTaggerRequestFixtures"
    private static let comparisonTolerance = 1e-3
    private static let probabilitySumTolerance = 1e-5
    private static let tolerantFields: Set<String> = [
        "boundary_probs", "span_probs", "priority_probs", "probabilities", "confidence",
        "continuation_probability"
    ]

    enum FixtureError: LocalizedError {
        case setup(String)
        case invalid(String)
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .setup(let detail): "ClauseTagger parity fixture setup failed: \(detail)"
            case .invalid(let detail): "ClauseTagger parity fixture is invalid: \(detail)"
            case .mismatch(let detail): "ClauseTagger parity fixture mismatch: \(detail)"
            }
        }
    }

    private struct CapturedCall {
        let document: [String: Any]
        let encoded: ClauseTaggerEncodedInput
        let prediction: ClauseTaggerPrediction
    }

    static var testIsEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RUN_CLAUSE_TAGGER_TESTS"] == "1"
            || environment["MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY"] == "1"
    }

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_CLAUSE_TAGGER_TESTS"] == "1" else {
            throw FixtureError.setup(
                "MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY=1 requires RUN_CLAUSE_TAGGER_TESTS=1."
            )
        }
        let writeMode = environment["MAC_AMBIENT_JEV_WRITE_CLAUSE_TAGGER_PARITY"] == "1"
        let modelDirectory = try requiredModelDirectory(environment: environment)
        let original = try ClauseTaggerFixtures.loadOriginal()
        guard original.fixtures.count == 13 else {
            throw FixtureError.invalid("The original fixture document must contain exactly 13 cases.")
        }

        let tokenizerURL = modelDirectory.appending(path: "tokenizer.json")
        let tokenizerBytes: Data
        do {
            tokenizerBytes = try Data(contentsOf: tokenizerURL)
        } catch {
            throw FixtureError.setup("Cannot read tokenizer.json: \(error.localizedDescription)")
        }
        let tokenizerSHA256 = sha256(tokenizerBytes)
        guard tokenizerSHA256 == original.tokenizerSHA256 else {
            throw FixtureError.invalid("The supplied tokenizer SHA-256 does not match the original fixture.")
        }
        let tokenizer = try ClauseTaggerTokenizer(
            tokenizerURL: tokenizerURL,
            expectedSHA256: original.tokenizerSHA256
        )
        let packageURL = modelDirectory.appending(
            path: "ClauseTagger.mlpackage",
            directoryHint: .isDirectory
        )
        let model = try ClauseTaggerModel(packageURL: packageURL)
        guard model.identity.modelID == original.modelID,
              model.identity.revision == original.modelRevision,
              model.identity.tokenizerSHA256 == original.tokenizerSHA256 else {
            throw FixtureError.invalid("The supplied Core ML identity differs from the original fixture identity.")
        }
        let tagger = try LocalClauseTagger(modelDirectory: modelDirectory)
        guard tagger.identity.modelID == original.modelID,
              tagger.identity.revision == original.modelRevision,
              tagger.identity.tokenizerSHA256 == original.tokenizerSHA256 else {
            throw FixtureError.invalid("LocalClauseTagger loaded an identity different from the original fixture.")
        }

        try printOriginalModelDifferences(original: original, tokenizer: tokenizer, model: model)
        let tokenizerDocument = try makeTokenizerDocument(
            original: original,
            tokenizer: tokenizer,
            tokenizerBytes: tokenizerBytes
        )
        let requestDocument = try await makeRequestDocument(
            original: original,
            tokenizer: tokenizer,
            model: model,
            tagger: tagger
        )

        // Build and validate both complete documents before either destination can change.
        let tokenizerData = try serializedJSON(tokenizerDocument)
        let requestData = try serializedJSON(requestDocument)
        if writeMode {
            let destinations = try outputURLs()
            try tokenizerData.write(to: destinations.tokenizer, options: .atomic)
            try requestData.write(to: destinations.request, options: .atomic)
            print("Wrote \(tokenizerFixtureName).json: \(tokenizerData.count) bytes")
            print("Wrote \(requestFixtureName).json: \(requestData.count) bytes")
        } else {
            let expectedTokenizer = try Data(contentsOf: ClauseTaggerFixtures.resourceURL(named: tokenizerFixtureName))
            let expectedRequest = try Data(contentsOf: ClauseTaggerFixtures.resourceURL(named: requestFixtureName))
            try compareJSON(
                expected: try jsonObject(expectedTokenizer, name: tokenizerFixtureName),
                actual: tokenizerDocument,
                path: "$"
            )
            let expectedRequestDocument = try jsonObject(expectedRequest, name: requestFixtureName)
            try compareJSON(
                expected: expectedRequestDocument,
                actual: requestDocument,
                path: "$"
            )
            let rawMaxima = try rawHeadMaxima(expected: expectedRequestDocument, actual: requestDocument)
            for head in ["boundary_probs", "span_probs", "priority_probs"] {
                guard let maximum = rawMaxima[head] else {
                    throw FixtureError.invalid("Missing raw-head maximum for \(head).")
                }
                print("ClauseTagger request \(head) max abs diff: \(maximum)")
            }
            print("Checked \(tokenizerFixtureName).json and \(requestFixtureName).json")
        }
    }

    static func compareJSON(expected: Any, actual: Any, path: String = "$") throws {
        try compare(expected: expected, actual: actual, path: path, probabilitySubtree: false)
    }

    static func rawHeadMaxima(expected: Any, actual: Any) throws -> [String: Double] {
        var maxima = ["boundary_probs": 0.0, "span_probs": 0.0, "priority_probs": 0.0]
        try collectRawHeadMaxima(expected: expected, actual: actual, path: "$", maxima: &maxima)
        return maxima
    }

    private static func collectRawHeadMaxima(
        expected: Any,
        actual: Any,
        path: String,
        maxima: inout [String: Double]
    ) throws {
        if let expectedDictionary = expected as? [String: Any],
           let actualDictionary = actual as? [String: Any] {
            let expectedKeys = Set(expectedDictionary.keys)
            let actualKeys = Set(actualDictionary.keys)
            guard expectedKeys == actualKeys else {
                throw FixtureError.mismatch("\(path): object keys differ while collecting raw-head differences.")
            }
            for key in expectedDictionary.keys.sorted() {
                let childPath = path == "$" ? "$.\(key)" : "\(path).\(key)"
                switch key {
                case "boundary_probs", "span_probs":
                    try collectRawHeadMatrix(
                        expected: expectedDictionary[key]!,
                        actual: actualDictionary[key]!,
                        head: key,
                        width: key == "boundary_probs" ? 2 : 4,
                        path: childPath,
                        maxima: &maxima
                    )
                case "priority_probs":
                    try collectRawHeadVector(
                        expected: expectedDictionary[key]!,
                        actual: actualDictionary[key]!,
                        head: key,
                        width: 2,
                        path: childPath,
                        maxima: &maxima
                    )
                default:
                    try collectRawHeadMaxima(
                        expected: expectedDictionary[key]!,
                        actual: actualDictionary[key]!,
                        path: childPath,
                        maxima: &maxima
                    )
                }
            }
            return
        }
        if let expectedArray = expected as? [Any], let actualArray = actual as? [Any] {
            guard expectedArray.count == actualArray.count else {
                throw FixtureError.mismatch("\(path): array counts differ while collecting raw-head differences.")
            }
            for index in expectedArray.indices {
                try collectRawHeadMaxima(
                    expected: expectedArray[index],
                    actual: actualArray[index],
                    path: "\(path)[\(index)]",
                    maxima: &maxima
                )
            }
            return
        }
        if expected is [String: Any] || actual is [String: Any] || expected is [Any] || actual is [Any] {
            throw FixtureError.mismatch("\(path): container types differ while collecting raw-head differences.")
        }
    }

    private static func collectRawHeadMatrix(
        expected: Any,
        actual: Any,
        head: String,
        width: Int,
        path: String,
        maxima: inout [String: Double]
    ) throws {
        guard let expectedRows = expected as? [Any], let actualRows = actual as? [Any] else {
            throw FixtureError.mismatch("\(path): raw head must be an array of rows.")
        }
        guard expectedRows.count == actualRows.count else {
            throw FixtureError.mismatch("\(path): raw-head row counts differ.")
        }
        for index in expectedRows.indices {
            try collectRawHeadVector(
                expected: expectedRows[index],
                actual: actualRows[index],
                head: head,
                width: width,
                path: "\(path)[\(index)]",
                maxima: &maxima
            )
        }
    }

    private static func collectRawHeadVector(
        expected: Any,
        actual: Any,
        head: String,
        width: Int,
        path: String,
        maxima: inout [String: Double]
    ) throws {
        let expectedValues = try rawHeadValues(expected, width: width, path: path)
        let actualValues = try rawHeadValues(actual, width: width, path: path)
        guard expectedValues.count == actualValues.count else {
            throw FixtureError.mismatch("\(path): raw-head widths differ.")
        }
        for index in expectedValues.indices {
            let difference = abs(expectedValues[index] - actualValues[index])
            guard difference.isFinite else {
                throw FixtureError.mismatch("\(path)[\(index)]: raw-head difference is not finite.")
            }
            guard let previousMaximum = maxima[head] else {
                throw FixtureError.invalid("Missing raw-head maximum accumulator for \(head).")
            }
            maxima[head] = max(previousMaximum, difference)
        }
    }

    private static func rawHeadValues(_ value: Any, width: Int, path: String) throws -> [Double] {
        guard let array = value as? [Any] else {
            throw FixtureError.mismatch("\(path): raw-head row must be an array.")
        }
        guard array.count == width else {
            throw FixtureError.mismatch("\(path): raw-head row width must be \(width), got \(array.count).")
        }
        return try array.enumerated().map { index, item in
            guard let number = item as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                throw FixtureError.mismatch("\(path)[\(index)]: raw-head value must be a finite number.")
            }
            return number.doubleValue
        }
    }

    private static func compare(
        expected: Any,
        actual: Any,
        path: String,
        probabilitySubtree inheritedProbabilitySubtree: Bool
    ) throws {
        if expected is NSNull || actual is NSNull {
            guard expected is NSNull, actual is NSNull else {
                throw FixtureError.mismatch("\(path): null/type differs.")
            }
            return
        }
        if let expectedDictionary = expected as? [String: Any],
           let actualDictionary = actual as? [String: Any] {
            let expectedKeys = Set(expectedDictionary.keys)
            let actualKeys = Set(actualDictionary.keys)
            guard expectedKeys == actualKeys else {
                let missing = expectedKeys.subtracting(actualKeys).sorted()
                let unexpected = actualKeys.subtracting(expectedKeys).sorted()
                throw FixtureError.mismatch("\(path): object keys differ (missing: \(missing), unexpected: \(unexpected)).")
            }
            for key in expectedDictionary.keys.sorted() {
                let childPath = path == "$" ? "$.\(key)" : "\(path).\(key)"
                try compare(
                    expected: expectedDictionary[key]!,
                    actual: actualDictionary[key]!,
                    path: childPath,
                    probabilitySubtree: inheritedProbabilitySubtree || tolerantFields.contains(key)
                )
            }
            return
        }
        if let expectedArray = expected as? [Any], let actualArray = actual as? [Any] {
            guard expectedArray.count == actualArray.count else {
                throw FixtureError.mismatch("\(path): array count differs (expected \(expectedArray.count), got \(actualArray.count)).")
            }
            for index in expectedArray.indices {
                try compare(
                    expected: expectedArray[index],
                    actual: actualArray[index],
                    path: "\(path)[\(index)]",
                    probabilitySubtree: inheritedProbabilitySubtree
                )
            }
            return
        }
        if let expectedString = expected as? String, let actualString = actual as? String {
            guard Data(expectedString.utf8) == Data(actualString.utf8) else {
                throw FixtureError.mismatch("\(path): UTF-8 string bytes differ.")
            }
            return
        }
        if let expectedNumber = expected as? NSNumber, let actualNumber = actual as? NSNumber {
            let expectedBoolean = CFGetTypeID(expectedNumber) == CFBooleanGetTypeID()
            let actualBoolean = CFGetTypeID(actualNumber) == CFBooleanGetTypeID()
            guard expectedBoolean == actualBoolean else {
                throw FixtureError.mismatch("\(path): boolean/number type differs.")
            }
            if expectedBoolean {
                guard expectedNumber.boolValue == actualNumber.boolValue else {
                    throw FixtureError.mismatch("\(path): boolean differs.")
                }
                return
            }
            let expectedValue = expectedNumber.doubleValue
            let actualValue = actualNumber.doubleValue
            guard expectedValue.isFinite, actualValue.isFinite else {
                throw FixtureError.mismatch("\(path): numeric values must be finite.")
            }
            if inheritedProbabilitySubtree {
                guard (0...1).contains(expectedValue), (0...1).contains(actualValue) else {
                    throw FixtureError.mismatch("\(path): probability-like numeric values must be in 0...1.")
                }
                guard abs(expectedValue - actualValue) <= comparisonTolerance else {
                    throw FixtureError.mismatch("\(path): probability differs by \(abs(expectedValue - actualValue)), above \(comparisonTolerance).")
                }
            } else {
                guard expectedNumber == actualNumber else {
                    throw FixtureError.mismatch("\(path): exact numeric value differs (\(expectedNumber) vs \(actualNumber)).")
                }
            }
            return
        }
        throw FixtureError.mismatch("\(path): JSON value types differ or are unsupported.")
    }

    static func requiredModelDirectory(environment: [String: String]) throws -> URL {
        guard let path = environment["CLAUSE_TAGGER_MODEL_DIRECTORY"], !path.isEmpty else {
            throw FixtureError.setup("CLAUSE_TAGGER_MODEL_DIRECTORY must be set to a nonempty absolute directory.")
        }
        guard path.hasPrefix("/") else {
            throw FixtureError.setup("CLAUSE_TAGGER_MODEL_DIRECTORY must be an absolute path.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FixtureError.setup("CLAUSE_TAGGER_MODEL_DIRECTORY must name an existing directory: \(path)")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw FixtureError.setup("CLAUSE_TAGGER_MODEL_DIRECTORY is not readable: \(path)")
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    private static func makeTokenizerDocument(
        original: ClauseTaggerFixtureDocument,
        tokenizer: ClauseTaggerTokenizer,
        tokenizerBytes: Data
    ) throws -> [String: Any] {
        let releaseJSON = try jsonObject(tokenizerBytes, name: "tokenizer.json")
        var cases: [[String: Any]] = []
        for (index, fixture) in original.fixtures.enumerated() {
            var recorded: [[String: Any]] = []
            _ = try ClauseTaggerEncoding.encode(text: fixture.text, next: fixture.next) { piece in
                let tokens = try tokenizer.encodePiece(piece)
                recorded.append(pieceRecord(text: piece, tokens: tokens))
                return tokens
            }
            cases.append([
                "name": String(format: "original-%02d", index + 1),
                "tokenizer": "release",
                "text": fixture.text,
                "next": fixture.next as Any? ?? NSNull(),
                "pieces": recorded
            ])
        }

        let directInputs: [(String, String)] = [
            ("direct-empty", ""),
            ("direct-bom", "\u{FEFF}今日は\u{FEFF}"),
            ("direct-composed", "é が カ"),
            ("direct-decomposed", "e\u{301} か\u{3099} カ\u{3099}"),
            ("direct-consecutive-oov", "\u{10FFFF}\u{10FFFE}"),
            ("direct-separated-oov", "\u{10FFFF}a\u{10FFFE} \u{10FFFF}"),
            ("direct-emoji-modifiers", "👍🏽👩🏽‍💻😀😀"),
            ("direct-whitespace", "  今日\tは\n晴れ\r\n　です  ")
        ]
        for (name, text) in directInputs {
            cases.append(try directCase(name: name, tokenizerName: "release", text: text, tokenizer: tokenizer))
        }

        let addedContents = try addedTokenContents(in: releaseJSON)
        for (index, content) in addedContents.enumerated() {
            let text = "前" + content + "後"
            cases.append(try directCase(
                name: String(format: "release-added-token-%03d", index + 1),
                tokenizerName: "release",
                text: text,
                tokenizer: tokenizer
            ))
        }

        let synthetic = try syntheticTokenizerDocuments(from: releaseJSON)
        var syntheticRecords: [[String: Any]] = []
        let tieTexts = ["ab", "aba", "abab", "baba"]
        for item in synthetic {
            let temporaryURL = try writeTemporaryTokenizer(item.bytes)
            do {
                let syntheticTokenizer = try ClauseTaggerTokenizer(
                    tokenizerURL: temporaryURL,
                    expectedSHA256: item.sha256
                )
                for text in tieTexts {
                    let tokens = try syntheticTokenizer.encodePiece(text)
                    if text == "ab" || text == "aba" {
                        guard tokens.count == 1, tokens[0].id == item.wholeTokenIDs[text] else {
                            throw FixtureError.invalid(
                                "Synthetic \(item.name) tie witness \(text) did not select its whole-token vocabulary entry."
                            )
                        }
                    }
                    cases.append([
                        "name": "\(item.name)-\(text)",
                        "tokenizer": item.name,
                        "text": text,
                        "next": NSNull(),
                        "pieces": [pieceRecord(text: text, tokens: tokens)]
                    ])
                }
            } catch {
                let captureError = error
                do {
                    try removeVerifiedTemporaryTokenizer(temporaryURL)
                } catch {
                    throw FixtureError.setup(
                        "Synthetic tokenizer capture failed (\(captureError.localizedDescription)); cleanup also failed (\(error.localizedDescription))."
                    )
                }
                throw captureError
            }
            try removeVerifiedTemporaryTokenizer(temporaryURL)
            syntheticRecords.append([
                "name": item.name,
                "sha256": item.sha256,
                "tokenizer_json": item.json
            ])
        }

        let names = cases.compactMap { $0["name"] as? String }
        guard names.count == cases.count, Set(names).count == names.count else {
            throw FixtureError.invalid("Tokenizer case identifiers must be present and unique.")
        }
        var pieceCount = 0
        for item in cases {
            guard let pieces = item["pieces"] as? [[String: Any]] else {
                throw FixtureError.invalid("Every tokenizer case must contain a pieces array.")
            }
            pieceCount += pieces.count
        }
        print("Tokenizer fixtures: \(cases.count) cases, \(pieceCount) pieces")
        return [
            "schema_version": 1,
            "tokenizer_sha256": original.tokenizerSHA256,
            "tokenizer_backend": "swift-transformers-1.3.4",
            "synthetic_tokenizers": syntheticRecords,
            "cases": cases
        ]
    }

    private static func makeRequestDocument(
        original: ClauseTaggerFixtureDocument,
        tokenizer: ClauseTaggerTokenizer,
        model: ClauseTaggerModel,
        tagger: LocalClauseTagger
    ) async throws -> [String: Any] {
        let longPiece = String(repeating: "今日は損失関数の話をします ", count: 12)
        let longText = longPiece + "、" + longPiece + "、" + longPiece + "。"
        let longPieceTokenCount = try tokenizer.encodePiece(longPiece).count
        guard longPieceTokenCount <= 189 else {
            throw FixtureError.invalid("The repeated longPiece must tokenize to at most 189 tokens; got \(longPieceTokenCount).")
        }
        var wholeTextPieces: [[ClauseTaggerToken]] = []
        _ = try ClauseTaggerEncoding.encode(text: longText) { piece in
            let tokens = try tokenizer.encodePiece(piece)
            wholeTextPieces.append(tokens)
            return tokens
        }
        let trimmedScalars = trimTrailingPunctuation(Array(longText.unicodeScalars))
        let punctuationCount = trimmedScalars.reduce(0) {
            $0 + (ClauseTaggerEncoding.punctuation.unicodeScalars.contains($1) ? 1 : 0)
        }
        let completeContentTokenCount = wholeTextPieces.reduce(0) { $0 + $1.count } + punctuationCount
        guard completeContentTokenCount > 190 else {
            throw FixtureError.invalid("The long request must exceed 190 complete content tokens; got \(completeContentTokenCount).")
        }

        let specifications: [(name: String, text: String, next: String?)] = [
            ("multi-window", longText, nil),
            ("continuation", "今日は天気がいいですけど、明日は雨が降るそうです", "続きです"),
            ("long-continuation", longText, "続きです"),
            ("terminal-no-candidates", "まあ。", nil),
            ("filler", "まあ、あの、今日は損失関数の話をします。", nil),
            ("backchannel", " えーと、 あのー、ビ、ビザの話なんですけど、はい！ ", nil)
        ]
        var boundaryCases: [[String: Any]] = []
        var boundaryCallCount = 0
        for specification in specifications {
            let request = try boundaryRequest(text: specification.text, next: specification.next)
            let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
                try tokenizer.encodePiece(piece)
            }
            if specification.name == "multi-window" {
                guard boundaryInputs.count > 1 else {
                    throw FixtureError.invalid("The long boundary request must require multiple model windows.")
                }
            }
            if specification.name == "terminal-no-candidates", !request.candidates.isEmpty {
                throw FixtureError.invalid("The terminal-no-candidates request unexpectedly has candidates.")
            }

            // Raw calls are a deterministic replay of the unchanged LocalClauseTagger encoding/model sequence;
            // the stored response below is taken from the actual actor API, not reconstructed from this trace.
            var calls: [CapturedCall] = []
            for input in boundaryInputs {
                calls.append(try captureCall(input, purpose: "boundary", model: model))
            }
            if request.next != nil {
                let continuationInput = try ClauseTaggerEncoding.continuationInput(request) { piece in
                    try tokenizer.encodePiece(piece)
                }
                calls.append(try captureCall(continuationInput, purpose: "continuation", model: model))
            }
            let response = try await tagger.assessBoundaries(request)
            let reconstructed = try validateBoundaryCapture(
                request: request,
                boundaryInputs: boundaryInputs,
                calls: calls,
                response: response
            )
            if specification.name == "backchannel" {
                var ownedSpanArgmaxes = Set<Int>()
                for call in calls where (call.document["purpose"] as? String) == "boundary" {
                    for tokenIndex in call.encoded.spanTokenIndices {
                        let probabilities = call.prediction.spanProbabilities[tokenIndex]
                        var label = 0
                        for classIndex in 1..<probabilities.count where probabilities[classIndex] > probabilities[label] {
                            label = classIndex
                        }
                        ownedSpanArgmaxes.insert(label)
                    }
                }
                guard ownedSpanArgmaxes.contains(3), ownedSpanArgmaxes.contains(1),
                      !response.fillerRanges.isEmpty else {
                    throw FixtureError.invalid(
                        "The backchannel fixture must capture owned B and F span argmaxes and a nonempty filler removal."
                    )
                }
            }
            let projected = try TranscriptTextProjector().project(
                sourceText: request.text,
                fillerRanges: response.fillerRanges
            ).text
            if specification.name == "filler" {
                guard projected == "今日は損失関数の話をします。", !response.fillerRanges.isEmpty else {
                    throw FixtureError.invalid("The required filler projection/removal witness changed.")
                }
            }
            if specification.name == "terminal-no-candidates" {
                guard calls.count > 0, response.inputTokens > 0 else {
                    throw FixtureError.invalid("The empty-candidate terminal request must still invoke the model.")
                }
            }
            guard reconstructed.probabilities.count == request.candidates.count,
                  reconstructed.inputTokens == response.inputTokens,
                  reconstructed.fillerRanges == response.fillerRanges,
                  optionalNear(reconstructed.continuationProbability, response.continuationProbability) else {
                throw FixtureError.invalid("Captured raw boundary calls do not reconstruct LocalClauseTagger response for \(specification.name).")
            }
            boundaryCallCount += calls.count
            boundaryCases.append([
                "name": specification.name,
                "request": try requestRecord(request),
                "calls": calls.map(\.document),
                "response": [
                    "probabilities": response.probabilities,
                    "continuation_probability": response.continuationProbability as Any? ?? NSNull(),
                    "filler_ranges": response.fillerRanges.map(rangeRecord),
                    "input_tokens": response.inputTokens
                ],
                "projected_text": projected
            ])
        }

        let priorityTargets = [
            PriorityTextTarget(key: "u0001", text: "まあ、あの、今日は損失関数の話をします。"),
            PriorityTextTarget(key: "u0002", text: String(repeating: longText, count: 3)),
            PriorityTextTarget(key: "u0003", text: "？！")
        ]
        guard priorityTargets.map(\.key) == ["u0001", "u0002", "u0003"] else {
            throw FixtureError.invalid("Priority batch target order or identifiers changed.")
        }
        var priorityInputs: [ClauseTaggerEncodedInput] = []
        for target in priorityTargets {
            priorityInputs.append(try ClauseTaggerEncoding.encode(text: target.text) { piece in
                try tokenizer.encodePiece(piece)
            })
        }
        guard priorityInputs.count == priorityTargets.count else {
            throw FixtureError.invalid("Each priority target must produce exactly one encoded input.")
        }
        var priorityCalls: [CapturedCall] = []
        for index in priorityTargets.indices {
            priorityCalls.append(try captureCall(
                priorityInputs[index],
                purpose: "priority",
                targetKey: priorityTargets[index].key,
                model: model
            ))
        }
        guard priorityInputs[1].inputIDs.count == ClauseTaggerEncoding.maximumTokens else {
            throw FixtureError.invalid("Priority target u0002 must exercise a 192-token truncated input.")
        }
        let priorityResponse = try await tagger.classifyPriorities(priorityTargets)
        let priorityDocument = try validatePriorityCapture(
            targets: priorityTargets,
            inputs: priorityInputs,
            calls: priorityCalls,
            response: priorityResponse
        )
        print("Boundary fixtures: \(boundaryCases.count) cases, \(boundaryCallCount) raw calls")
        print("Priority fixtures: 1 batch, \(priorityCalls.count) raw calls")

        return [
            "schema_version": 1,
            "model_id": original.modelID,
            "model_revision": original.modelRevision,
            "tokenizer_sha256": original.tokenizerSHA256,
            "backend": "coreml",
            "compute_units": "cpuOnly",
            "compute_precision": "float32",
            "encoding_revision": original.encodingRevision,
            "boundary_cases": boundaryCases,
            "priority_batches": [priorityDocument]
        ]
    }

    private static func validateBoundaryCapture(
        request: ClauseBoundaryRequest,
        boundaryInputs: [ClauseTaggerEncodedInput],
        calls: [CapturedCall],
        response: ClauseBoundaryResponse
    ) throws -> (probabilities: [String: Double], continuationProbability: Double?, fillerRanges: [TextUTF16Range], inputTokens: Int) {
        let boundaryCalls = calls.filter { ($0.document["purpose"] as? String) == "boundary" }
        let continuationCalls = calls.filter { ($0.document["purpose"] as? String) == "continuation" }
        guard boundaryCalls.count == boundaryInputs.count,
              continuationCalls.count == (request.next == nil ? 0 : 1),
              calls.count == boundaryCalls.count + continuationCalls.count else {
            throw FixtureError.invalid("Boundary call purposes/counts do not match the encoding sequence.")
        }
        var expectedSourceOrdinals = Set<Int>()
        for input in boundaryInputs {
            try validateInput(input)
            guard input.sourceTokenRanges.count == input.inputIDs.count else {
                throw FixtureError.invalid("Boundary source_token_ranges do not align with input_ids.")
            }
            for index in input.sourceTokenRanges.indices where input.sourceTokenRanges[index] != nil {
                guard index > 0, index < input.inputIDs.count - 1 else {
                    throw FixtureError.invalid("A boundary source range is attached to a special token.")
                }
                let ordinal = input.contentStartTokenIndex + index - 1
                expectedSourceOrdinals.insert(ordinal)
            }
        }
        guard expectedSourceOrdinals.sorted() == Array(0..<expectedSourceOrdinals.count) else {
            throw FixtureError.invalid("Boundary source token ordinals are not a complete contiguous sequence.")
        }

        var actualCandidateOffsets: [Int] = []
        var candidateProbabilities: [String: Double] = [:]
        var spanRows: [(ordinal: Int, range: TextUTF16Range, probabilities: [Double])] = []
        var inputTokenSum = 0
        for call in boundaryCalls {
            let input = call.encoded
            let prediction = call.prediction
            inputTokenSum += input.inputIDs.count
            for (offset, tokenIndex) in input.candidateTokenIndices {
                guard input.inputIDs.indices.contains(tokenIndex),
                      prediction.boundaryProbabilities.indices.contains(tokenIndex),
                      let candidate = request.candidates.first(where: { $0.offsetUTF16 == offset }),
                      candidateProbabilities[candidate.id] == nil else {
                    throw FixtureError.invalid("A captured boundary candidate is missing, duplicated, or out of range.")
                }
                candidateProbabilities[candidate.id] = prediction.boundaryProbabilities[tokenIndex][1]
                actualCandidateOffsets.append(offset)
            }
            guard input.sourceTokenRanges.count == input.inputIDs.count else {
                throw FixtureError.invalid("Captured boundary source ranges have the wrong count.")
            }
            for tokenIndex in input.spanTokenIndices {
                guard tokenIndex > 0,
                      tokenIndex < input.inputIDs.count - 1,
                      input.sourceTokenRanges.indices.contains(tokenIndex),
                      let range = input.sourceTokenRanges[tokenIndex],
                      prediction.spanProbabilities.indices.contains(tokenIndex) else {
                    throw FixtureError.invalid("A captured span token has no aligned source range/probability row.")
                }
                let ordinal = input.contentStartTokenIndex + tokenIndex - 1
                guard !spanRows.contains(where: { $0.ordinal == ordinal }) else {
                    throw FixtureError.invalid("A source ordinal is span-owned more than once.")
                }
                spanRows.append((ordinal, range, prediction.spanProbabilities[tokenIndex]))
            }
        }
        let expectedOffsets = request.candidates.map(\.offsetUTF16).sorted()
        guard actualCandidateOffsets.sorted() == expectedOffsets,
              Set(actualCandidateOffsets).count == actualCandidateOffsets.count,
              Set(candidateProbabilities.keys) == Set(request.candidates.map(\.id)) else {
            throw FixtureError.invalid("Captured candidate offsets or IDs do not match the request exactly.")
        }
        guard spanRows.map(\.ordinal).sorted() == expectedSourceOrdinals.sorted() else {
            throw FixtureError.invalid("Each source ordinal must be span-owned exactly once.")
        }
        spanRows.sort { $0.ordinal < $1.ordinal }
        let fillerRanges = try ClauseTaggerSpanProjection.removalRanges(
            sourceText: request.text,
            tokenRanges: spanRows.map(\.range),
            spanProbabilities: spanRows.map(\.probabilities)
        )

        var continuationProbability: Double?
        if let continuationCall = continuationCalls.first {
            let input = continuationCall.encoded
            guard let junctionIndex = input.junctionIndex,
                  input.inputIDs.indices.contains(junctionIndex),
                  continuationCall.prediction.boundaryProbabilities.indices.contains(junctionIndex) else {
                throw FixtureError.invalid("Continuation raw call has no valid junction row.")
            }
            continuationProbability = 1 - continuationCall.prediction.boundaryProbabilities[junctionIndex][1]
            inputTokenSum += input.inputIDs.count
        }
        guard inputTokenSum == response.inputTokens else {
            throw FixtureError.invalid("Captured raw boundary calls sum to \(inputTokenSum) input tokens; LocalClauseTagger reports \(response.inputTokens).")
        }
        for (key, value) in candidateProbabilities {
            guard let actual = response.probabilities[key], abs(value - actual) <= comparisonTolerance else {
                throw FixtureError.invalid("Raw candidate probability for \(key) differs from LocalClauseTagger.")
            }
        }
        guard Set(response.probabilities.keys) == Set(candidateProbabilities.keys) else {
            throw FixtureError.invalid("LocalClauseTagger candidate response keys differ from the captured calls.")
        }
        return (candidateProbabilities, continuationProbability, fillerRanges, inputTokenSum)
    }

    private static func validatePriorityCapture(
        targets: [PriorityTextTarget],
        inputs: [ClauseTaggerEncodedInput],
        calls: [CapturedCall],
        response: PriorityBatchResponse
    ) throws -> [String: Any] {
        guard targets.count == 3, inputs.count == targets.count, calls.count == targets.count,
              response.decisions.count == targets.count,
              Set(response.decisions.keys) == Set(targets.map(\.key)) else {
            throw FixtureError.invalid("Priority batch must contain exactly three target decisions and calls.")
        }
        var inputTokenSum = 0
        var decisions: [String: Any] = [:]
        for index in targets.indices {
            let target = targets[index]
            let input = inputs[index]
            let call = calls[index]
            try validateInput(input)
            guard call.encoded.inputIDs == input.inputIDs,
                  call.document["target_key"] as? String == target.key,
                  let decision = response.decisions[target.key] else {
                throw FixtureError.invalid("Priority call/target/decision ownership differs at \(target.key).")
            }
            inputTokenSum += input.inputIDs.count
            let probabilities = call.prediction.priorityProbabilities
            guard probabilities.count == 2,
                  let rawPrimary = decision.probabilities["PRIMARY"],
                  let rawLow = decision.probabilities["LOW_PRIORITY"],
                  abs(rawPrimary - probabilities[0]) <= comparisonTolerance,
                  abs(rawLow - probabilities[1]) <= comparisonTolerance else {
                throw FixtureError.invalid("Priority raw probabilities differ from the public response for \(target.key).")
            }
            let maximum = max(probabilities[0], probabilities[1])
            let expectedPriority = probabilities[0] >= probabilities[1] ? ContentPriority.primary : ContentPriority.lowPriority
            guard decision.priority == expectedPriority,
                  abs(decision.confidence - (2 * maximum - 1)) <= comparisonTolerance else {
                throw FixtureError.invalid("Priority label/confidence reconstruction differs for \(target.key).")
            }
            decisions[target.key] = [
                "priority": decision.priority.rawValue,
                "confidence": decision.confidence,
                "probabilities": decision.probabilities
            ]
        }
        guard inputTokenSum == response.inputTokens else {
            throw FixtureError.invalid("Priority raw calls sum to \(inputTokenSum) tokens; response reports \(response.inputTokens).")
        }
        return [
            "name": "truncation-batch",
            "targets": targets.map { ["key": $0.key, "text": $0.text] },
            "calls": calls.map(\.document),
            "response": ["decisions": decisions, "input_tokens": response.inputTokens]
        ]
    }

    private static func captureCall(
        _ input: ClauseTaggerEncodedInput,
        purpose: String,
        targetKey: String? = nil,
        model: ClauseTaggerModel
    ) throws -> CapturedCall {
        try validateInput(input)
        let prediction = try model.predict(inputIDs: input.inputIDs)
        try validatePrediction(prediction, inputLength: input.inputIDs.count)
        let sourceRanges: [Any]
        if input.sourceTokenRanges.isEmpty {
            sourceRanges = []
        } else {
            guard input.sourceTokenRanges.count == input.inputIDs.count else {
                throw FixtureError.invalid("Raw source_token_ranges length differs from input_ids.")
            }
            sourceRanges = input.sourceTokenRanges.map { range in
                guard let range else { return NSNull() }
                return rangeRecord(range)
            }
        }
        var document: [String: Any] = [
            "purpose": purpose,
            "input_ids": input.inputIDs,
            "content_start_token_index": input.contentStartTokenIndex,
            "source_token_ranges": sourceRanges,
            "candidate_token_indices": Dictionary(uniqueKeysWithValues: input.candidateTokenIndices.map {
                (String($0.key), $0.value)
            }),
            "junction_index": input.junctionIndex as Any? ?? NSNull(),
            "span_token_indices": input.spanTokenIndices,
            "boundary_probs": prediction.boundaryProbabilities,
            "span_probs": prediction.spanProbabilities,
            "priority_probs": prediction.priorityProbabilities
        ]
        if let targetKey { document["target_key"] = targetKey }
        return CapturedCall(document: document, encoded: input, prediction: prediction)
    }

    private static func validateInput(_ input: ClauseTaggerEncodedInput) throws {
        guard (2...ClauseTaggerEncoding.maximumTokens).contains(input.inputIDs.count),
              input.inputIDs.first == ClauseTaggerEncoding.clsTokenID,
              input.inputIDs.last == ClauseTaggerEncoding.sepTokenID else {
            throw FixtureError.invalid("Model call input length must be 2...192 with CLS/SEP endpoints.")
        }
        if !input.sourceTokenRanges.isEmpty && input.sourceTokenRanges.count != input.inputIDs.count {
            throw FixtureError.invalid("source_token_ranges must be empty or aligned with input_ids.")
        }
        for (offset, tokenIndex) in input.candidateTokenIndices {
            guard offset > 0, input.inputIDs.indices.contains(tokenIndex),
                  input.inputIDs[tokenIndex] == ClauseTaggerEncoding.commaTokenID else {
                throw FixtureError.invalid("Candidate token index \(tokenIndex) at offset \(offset) is invalid.")
            }
        }
        if let junction = input.junctionIndex {
            guard input.inputIDs.indices.contains(junction), input.inputIDs[junction] == ClauseTaggerEncoding.commaTokenID else {
                throw FixtureError.invalid("Junction index does not identify the comma token.")
            }
        }
        for index in input.spanTokenIndices {
            guard index > 0, index < input.inputIDs.count - 1 else {
                throw FixtureError.invalid("Span token index \(index) is outside content positions.")
            }
        }
    }

    private static func validatePrediction(_ prediction: ClauseTaggerPrediction, inputLength: Int) throws {
        guard prediction.boundaryProbabilities.count == inputLength,
              prediction.spanProbabilities.count == inputLength,
              prediction.priorityProbabilities.count == 2 else {
            throw FixtureError.invalid("A raw model output head has a shape inconsistent with its input.")
        }
        try validateRows(prediction.boundaryProbabilities, width: 2, label: "boundary_probs")
        try validateRows(prediction.spanProbabilities, width: 4, label: "span_probs")
        try validateVector(prediction.priorityProbabilities, label: "priority_probs")
    }

    private static func validateRows(_ rows: [[Double]], width: Int, label: String) throws {
        for (index, row) in rows.enumerated() {
            guard row.count == width else {
                throw FixtureError.invalid("\(label)[\(index)] must have width \(width).")
            }
            try validateVector(row, label: "\(label)[\(index)]")
        }
    }

    private static func validateVector(_ values: [Double], label: String) throws {
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(values.reduce(0, +) - 1) <= probabilitySumTolerance else {
            throw FixtureError.invalid("\(label) must contain finite probabilities in 0...1 summing to 1 within \(probabilitySumTolerance).")
        }
    }

    private static func printOriginalModelDifferences(
        original: ClauseTaggerFixtureDocument,
        tokenizer: ClauseTaggerTokenizer,
        model: ClauseTaggerModel
    ) throws {
        var maxBoundary = 0.0
        var maxSpan = 0.0
        var maxPriority = 0.0
        for (index, fixture) in original.fixtures.enumerated() {
            let encoded = try ClauseTaggerEncoding.encode(text: fixture.text, next: fixture.next) { piece in
                try tokenizer.encodePiece(piece)
            }
            guard fixture.inputIDs.count >= 2,
                  encoded.inputIDs.count >= fixture.inputIDs.count,
                  Array(encoded.inputIDs.prefix(fixture.inputIDs.count - 1)) + [ClauseTaggerEncoding.sepTokenID] == fixture.inputIDs else {
                throw FixtureError.invalid("Original fixture \(index + 1) input IDs differ from the shipped tokenizer encoding.")
            }
            let retainedCandidates = encoded.candidateTokenIndices.reduce(into: [Int: Int]()) { result, entry in
                if entry.value < fixture.inputIDs.count - 1 {
                    result[entry.key] = entry.value
                }
            }
            var expectedCandidates: [Int: Int] = [:]
            for (offsetText, tokenIndex) in fixture.candidateTokenIndices {
                guard let offset = Int(offsetText), expectedCandidates[offset] == nil else {
                    throw FixtureError.invalid("Original fixture \(index + 1) contains an invalid or duplicate candidate offset \(offsetText).")
                }
                expectedCandidates[offset] = tokenIndex
            }
            guard retainedCandidates == expectedCandidates else {
                throw FixtureError.invalid("Original fixture \(index + 1) retained candidate map differs from the shipped encoding.")
            }
            let retainedJunctionIndex = encoded.junctionIndex.flatMap {
                $0 < fixture.inputIDs.count - 1 ? $0 : nil
            }
            guard retainedJunctionIndex == fixture.junctionIndex else {
                throw FixtureError.invalid("Original fixture \(index + 1) retained junction index differs from the shipped encoding.")
            }
            guard fixture.boundaryProbabilities.count == fixture.inputIDs.count,
                  fixture.spanProbabilities.count == fixture.inputIDs.count,
                  fixture.priorityProbabilities.count == 2 else {
                throw FixtureError.invalid("Original fixture \(index + 1) reference probability head shapes do not match its input.")
            }
            try validateRows(fixture.boundaryProbabilities, width: 2, label: "original boundary_probs")
            try validateRows(fixture.spanProbabilities, width: 4, label: "original span_probs")
            try validateVector(fixture.priorityProbabilities, label: "original priority_probs")

            let prediction = try model.predict(inputIDs: fixture.inputIDs)
            try validatePrediction(prediction, inputLength: fixture.inputIDs.count)
            maxBoundary = max(maxBoundary, try maximumDifference(prediction.boundaryProbabilities, fixture.boundaryProbabilities, head: "boundary_probs"))
            maxSpan = max(maxSpan, try maximumDifference(prediction.spanProbabilities, fixture.spanProbabilities, head: "span_probs"))
            maxPriority = max(maxPriority, try maximumDifference(prediction.priorityProbabilities, fixture.priorityProbabilities, head: "priority_probs"))
        }
        print("ClauseTagger boundary_probs max abs diff: \(maxBoundary)")
        print("ClauseTagger span_probs max abs diff: \(maxSpan)")
        print("ClauseTagger priority_probs max abs diff: \(maxPriority)")
        guard maxBoundary.isFinite, maxSpan.isFinite, maxPriority.isFinite,
              maxBoundary <= comparisonTolerance,
              maxSpan <= comparisonTolerance,
              maxPriority <= comparisonTolerance else {
            throw FixtureError.invalid(
                "Original model probability differences exceed \(comparisonTolerance): boundary_probs=\(maxBoundary), span_probs=\(maxSpan), priority_probs=\(maxPriority)."
            )
        }
    }

    private static func maximumDifference(_ lhs: [[Double]], _ rhs: [[Double]], head: String) throws -> Double {
        guard lhs.count == rhs.count else { throw FixtureError.invalid("\(head) row counts differ.") }
        var maximum = 0.0
        for row in lhs.indices {
            maximum = max(maximum, try maximumDifference(lhs[row], rhs[row], head: "\(head)[\(row)]"))
        }
        return maximum
    }

    private static func maximumDifference(_ lhs: [Double], _ rhs: [Double], head: String) throws -> Double {
        guard lhs.count == rhs.count else { throw FixtureError.invalid("\(head) widths differ.") }
        var maximum = 0.0
        for index in lhs.indices { maximum = max(maximum, abs(lhs[index] - rhs[index])) }
        return maximum
    }

    private struct SyntheticTokenizer {
        let name: String
        let json: [String: Any]
        let bytes: Data
        let sha256: String
        let wholeTokenIDs: [String: Int]
    }

    private static func syntheticTokenizerDocuments(from releaseJSON: [String: Any]) throws -> [SyntheticTokenizer] {
        var root = releaseJSON
        guard var model = root["model"] as? [String: Any],
              let originalVocabulary = model["vocab"] as? [Any],
              originalVocabulary.count >= 276 else {
            throw FixtureError.invalid("Released tokenizer JSON has no Unigram vocabulary with at least 276 entries.")
        }
        guard let added = root["added_tokens"] as? [[String: Any]] else {
            throw FixtureError.invalid("Released tokenizer JSON added_tokens must be an array.")
        }
        let retainedAddedTokens = try added.filter { entry in
            guard let id = entry["id"] as? NSNumber else {
                throw FixtureError.invalid("Every added_tokens entry must have an integer id.")
            }
            return id.intValue < 276
        }
        var prefix = Array(originalVocabulary.prefix(276))
        guard prefix.count == 276 else {
            throw FixtureError.invalid("The synthetic tokenizer prefix must retain exactly 276 entries.")
        }
        for token in ["a", "b", "ab", "ba", "aba"] {
            if prefix.contains(where: { entry in
                guard let pair = entry as? [Any], let spelling = pair.first as? String else { return false }
                return spelling == token
            }) {
                throw FixtureError.invalid("Unexpected existing vocabulary token \(token) in the first 276 entries.")
            }
        }
        let forwardEntries: [(String, Double)] = [("a", -1), ("b", -1), ("ab", -2), ("ba", -2), ("aba", -3)]
        let reverseEntries = Array(forwardEntries.reversed())
        var results: [SyntheticTokenizer] = []
        for (name, appended) in [("ties-forward", forwardEntries), ("ties-reversed", reverseEntries)] {
            let startID = prefix.count
            let entries = prefix + appended.map { [$0.0, $0.1] as [Any] }
            model["vocab"] = entries
            root["model"] = model
            root["added_tokens"] = retainedAddedTokens
            let bytes = try serializedJSON(root)
            let json = try jsonObject(bytes, name: "synthetic \(name)")
            var ids: [String: Int] = [:]
            for (offset, entry) in appended.enumerated() { ids[entry.0] = startID + offset }
            guard let abID = ids["ab"], let abaID = ids["aba"] else {
                throw FixtureError.invalid("Synthetic tie vocabulary does not contain both whole-token witnesses.")
            }
            results.append(SyntheticTokenizer(
                name: name,
                json: json,
                bytes: bytes,
                sha256: sha256(bytes),
                wholeTokenIDs: ["ab": abID, "aba": abaID]
            ))
            // Restore the immutable release prefix before building the reversed sibling.
            prefix = Array(originalVocabulary.prefix(276))
            model["vocab"] = prefix
        }
        return results
    }

    private static func addedTokenContents(in document: [String: Any]) throws -> [String] {
        guard let entries = document["added_tokens"] as? [[String: Any]] else {
            throw FixtureError.invalid("Released tokenizer JSON added_tokens must be an array.")
        }
        return try entries.map { entry in
            guard let content = entry["content"] as? String else {
                throw FixtureError.invalid("Every release added_tokens entry must have string content.")
            }
            return content
        }
    }

    private static func directCase(
        name: String,
        tokenizerName: String,
        text: String,
        tokenizer: ClauseTaggerTokenizer
    ) throws -> [String: Any] {
        [
            "name": name,
            "tokenizer": tokenizerName,
            "text": text,
            "next": NSNull(),
            "pieces": [pieceRecord(text: text, tokens: try tokenizer.encodePiece(text))]
        ]
    }

    private static func pieceRecord(text: String, tokens: [ClauseTaggerToken]) -> [String: Any] {
        [
            "text": text,
            "token_ids": tokens.map(\.id),
            "ranges": tokens.map { rangeRecord($0.range) }
        ]
    }

    private static func boundaryRequest(text: String, next: String?) throws -> ClauseBoundaryRequest {
        let source = try SegmentTextReference(
            segmentationRunID: "clause-tagger-fixture-run",
            segmentID: "fixture-segment-1",
            asrRunID: "clause-tagger-fixture-asr",
            asrEventSeq: 1
        )
        let nextHead: NextSegmentHead?
        if let next {
            let nextSource = try SegmentTextReference(
                segmentationRunID: "clause-tagger-fixture-run",
                segmentID: "fixture-segment-2",
                asrRunID: "clause-tagger-fixture-asr",
                asrEventSeq: 2
            )
            nextHead = try NextSegmentHead(source: nextSource, text: next)
        } else {
            nextHead = nil
        }
        return try ClauseBoundaryRequest(source: source, text: text, next: nextHead)
    }

    private static func requestRecord(_ request: ClauseBoundaryRequest) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let sourceData = try encoder.encode(request.source)
        let candidateData = try encoder.encode(request.candidates)
        let source = try jsonObject(sourceData, name: "request source")
        let candidateObject: Any
        do {
            candidateObject = try JSONSerialization.jsonObject(with: candidateData, options: [])
        } catch {
            throw FixtureError.invalid("Cannot parse request candidates JSON: \(error.localizedDescription)")
        }
        guard let candidates = candidateObject as? [[String: Any]] else {
            throw FixtureError.invalid("request candidates JSON root must be an array of objects.")
        }
        let next: Any
        if let value = request.next {
            next = try jsonObject(encoder.encode(value), name: "request next")
        } else {
            next = NSNull()
        }
        return ["source": source, "text": request.text, "candidates": candidates, "next": next]
    }

    private static func rangeRecord(_ range: TextUTF16Range) -> [String: Int] {
        ["start": range.start, "end": range.end]
    }

    private static func trimTrailingPunctuation(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var result = scalars
        while let last = result.last, ClauseTaggerEncoding.punctuation.unicodeScalars.contains(last) {
            result.removeLast()
        }
        return result
    }

    private static func optionalNear(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): abs(left - right) <= comparisonTolerance
        default: false
        }
    }

    private static func serializedJSON(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw FixtureError.invalid("A generated fixture object is not valid JSON.")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    // JSONSerialization's NSString bridge strips a leading U+FEFF from string values.
    // JSONDecoder preserves the raw scalars, which are part of this migration oracle.
    private enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case boolean(Bool)
        case integer(Int)
        case number(Double)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        var foundationValue: Any {
            switch self {
            case .object(let value): value.mapValues(\.foundationValue)
            case .array(let value): value.map(\.foundationValue)
            case .string(let value): value
            case .boolean(let value): NSNumber(value: value)
            case .integer(let value): NSNumber(value: value)
            case .number(let value): NSNumber(value: value)
            case .null: NSNull()
            }
        }
    }

    static func jsonObject(_ data: Data, name: String) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONDecoder().decode(JSONValue.self, from: data).foundationValue
        } catch {
            throw FixtureError.invalid("Cannot parse \(name) JSON: \(error.localizedDescription)")
        }
        guard let dictionary = object as? [String: Any] else {
            throw FixtureError.invalid("\(name) JSON root must be an object.")
        }
        return dictionary
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeTemporaryTokenizer(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let filename = "clause-tagger-parity-\(UUID().uuidString).json"
        let destination = directory.appending(path: filename)
        guard destination.deletingLastPathComponent().standardizedFileURL == directory,
              filename.hasPrefix("clause-tagger-parity-"), filename.hasSuffix(".json") else {
            throw FixtureError.setup("Refusing an unverified temporary tokenizer path.")
        }
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func removeVerifiedTemporaryTokenizer(_ url: URL) throws {
        let expectedDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let name = url.lastPathComponent
        guard resolved.deletingLastPathComponent() == expectedDirectory,
              name.hasPrefix("clause-tagger-parity-"), name.hasSuffix(".json"),
              UUID(uuidString: String(name.dropFirst("clause-tagger-parity-".count).dropLast(".json".count))) != nil else {
            throw FixtureError.setup("Refusing to remove an unverified temporary tokenizer path: \(url.path)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func outputURLs() throws -> (tokenizer: URL, request: URL) {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fixtureDirectory = testsDirectory
            .deletingLastPathComponent()
            .appending(path: "MacAmbientJevClauseTaggerFixtures", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .standardizedFileURL
        let resolvedFixtureDirectory = fixtureDirectory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard resolvedFixtureDirectory == fixtureDirectory,
              resolvedFixtureDirectory.lastPathComponent == "Resources",
              resolvedFixtureDirectory.deletingLastPathComponent().lastPathComponent == "MacAmbientJevClauseTaggerFixtures",
              FileManager.default.fileExists(atPath: resolvedFixtureDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: resolvedFixtureDirectory.path) else {
            throw FixtureError.setup("Resolved fixture output directory is not the writable sibling shared resource directory.")
        }
        let tokenizer = resolvedFixtureDirectory.appending(path: "\(tokenizerFixtureName).json")
        let request = resolvedFixtureDirectory.appending(path: "\(requestFixtureName).json")
        guard tokenizer.deletingLastPathComponent() == resolvedFixtureDirectory,
              request.deletingLastPathComponent() == resolvedFixtureDirectory,
              tokenizer.lastPathComponent == "\(tokenizerFixtureName).json",
              request.lastPathComponent == "\(requestFixtureName).json" else {
            throw FixtureError.setup("Resolved output filenames are not the two fixed parity resource names.")
        }
        return (tokenizer, request)
    }
}
