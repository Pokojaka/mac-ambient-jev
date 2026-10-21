import Foundation
import MacAmbientJevClauseTaggerFixtures
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

private enum ClauseTaggerTestInputError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case let .invalid(reason): "Clause tagger test input is invalid: \(reason)"
        }
    }
}

private enum ClauseTaggerTestInputs {
    static let modelDirectoryKey = "MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY"
    static let intraOpThreads = 4
    static let tolerance = 1e-3

    /// The directory `scripts/fetch_clause_tagger.py` printed. There is no default, and a missing or
    /// wrong value fails the test instead of skipping it.
    static func modelDirectory() throws -> URL {
        let hint = "Run `python3 scripts/fetch_clause_tagger.py` and export the directory it prints as \(modelDirectoryKey)."
        guard let path = ProcessInfo.processInfo.environment[modelDirectoryKey], !path.isEmpty else {
            throw ClauseTaggerTestInputError.invalid("environment variable \(modelDirectoryKey) is not set. \(hint)")
        }
        guard (path as NSString).isAbsolutePath else {
            throw ClauseTaggerTestInputError.invalid("\(modelDirectoryKey) must be an absolute path: \(path). \(hint)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ClauseTaggerTestInputError.invalid("\(modelDirectoryKey) is not an existing directory: \(path). \(hint)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated(unsafe) static let model: Result<ONNXClauseTaggerModel, any Error> = Result {
        try ONNXClauseTaggerModel(
            assets: ClauseTaggerAssets(modelDirectory: modelDirectory()),
            intraOpThreads: intraOpThreads
        )
    }

    static let tagger: Result<ONNXClauseTagger, any Error> = Result {
        try ONNXClauseTagger(modelDirectory: modelDirectory(), intraOpThreads: intraOpThreads)
    }
}

private struct RequestFixtureDocument: Decodable {
    struct Request: Decodable {
        let source: SegmentTextReference
        let text: String
        let candidates: [ClauseBoundaryCandidate]
        let next: NextSegmentHead?

        func makeRequest() throws -> ClauseBoundaryRequest {
            try ClauseBoundaryRequest(source: source, text: text, candidates: candidates, next: next)
        }
    }

    struct BoundaryResponse: Decodable {
        let probabilities: [String: Double]
        let continuationProbability: Double?
        let fillerRanges: [TextUTF16Range]
        let inputTokens: Int

        enum CodingKeys: String, CodingKey {
            case probabilities
            case continuationProbability = "continuation_probability"
            case fillerRanges = "filler_ranges"
            case inputTokens = "input_tokens"
        }
    }

    struct BoundaryCase: Decodable {
        let name: String
        let request: Request
        let response: BoundaryResponse
        let projectedText: String

        enum CodingKeys: String, CodingKey {
            case name, request, response
            case projectedText = "projected_text"
        }
    }

    struct Target: Decodable {
        let key: String
        let text: String
    }

    struct PriorityResponse: Decodable {
        let decisions: [String: ContentPriorityDecision]
        let inputTokens: Int

        enum CodingKeys: String, CodingKey {
            case decisions
            case inputTokens = "input_tokens"
        }
    }

    struct PriorityBatch: Decodable {
        let name: String
        let targets: [Target]
        let response: PriorityResponse
    }

    let modelRevision: String
    let tokenizerSHA256: String
    let boundaryCases: [BoundaryCase]
    let priorityBatches: [PriorityBatch]

    enum CodingKeys: String, CodingKey {
        case modelRevision = "model_revision"
        case tokenizerSHA256 = "tokenizer_sha256"
        case boundaryCases = "boundary_cases"
        case priorityBatches = "priority_batches"
    }

    static func load() throws -> RequestFixtureDocument {
        let url = try ClauseTaggerFixtures.resourceURL(named: "ClauseTaggerRequestFixtures")
        return try JSONDecoder().decode(RequestFixtureDocument.self, from: Data(contentsOf: url))
    }
}

private func maxAbsoluteError(_ actual: [[Double]], _ expected: [[Double]]) -> Double? {
    guard actual.count == expected.count else { return nil }
    var maximum = 0.0
    for (actualRow, expectedRow) in zip(actual, expected) {
        guard actualRow.count == expectedRow.count else { return nil }
        for (a, e) in zip(actualRow, expectedRow) {
            maximum = max(maximum, abs(a - e))
        }
    }
    return maximum
}

@Suite(.serialized)
struct ONNXClauseTaggerTests {
    @Test func relativeModelDirectoryFailsBeforeLoading() throws {
        let relative = try #require(URL(string: "relative/clause-tagger"))
        let error = try #require(throwing { try ONNXClauseTagger(modelDirectory: relative, intraOpThreads: 1) })
        guard case ClauseTaggerAssetsError.directoryNotAbsolute = error else {
            Issue.record("expected directoryNotAbsolute, got \(error)")
            return
        }
    }

    @Test func missingModelDirectoryNamesTheFetchCommand() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-clause-tagger-missing-\(UUID().uuidString)", isDirectory: true)
        let error = try #require(throwing { try ONNXClauseTagger(modelDirectory: missing, intraOpThreads: 1) })
        guard case ClauseTaggerAssetsError.directoryMissing = error else {
            Issue.record("expected directoryMissing, got \(error)")
            return
        }
        #expect("\(error)".contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func nonPositiveThreadCountIsRejectedBeforeLoading() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("onnx-clause-tagger-missing-\(UUID().uuidString)", isDirectory: true)
        for threads in [0, -1] {
            let error = try #require(throwing { try ONNXClauseTagger(modelDirectory: missing, intraOpThreads: threads) })
            guard case ClauseTaggerModelError.unavailable = error else {
                Issue.record("threads=\(threads): expected unavailable, got \(error)")
                continue
            }
        }
    }

    @Test func modelRejectsInputsOutsideTheContract() throws {
        let model = try ClauseTaggerTestInputs.model.get()
        let cls = ClauseTaggerEncoding.clsTokenID
        let sep = ClauseTaggerEncoding.sepTokenID
        let content = Array(repeating: ClauseTaggerEncoding.commaTokenID, count: 191)
        let invalid: [(String, [Int])] = [
            ("empty", []),
            ("one token", [cls]),
            ("193 tokens", [cls] + content + [sep]),
            ("missing CLS", [sep, sep]),
            ("missing SEP", [cls, cls]),
            ("negative id", [cls, -1, sep]),
            ("id past the vocabulary", [cls, 102_400, sep]),
        ]
        for (name, ids) in invalid {
            do {
                _ = try model.predict(inputIDs: ids)
                Issue.record("\(name) unexpectedly ran")
            } catch ClauseTaggerModelError.invalidInput {
            } catch {
                Issue.record("\(name): unexpected error \(error)")
            }
        }
        let shortest = try model.predict(inputIDs: [cls, sep])
        #expect(shortest.boundaryProbabilities.count == 2)
        let longest = try model.predict(inputIDs: [cls] + content.dropLast() + [sep])
        #expect(longest.boundaryProbabilities.count == 192)
    }

    @Test func originalFixturesMatchEveryHeadWithinTolerance() throws {
        let model = try ClauseTaggerTestInputs.model.get()
        let document = try ClauseTaggerFixtures.loadOriginal()
        #expect(document.fixtures.count == 13)
        let pinnedRevision = try ClauseTaggerAssets.pinnedIdentity().revision
        #expect(document.modelRevision == pinnedRevision)
        var maxima = (boundary: 0.0, span: 0.0, priority: 0.0)
        for (index, fixture) in document.fixtures.enumerated() {
            let prediction = try model.predict(inputIDs: fixture.inputIDs)
            let boundary = maxAbsoluteError(prediction.boundaryProbabilities, fixture.boundaryProbabilities)
            let span = maxAbsoluteError(prediction.spanProbabilities, fixture.spanProbabilities)
            let priority = maxAbsoluteError([prediction.priorityProbabilities], [fixture.priorityProbabilities])
            #expect(boundary != nil && span != nil && priority != nil, "fixture \(index) head shapes")
            guard let boundary, let span, let priority else { continue }
            print("ClauseTagger ONNX fixture \(index) tokens=\(fixture.inputIDs.count) boundary=\(boundary) span=\(span) priority=\(priority)")
            #expect(boundary <= ClauseTaggerTestInputs.tolerance, "fixture \(index) boundary max abs error")
            #expect(span <= ClauseTaggerTestInputs.tolerance, "fixture \(index) span max abs error")
            #expect(priority <= ClauseTaggerTestInputs.tolerance, "fixture \(index) priority max abs error")
            maxima = (max(maxima.boundary, boundary), max(maxima.span, span), max(maxima.priority, priority))
        }
        print("ClauseTagger ONNX original fixtures max abs error: boundary=\(maxima.boundary) span=\(maxima.span) priority=\(maxima.priority)")
    }

    @Test func boundaryRequestFixturesMatchTheCoreMLResponses() async throws {
        let tagger = try ClauseTaggerTestInputs.tagger.get()
        let document = try RequestFixtureDocument.load()
        #expect(document.modelRevision == tagger.identity.revision)
        #expect(document.tokenizerSHA256 == tagger.identity.tokenizerSHA256)
        #expect(document.boundaryCases.count == 6)
        var maximum = 0.0
        for fixtureCase in document.boundaryCases {
            let request = try fixtureCase.request.makeRequest()
            let response = try await tagger.assessBoundaries(request)
            let expected = fixtureCase.response
            #expect(Set(response.probabilities.keys) == Set(expected.probabilities.keys), "\(fixtureCase.name) candidate keys")
            #expect(response.probabilities.count == expected.probabilities.count, "\(fixtureCase.name) candidate count")
            #expect(response.inputTokens == expected.inputTokens, "\(fixtureCase.name) input tokens")
            #expect(response.fillerRanges == expected.fillerRanges, "\(fixtureCase.name) filler ranges")
            for key in expected.probabilities.keys.sorted() {
                guard let actual = response.probabilities[key], let wanted = expected.probabilities[key] else { continue }
                let error = abs(actual - wanted)
                maximum = max(maximum, error)
                #expect(error <= ClauseTaggerTestInputs.tolerance, "\(fixtureCase.name) probability \(key)")
            }
            #expect(
                (response.continuationProbability == nil) == (expected.continuationProbability == nil),
                "\(fixtureCase.name) continuation presence"
            )
            if let actual = response.continuationProbability, let wanted = expected.continuationProbability {
                let error = abs(actual - wanted)
                maximum = max(maximum, error)
                #expect(error <= ClauseTaggerTestInputs.tolerance, "\(fixtureCase.name) continuation probability")
            }
            let projected = try TranscriptTextProjector().project(
                sourceText: request.text,
                fillerRanges: response.fillerRanges
            ).text
            #expect(Data(projected.utf8) == Data(fixtureCase.projectedText.utf8), "\(fixtureCase.name) projected text")
            if fixtureCase.name == "filler" {
                #expect(request.text == "まあ、あの、今日は損失関数の話をします。")
                #expect(projected == "今日は損失関数の話をします。")
            }
        }
        print("ClauseTagger ONNX boundary request fixtures max abs probability error=\(maximum)")
    }

    @Test func priorityRequestFixturesMatchTheCoreMLResponses() async throws {
        let tagger = try ClauseTaggerTestInputs.tagger.get()
        let document = try RequestFixtureDocument.load()
        #expect(document.priorityBatches.count == 1)
        var maximum = 0.0
        for batch in document.priorityBatches {
            let targets = batch.targets.map { PriorityTextTarget(key: $0.key, text: $0.text) }
            let response = try await tagger.classifyPriorities(targets)
            #expect(response.inputTokens == batch.response.inputTokens, "\(batch.name) input tokens")
            #expect(Set(response.decisions.keys) == Set(batch.response.decisions.keys), "\(batch.name) keys")
            for (key, expected) in batch.response.decisions.sorted(by: { $0.key < $1.key }) {
                guard let actual = response.decisions[key] else { continue }
                #expect(actual.priority == expected.priority, "\(key) priority label")
                #expect(Set(actual.probabilities.keys) == Set(expected.probabilities.keys), "\(key) probability keys")
                let confidenceError = abs(actual.confidence - expected.confidence)
                maximum = max(maximum, confidenceError)
                #expect(confidenceError <= ClauseTaggerTestInputs.tolerance, "\(key) confidence")
                for (label, wanted) in expected.probabilities {
                    guard let value = actual.probabilities[label] else { continue }
                    let error = abs(value - wanted)
                    maximum = max(maximum, error)
                    #expect(error <= ClauseTaggerTestInputs.tolerance, "\(key) \(label) probability")
                }
            }
        }
        print("ClauseTagger ONNX priority request fixtures max abs error=\(maximum)")
    }

    @Test func cancelledRequestThrowsCancellation() async throws {
        let tagger = try ClauseTaggerTestInputs.tagger.get()
        let document = try RequestFixtureDocument.load()
        let request = try #require(document.boundaryCases.first).request.makeRequest()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await tagger.assessBoundaries(request)
        }
        do {
            _ = try await task.value
            Issue.record("A cancelled request unexpectedly completed.")
        } catch is CancellationError {
        }
    }

    @Test func factoryLoadsTheProviderOnceAndReturnsItsIdentity() throws {
        let directory = try ClauseTaggerTestInputs.modelDirectory()
        let loads = LoadCounter()
        let factory = DecisionProviderFactory(usageCounter: DecisionUsageCounter()) {
            loads.record()
            let tagger = try ONNXClauseTagger(modelDirectory: directory, intraOpThreads: ClauseTaggerTestInputs.intraOpThreads)
            return LoadedDecisionProvider(provider: tagger, identity: tagger.identity)
        }
        let pinned = try ClauseTaggerAssets.pinnedIdentity()
        #expect(try factory.localModelIdentity() == pinned)
        _ = try factory.makeCoordinator()
        _ = try factory.makeCoordinator()
        #expect(try factory.localModelIdentity() == pinned)
        #expect(loads.count == 1)
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    var count: Int { lock.withLock { loads } }

    func record() { lock.withLock { loads += 1 } }
}

private func throwing(_ body: () throws -> some Any) -> (any Error)? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}
