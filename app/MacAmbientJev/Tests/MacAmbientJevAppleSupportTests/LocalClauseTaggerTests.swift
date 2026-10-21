import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevAppleSupport
import MacAmbientJevClauseTaggerFixtures

private enum LocalClauseTaggerTestSetupError: LocalizedError {
    case missingModelDirectoryEnvironment
    case modelDirectoryMustBeAbsolute
    case modelDirectoryMustExistAsDirectory(String)

    var errorDescription: String? {
        switch self {
        case .missingModelDirectoryEnvironment:
            "RUN_CLAUSE_TAGGER_TESTS=1 requires CLAUSE_TAGGER_MODEL_DIRECTORY to be set explicitly."
        case .modelDirectoryMustBeAbsolute:
            "CLAUSE_TAGGER_MODEL_DIRECTORY must be an absolute path."
        case .modelDirectoryMustExistAsDirectory(let path):
            "CLAUSE_TAGGER_MODEL_DIRECTORY must name an existing directory: \(path)"
        }
    }
}

@Suite
struct LocalClauseTaggerTests {
    @Test
    func fixtureIsTrainedAndHasConsistentProbabilityShapes() throws {
        let document = try Self.loadFixture()

        #expect(document.modelID == "sbintuitions/modernbert-ja-30m-multitagger")
        #expect(document.modelRevision == "90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9")
        #expect(document.trainingStatus == "trained")
        #expect(Self.isLowercaseSHA256(document.tokenizerSHA256))
        #expect(document.unitPolicy == "btsj-utterance-sentence")
        #expect(document.encodingRevision == "1")
        #expect(document.clsTokenID == ClauseTaggerEncoding.clsTokenID)
        #expect(document.sepTokenID == ClauseTaggerEncoding.sepTokenID)
        #expect(document.commaTokenID == ClauseTaggerEncoding.commaTokenID)
        #expect(document.fixtures.count == 13)

        for fixture in document.fixtures {
            let length = fixture.inputIDs.count
            #expect((2...ClauseTaggerEncoding.maximumTokens).contains(length))
            #expect(fixture.inputIDs.first == document.clsTokenID)
            #expect(fixture.inputIDs.last == document.sepTokenID)
            #expect(fixture.boundaryProbabilities.count == length)
            #expect(fixture.spanProbabilities.count == length)
            #expect(fixture.priorityProbabilities.count == 2)
            #expect(fixture.boundaryProbabilities.allSatisfy { $0.count == 2 })
            #expect(fixture.spanProbabilities.allSatisfy { $0.count == 4 })
            #expect(fixture.boundaryProbabilities.allSatisfy(Self.isProbabilityDistribution))
            #expect(fixture.spanProbabilities.allSatisfy(Self.isProbabilityDistribution))
            #expect(Self.isProbabilityDistribution(fixture.priorityProbabilities))
            #expect(fixture.coreMLMaxAbsDiff.isFinite && fixture.coreMLMaxAbsDiff >= 0)
            #expect((fixture.next != nil) == (fixture.junctionIndex != nil))

            let candidateOffsetUpperBound = Self.candidateOffsetUpperBound(for: fixture)
            for (offsetText, tokenIndex) in fixture.candidateTokenIndices {
                let offset = try #require(Int(offsetText))
                #expect(offset > 0 && offset <= candidateOffsetUpperBound)
                #expect(fixture.inputIDs.indices.contains(tokenIndex))
                #expect(fixture.inputIDs[tokenIndex] == document.commaTokenID)
            }
            if let junctionIndex = fixture.junctionIndex {
                #expect(fixture.inputIDs.indices.contains(junctionIndex))
                #expect(fixture.inputIDs[junctionIndex] == document.commaTokenID)
            }
        }
    }

    @Test
    func missingTokenizerWithAllZeroExpectedHashReportsItsLocalFileError() throws {
        let directory = Self.temporaryDirectoryURL()
        let tokenizerURL = directory.appending(path: "tokenizer.json")

        do {
            _ = try ClauseTaggerTokenizer(
                tokenizerURL: tokenizerURL,
                expectedSHA256: String(repeating: "0", count: 64)
            )
            Issue.record("A missing tokenizer.json unexpectedly loaded.")
        } catch let error as ClauseTaggerTokenizerError {
            guard case .invalidConfiguration(let detail) = error else {
                Issue.record("Unexpected tokenizer error: \(error.localizedDescription)")
                return
            }
            #expect(detail.contains("tokenizer.json を読み込めません"))
        } catch {
            Issue.record("Unexpected error for a missing tokenizer: \(error)")
        }
    }

    @Test
    func missingPackageReportsItsLocalFileError() throws {
        let packageURL = Self.temporaryDirectoryURL()
            .appending(path: "ClauseTagger.mlpackage", directoryHint: .isDirectory)

        do {
            _ = try ClauseTaggerModel(packageURL: packageURL)
            Issue.record("A missing Core ML package unexpectedly loaded.")
        } catch let error as ClauseTaggerModelError {
            guard case .unavailable(let detail) = error else {
                Issue.record("Unexpected model error: \(error.localizedDescription)")
                return
            }
            #expect(detail.contains(".mlpackage が見つからないか、読み込めません"))
        } catch {
            Issue.record("Unexpected error for a missing package: \(error)")
        }
    }

    @Test
    func missingModelPackageFailsFast() throws {
        let directory = Self.temporaryDirectoryURL()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        do {
            _ = try LocalClauseTagger(modelDirectory: directory)
            Issue.record("A missing local model unexpectedly loaded.")
        } catch let error as ClauseTaggerModelError {
            guard case .unavailable(let detail) = error else {
                Issue.record("Unexpected local-model error: \(error.localizedDescription)")
                return
            }
            #expect(detail.contains(".mlpackage が見つからないか、読み込めません"))
        } catch {
            Issue.record("Unexpected error for a missing local model: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CLAUSE_TAGGER_TESTS"] == "1"))
    func realModelParityAndLocalTaggerBehaviorWhenEnabled() async throws {
        let document = try Self.loadFixture()
        let modelDirectory = try Self.requiredModelDirectory()
        let tokenizer = try ClauseTaggerTokenizer(
            tokenizerURL: modelDirectory.appending(path: "tokenizer.json"),
            expectedSHA256: document.tokenizerSHA256
        )
        let model = try ClauseTaggerModel(
            packageURL: modelDirectory.appending(path: "ClauseTagger.mlpackage", directoryHint: .isDirectory)
        )

        #expect(model.identity.modelID == document.modelID)
        #expect(model.identity.revision == document.modelRevision)
        #expect(model.identity.tokenizerSHA256 == document.tokenizerSHA256)

        var maxBoundaryDifference = 0.0
        var maxSpanDifference = 0.0
        var maxPriorityDifference = 0.0
        var predictions: [ClauseTaggerPrediction] = []

        for fixture in document.fixtures {
            let encoded = try ClauseTaggerEncoding.encode(text: fixture.text, next: fixture.next) { piece in
                try tokenizer.encodePiece(piece)
            }
            let expectedCandidates = try Self.integerKeyedCandidates(fixture.candidateTokenIndices)
            #expect(encoded.inputIDs.count >= fixture.inputIDs.count)
            #expect(
                Array(encoded.inputIDs.prefix(fixture.inputIDs.count - 1)) + [ClauseTaggerEncoding.sepTokenID]
                    == fixture.inputIDs
            )
            let retainedCandidates = encoded.candidateTokenIndices.reduce(into: [Int: Int]()) { result, entry in
                if entry.value < fixture.inputIDs.count - 1 {
                    result[entry.key] = entry.value
                }
            }
            #expect(retainedCandidates == expectedCandidates)
            let retainedJunctionIndex = encoded.junctionIndex.flatMap {
                $0 < fixture.inputIDs.count - 1 ? $0 : nil
            }
            #expect(retainedJunctionIndex == fixture.junctionIndex)

            if let next = fixture.next {
                let request = try Self.boundaryRequest(text: fixture.text, next: next)
                let continuation = try ClauseTaggerEncoding.continuationInput(request) { piece in
                    try tokenizer.encodePiece(piece)
                }
                #expect(continuation.inputIDs == fixture.inputIDs)
                #expect(continuation.candidateTokenIndices.isEmpty)
                #expect(continuation.junctionIndex == fixture.junctionIndex)
            }

            let prediction = try model.predict(inputIDs: fixture.inputIDs)
            #expect(prediction.boundaryProbabilities.count == fixture.inputIDs.count)
            #expect(prediction.spanProbabilities.count == fixture.inputIDs.count)
            #expect(prediction.spanProbabilities.allSatisfy { $0.count == 4 })
            #expect(prediction.priorityProbabilities.count == 2)
            maxBoundaryDifference = max(
                maxBoundaryDifference,
                Self.maxAbsoluteDifference(prediction.boundaryProbabilities, fixture.boundaryProbabilities)
            )
            maxSpanDifference = max(
                maxSpanDifference,
                Self.maxAbsoluteDifference(prediction.spanProbabilities, fixture.spanProbabilities)
            )
            maxPriorityDifference = max(
                maxPriorityDifference,
                Self.maxAbsoluteDifference(prediction.priorityProbabilities, fixture.priorityProbabilities)
            )
            predictions.append(prediction)
        }

        print("ClauseTagger boundary max abs diff: \(maxBoundaryDifference)")
        print("ClauseTagger span max abs diff: \(maxSpanDifference)")
        print("ClauseTagger priority max abs diff: \(maxPriorityDifference)")
        print("ClauseTagger tested input lengths: \(Array(Set(document.fixtures.map { $0.inputIDs.count })).sorted())")
        #expect(maxBoundaryDifference <= 1e-3)
        #expect(maxSpanDifference <= 1e-3)
        #expect(maxPriorityDifference <= 1e-3)

        let tagger = try LocalClauseTagger(modelDirectory: modelDirectory)
        let longFixture = try #require(document.fixtures.first {
            $0.inputIDs.count == ClauseTaggerEncoding.maximumTokens
        })
        let longBoundaryText = longFixture.text + "終わり"
        var assessedNoNextFixtures = 0
        for fixture in document.fixtures where fixture.next == nil && !fixture.candidateTokenIndices.isEmpty {
            let request = try Self.boundaryRequest(text: fixture.text)
            let fullInput = try ClauseTaggerEncoding.encode(text: fixture.text) { piece in
                try tokenizer.encodePiece(piece)
            }
            guard !request.candidates.isEmpty,
                  request.candidates.allSatisfy({ fullInput.candidateTokenIndices[$0.offsetUTF16] != nil }) else {
                continue
            }
            let boundaryInputs = try ClauseTaggerEncoding.boundaryInputs(request) { piece in
                try tokenizer.encodePiece(piece)
            }
            let windowPredictions = try boundaryInputs.map { try model.predict(inputIDs: $0.inputIDs) }
            let assignedOffsets = boundaryInputs.flatMap { $0.candidateTokenIndices.keys }.sorted()
            #expect(assignedOffsets == request.candidates.map(\.offsetUTF16).sorted())
            #expect(Set(assignedOffsets).count == request.candidates.count)

            var expectedProbabilities: [Int: Double] = [:]
            for (encoded, prediction) in zip(boundaryInputs, windowPredictions) {
                for (offset, tokenIndex) in encoded.candidateTokenIndices {
                    #expect(prediction.boundaryProbabilities.indices.contains(tokenIndex))
                    expectedProbabilities[offset] = prediction.boundaryProbabilities[tokenIndex][1]
                }
            }

            let response = try await tagger.assessBoundaries(request)
            #expect(response.probabilities.count == request.candidates.count)
            for candidate in request.candidates {
                let expectedProbability = try #require(expectedProbabilities[candidate.offsetUTF16])
                #expect(response.probabilities[candidate.id] == expectedProbability)
            }
            #expect(response.continuationProbability == nil)
            #expect(response.inputTokens == boundaryInputs.reduce(0) { $0 + $1.inputIDs.count })
            assessedNoNextFixtures += 1
        }
        #expect(assessedNoNextFixtures > 0)

        let longBoundaryRequest = try Self.boundaryRequest(text: longBoundaryText)
        let longFullInput = try ClauseTaggerEncoding.encode(text: longBoundaryText) { piece in
            try tokenizer.encodePiece(piece)
        }
        #expect(longFullInput.inputIDs.count == ClauseTaggerEncoding.maximumTokens)
        let longBoundaryInputs = try ClauseTaggerEncoding.boundaryInputs(longBoundaryRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let longWindowPredictions = try longBoundaryInputs.map { try model.predict(inputIDs: $0.inputIDs) }
        let longAssignedOffsets = longBoundaryInputs.flatMap { $0.candidateTokenIndices.keys }.sorted()
        #expect(longBoundaryInputs.count > 1)
        #expect(longAssignedOffsets == longBoundaryRequest.candidates.map(\.offsetUTF16).sorted())
        #expect(Set(longAssignedOffsets).count == longBoundaryRequest.candidates.count)
        var longExpectedProbabilities: [Int: Double] = [:]
        for (encoded, prediction) in zip(longBoundaryInputs, longWindowPredictions) {
            for (offset, tokenIndex) in encoded.candidateTokenIndices {
                longExpectedProbabilities[offset] = prediction.boundaryProbabilities[tokenIndex][1]
            }
        }
        let longBoundaryResponse = try await tagger.assessBoundaries(longBoundaryRequest)
        #expect(longBoundaryResponse.probabilities.count == longBoundaryRequest.candidates.count)
        for candidate in longBoundaryRequest.candidates {
            let expectedProbability = try #require(longExpectedProbabilities[candidate.offsetUTF16])
            #expect(longBoundaryResponse.probabilities[candidate.id] == expectedProbability)
        }
        #expect(
            longBoundaryResponse.inputTokens
                == longBoundaryInputs.reduce(0) { $0 + $1.inputIDs.count }
        )
        guard let continuationFixture = document.fixtures.first(where: { $0.next != nil }),
              let nextText = continuationFixture.next,
              let expectedJunction = continuationFixture.junctionIndex else {
            Issue.record("The fixture set must contain a continuation example.")
            return
        }
        let continuationRequest = try Self.boundaryRequest(text: continuationFixture.text, next: nextText)
        let continuationBoundaryInputs = try ClauseTaggerEncoding.boundaryInputs(continuationRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let continuationInput = try ClauseTaggerEncoding.continuationInput(continuationRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let continuationPrediction = try model.predict(inputIDs: continuationInput.inputIDs)
        let continuationResponse = try await tagger.assessBoundaries(continuationRequest)
        let continuationTokenIndex = try #require(continuationInput.junctionIndex)
        #expect(continuationTokenIndex == expectedJunction)
        #expect(
            continuationResponse.continuationProbability
                == 1 - continuationPrediction.boundaryProbabilities[continuationTokenIndex][1]
        )
        #expect(
            continuationResponse.inputTokens
                == continuationBoundaryInputs.reduce(0) { $0 + $1.inputIDs.count } + continuationInput.inputIDs.count
        )

        let longNextText = "続きです"
        let longContinuationRequest = try Self.boundaryRequest(text: longBoundaryText, next: longNextText)
        let longContinuationBoundaryInputs = try ClauseTaggerEncoding.boundaryInputs(longContinuationRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let longContinuationInput = try ClauseTaggerEncoding.continuationInput(longContinuationRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let longJunctionIndex = try #require(longContinuationInput.junctionIndex)
        let lastPiece = try #require(
            longBoundaryText.split(whereSeparator: { ClauseTaggerEncoding.punctuation.contains($0) }).last
        )
        let lastPieceTokenIDs = try tokenizer.encodePiece(String(lastPiece)).map(\.id)
        #expect(longContinuationInput.inputIDs.count <= ClauseTaggerEncoding.maximumTokens)
        #expect(longContinuationInput.inputIDs[longJunctionIndex] == ClauseTaggerEncoding.commaTokenID)
        #expect(longContinuationInput.inputIDs[longJunctionIndex - 1] == lastPieceTokenIDs.last)
        let longNextTokenIDs = try tokenizer.encodePiece(longNextText).map(\.id)
        #expect(Array(longContinuationInput.inputIDs.dropLast().suffix(longNextTokenIDs.count)) == longNextTokenIDs)

        let longBoundaryTokens = longContinuationBoundaryInputs.reduce(0) { $0 + $1.inputIDs.count }
        let longContinuationPrediction = try model.predict(inputIDs: longContinuationInput.inputIDs)
        let longContinuationResponse = try await tagger.assessBoundaries(longContinuationRequest)
        #expect(
            longContinuationResponse.continuationProbability
                == 1 - longContinuationPrediction.boundaryProbabilities[longJunctionIndex][1]
        )
        #expect(
            longContinuationResponse.inputTokens
                == longBoundaryTokens + longContinuationInput.inputIDs.count
        )

        let baseFixture = try #require(document.fixtures.first(where: { $0.next == nil && !$0.candidateTokenIndices.isEmpty }))
        let syntheticRequest = try Self.boundaryRequest(text: baseFixture.text, next: nextText)
        let baseInputs = try ClauseTaggerEncoding.boundaryInputs(syntheticRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let baseInput = try #require(baseInputs.first)
        #expect(baseInputs.count == 1)
        let syntheticContinuationInput = try ClauseTaggerEncoding.continuationInput(syntheticRequest) { piece in
            try tokenizer.encodePiece(piece)
        }
        let basePrediction = try model.predict(inputIDs: baseInput.inputIDs)
        let syntheticContinuationPrediction = try model.predict(inputIDs: syntheticContinuationInput.inputIDs)
        let syntheticResponse = try await tagger.assessBoundaries(syntheticRequest)
        let syntheticCandidateMap = try Self.integerKeyedCandidates(baseFixture.candidateTokenIndices)
        for candidate in syntheticRequest.candidates {
            let tokenIndex = try #require(syntheticCandidateMap[candidate.offsetUTF16])
            #expect(syntheticResponse.probabilities[candidate.id] == basePrediction.boundaryProbabilities[tokenIndex][1])
        }
        let syntheticJunctionIndex = try #require(syntheticContinuationInput.junctionIndex)
        #expect(
            syntheticResponse.continuationProbability
                == 1 - syntheticContinuationPrediction.boundaryProbabilities[syntheticJunctionIndex][1]
        )
        #expect(
            syntheticResponse.inputTokens
                == baseInputs.reduce(0) { $0 + $1.inputIDs.count } + syntheticContinuationInput.inputIDs.count
        )

        let noNextFixtures = document.fixtures.enumerated().filter { $0.element.next == nil }
        var priorityFixtures: [(offset: Int, element: ClauseTaggerFixture)] = []
        var priorityEncodedInputs: [ClauseTaggerEncodedInput] = []
        for item in noNextFixtures {
            let encoded = try ClauseTaggerEncoding.encode(text: item.element.text) { piece in
                try tokenizer.encodePiece(piece)
            }
            priorityFixtures.append(item)
            priorityEncodedInputs.append(encoded)
        }
        let targets = priorityFixtures.enumerated().map { index, item in
            PriorityTextTarget(key: String(format: "u%04d", index + 1), text: item.element.text)
        }
        let priorityResponse = try await tagger.classifyPriorities(targets)
        #expect(priorityResponse.decisions.count == priorityFixtures.count)
        let expectedPriorityInputTokens = priorityEncodedInputs.reduce(0) { $0 + $1.inputIDs.count }
        #expect(priorityResponse.inputTokens == expectedPriorityInputTokens)

        for (target, item) in zip(targets, priorityFixtures) {
            let prediction = predictions[item.offset]
            let decision = try #require(priorityResponse.decisions[target.key])
            let primary = prediction.priorityProbabilities[0]
            let lowPriority = prediction.priorityProbabilities[1]
            let maximum = max(primary, lowPriority)
            #expect(decision.probabilities["PRIMARY"] == primary)
            #expect(decision.probabilities["LOW_PRIORITY"] == lowPriority)
            #expect(decision.confidence == 2 * maximum - 1)
            #expect(decision.priority == (primary >= lowPriority ? .primary : .lowPriority))
            #expect(abs(primary - item.element.priorityProbabilities[0]) <= 1e-3)
            #expect(abs(lowPriority - item.element.priorityProbabilities[1]) <= 1e-3)
        }

        let overlongPriorityText = String(repeating: longBoundaryText, count: 3)
        let overlongPriorityInput = try ClauseTaggerEncoding.encode(text: overlongPriorityText) { piece in
            try tokenizer.encodePiece(piece)
        }
        #expect(overlongPriorityInput.inputIDs.count == ClauseTaggerEncoding.maximumTokens)
        let overlongPriorityResponse = try await tagger.classifyPriorities([
            PriorityTextTarget(key: "u0001", text: overlongPriorityText)
        ])
        let overlongPrediction = try model.predict(inputIDs: overlongPriorityInput.inputIDs)
        let overlongDecision = try #require(overlongPriorityResponse.decisions["u0001"])
        #expect(overlongDecision.probabilities["PRIMARY"] == overlongPrediction.priorityProbabilities[0])
        #expect(overlongDecision.probabilities["LOW_PRIORITY"] == overlongPrediction.priorityProbabilities[1])
        #expect(overlongPriorityResponse.inputTokens == ClauseTaggerEncoding.maximumTokens)

        try await Self.expectInvalidTargets {
            _ = try await tagger.classifyPriorities([])
        }
        try await Self.expectInvalidTargets {
            _ = try await tagger.classifyPriorities([
                PriorityTextTarget(key: "u0001", text: "有効な内容"),
                PriorityTextTarget(key: "u0001", text: "重複したキー")
            ])
        }
        try await Self.expectInvalidTargets {
            _ = try await tagger.classifyPriorities([PriorityTextTarget(key: "u0000", text: "有効な内容")])
        }
        try await Self.expectInvalidTargets {
            let tooManyTargets = (1...41).map { index in
                PriorityTextTarget(key: String(format: "u%04d", index), text: "対象 \(index)")
            }
            _ = try await tagger.classifyPriorities(tooManyTargets)
        }
        for emptyText in ["", " \n ", "\t\u{3000}"] {
            try await Self.expectInvalidTargets {
                _ = try await tagger.classifyPriorities([
                    PriorityTextTarget(key: "u0001", text: emptyText)
                ])
            }
        }
        for punctuationOnly in ["？", "？！", " 。 ! \t "] {
            let encoded = try ClauseTaggerEncoding.encode(text: punctuationOnly) { piece in
                try tokenizer.encodePiece(piece)
            }
            let response = try await tagger.classifyPriorities([
                PriorityTextTarget(key: "u0001", text: punctuationOnly)
            ])
            let prediction = try model.predict(inputIDs: encoded.inputIDs)
            let decision = try #require(response.decisions["u0001"])
            #expect(decision.probabilities["PRIMARY"] == prediction.priorityProbabilities[0])
            #expect(response.inputTokens == encoded.inputIDs.count)
        }

        let twoTokenPrediction = try model.predict(inputIDs: [6, 4])
        #expect(twoTokenPrediction.boundaryProbabilities.count == 2)
        #expect(twoTokenPrediction.spanProbabilities.count == 2)
        #expect(twoTokenPrediction.spanProbabilities.allSatisfy { $0.count == 4 })
        #expect(twoTokenPrediction.priorityProbabilities.count == 2)
        try Self.expectInvalidModelInput(model, inputIDs: [6, 102_400, 4])
        try Self.expectInvalidModelInput(model, inputIDs: [2, 4])

    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CLAUSE_TAGGER_TESTS"] == "1"))
    func realModelProjectsFillersAndCountsTerminalBoundaryInputWhenEnabled() async throws {
        let modelDirectory = try Self.requiredModelDirectory()
        let tagger = try LocalClauseTagger(modelDirectory: modelDirectory)

        let request = try Self.boundaryRequest(text: "まあ、あの、今日は損失関数の話をします。")
        let response = try await tagger.assessBoundaries(request)
        #expect(!response.fillerRanges.isEmpty)
        let projected = try TranscriptTextProjector().project(
            sourceText: request.text,
            fillerRanges: response.fillerRanges
        )
        #expect(projected.text == "今日は損失関数の話をします。")

        let terminalRequest = try Self.boundaryRequest(text: "まあ。")
        #expect(terminalRequest.candidates.isEmpty)
        #expect(terminalRequest.next == nil)
        let terminalResponse = try await tagger.assessBoundaries(terminalRequest)
        #expect(terminalResponse.inputTokens > 0)
    }

    private static func loadFixture() throws -> ClauseTaggerFixtureDocument {
        try ClauseTaggerFixtures.loadOriginal()
    }

    private static func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "mac-ambient-jev-clause-tagger-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private static func requiredModelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CLAUSE_TAGGER_MODEL_DIRECTORY"] else {
            throw LocalClauseTaggerTestSetupError.missingModelDirectoryEnvironment
        }
        guard path.hasPrefix("/") else {
            throw LocalClauseTaggerTestSetupError.modelDirectoryMustBeAbsolute
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalClauseTaggerTestSetupError.modelDirectoryMustExistAsDirectory(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    private static func candidateOffsetUpperBound(for fixture: ClauseTaggerFixture) -> Int {
        var scalars = removingTrailingPunctuation(from: Array(fixture.text.unicodeScalars))
        if let next = fixture.next {
            scalars.append(contentsOf: "、".unicodeScalars)
            scalars.append(contentsOf: next.unicodeScalars)
            scalars = removingTrailingPunctuation(from: scalars)
        }
        return scalars.reduce(into: 0) { offset, scalar in
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
    }

    private static func removingTrailingPunctuation(from scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        let punctuation = ClauseTaggerEncoding.punctuation.unicodeScalars
        var end = scalars.count
        while end > 0 && punctuation.contains(scalars[end - 1]) {
            end -= 1
        }
        return Array(scalars[..<end])
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func integerKeyedCandidates(_ candidates: [String: Int]) throws -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (offsetText, tokenIndex) in candidates {
            let offset = try #require(Int(offsetText))
            result[offset] = tokenIndex
        }
        return result
    }

    private static func boundaryRequest(text: String, next: String? = nil) throws -> ClauseBoundaryRequest {
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

    private static func isProbabilityDistribution(_ values: [Double]) -> Bool {
        values.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && abs(values.reduce(0, +) - 1) <= 1e-5
    }

    private static func maxAbsoluteDifference(_ left: [[Double]], _ right: [[Double]]) -> Double {
        zip(left, right).reduce(0.0) { largest, rows in
            max(largest, maxAbsoluteDifference(rows.0, rows.1))
        }
    }

    private static func maxAbsoluteDifference(_ left: [Double], _ right: [Double]) -> Double {
        zip(left, right).reduce(0.0) { max($0, abs($1.0 - $1.1)) }
    }

    private static func expectInvalidTargets(
        _ operation: () async throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        do {
            try await operation()
            Issue.record("Invalid priority targets unexpectedly succeeded.", sourceLocation: sourceLocation)
        } catch let error as ClauseValidationError {
            guard case .invalidTargets = error else {
                Issue.record("Unexpected clause validation error: \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("Unexpected error for invalid priority targets: \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func expectInvalidModelInput(
        _ model: ClauseTaggerModel,
        inputIDs: [Int],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        do {
            _ = try model.predict(inputIDs: inputIDs)
            Issue.record("Invalid model input unexpectedly succeeded: \(inputIDs)", sourceLocation: sourceLocation)
        } catch let error as ClauseTaggerModelError {
            guard case .invalidInput = error else {
                Issue.record("Unexpected model error: \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("Unexpected error for invalid model input: \(error)", sourceLocation: sourceLocation)
        }
    }
}
