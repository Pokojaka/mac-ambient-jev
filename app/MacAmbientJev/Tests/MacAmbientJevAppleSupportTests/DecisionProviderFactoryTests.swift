import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevAppleSupport

private struct UnexpectedLoad: Error {}

private final class LocalTaggerLoadFailure: Error, @unchecked Sendable {}

private func makeCoordinatorOnThread(
    _ factory: DecisionProviderFactory,
    failure: LocalTaggerLoadFailure
) async -> Bool {
    await withCheckedContinuation { continuation in
        Thread {
            do {
                _ = try factory.makeCoordinator()
                continuation.resume(returning: false)
            } catch {
                continuation.resume(returning: (error as AnyObject) === failure)
            }
        }.start()
    }
}

private final class FailingLocalTaggerLoader: @unchecked Sendable {
    private let lock = NSLock()
    private let failures: [LocalTaggerLoadFailure]
    private var attempts = 0

    init(failures: [LocalTaggerLoadFailure]) {
        self.failures = failures
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func load() throws -> LocalClauseTagger {
        lock.lock()
        let attempt = attempts
        attempts += 1
        lock.unlock()
        guard failures.indices.contains(attempt) else {
            throw UnexpectedLoad()
        }
        throw failures[attempt]
    }
}

private final class ThreadSafeLocalTaggerLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    func recordLoad() {
        lock.lock()
        loads += 1
        lock.unlock()
    }
}

private struct FactoryTestHarness {
    let temporaryRoot: URL
    let modelDirectory: URL
    let usageCounter: DecisionUsageCounter
    let factory: DecisionProviderFactory

    func cleanUp() {
        guard Self.isTestCreatedTemporaryRoot(temporaryRoot) else {
            Issue.record("Refusing to remove a path that is not this test's verified temporary root.")
            return
        }
        guard FileManager.default.fileExists(atPath: temporaryRoot.path) else { return }
        do {
            try FileManager.default.removeItem(at: temporaryRoot)
        } catch {
            Issue.record("Could not remove this test's temporary root: \(error)")
        }
    }

    static func isTestCreatedTemporaryRoot(_ root: URL) -> Bool {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let standardizedRoot = root.standardizedFileURL
        let namePrefix = "mac-ambient-jev-decision-provider-"
        guard standardizedRoot.path.hasPrefix("/"),
              standardizedRoot.deletingLastPathComponent() == temporaryDirectory,
              standardizedRoot.path.hasPrefix(temporaryDirectory.path + "/"),
              standardizedRoot.lastPathComponent.hasPrefix(namePrefix) else {
            return false
        }
        let identifier = String(standardizedRoot.lastPathComponent.dropFirst(namePrefix.count))
        return UUID(uuidString: identifier) != nil
    }
}

private struct LocalMetadataFixtureIdentity: Decodable {
    let modelID: String
    let modelRevision: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelRevision = "model_revision"
    }
}

private enum FactoryTestSetupError: LocalizedError {
    case missingModelDirectoryEnvironment
    case modelDirectoryMustBeAbsolute
    case modelDirectoryMustExist(String)
    case missingModelArtifact(String)
    case unsafeCopyLocation

    var errorDescription: String? {
        switch self {
        case .missingModelDirectoryEnvironment:
            "RUN_CLAUSE_TAGGER_TESTS=1 requires CLAUSE_TAGGER_MODEL_DIRECTORY to be set explicitly."
        case .modelDirectoryMustBeAbsolute:
            "CLAUSE_TAGGER_MODEL_DIRECTORY must be an absolute path."
        case .modelDirectoryMustExist(let path):
            "CLAUSE_TAGGER_MODEL_DIRECTORY must name an existing directory: \(path)"
        case .missingModelArtifact(let path):
            "The supplied model directory is missing a required artifact: \(path)"
        case .unsafeCopyLocation:
            "The model fixture and test-owned destination must be separate directories."
        }
    }
}

private struct SyntheticLocalDecisionProvider: DecisionProvider {
    let inputTokens: Int

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.75) }),
            continuationProbability: request.next == nil ? nil : 0.5,
            fillerRanges: [],
            inputTokens: inputTokens
        )
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        let decision = try ContentPriorityDecision(
            priority: .primary,
            confidence: 1,
            probabilities: ["PRIMARY": 1, "LOW_PRIORITY": 0]
        )
        return PriorityBatchResponse(
            decisions: Dictionary(uniqueKeysWithValues: targets.map { ($0.key, decision) }),
            inputTokens: inputTokens
        )
    }
}

@Suite
struct DecisionProviderFactoryTests {
    @Test
    func missingLocalModelFailsWithoutUsageAttempts() async throws {
        let harness = try Self.makeHarness()
        defer { harness.cleanUp() }

        do {
            _ = try harness.factory.makeCoordinator()
            Issue.record("The local tagger unexpectedly loaded without its model files.")
        } catch {
            #expect(error is ClauseTaggerTokenizerError || error is ClauseTaggerModelError)
        }

        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 0)
        #expect(usage.successCount == 0)
        #expect(usage.failureCount == 0)
    }

    @Test
    func localLoadFailureIsCachedForTheFactoryLifetime() throws {
        let firstFailure = LocalTaggerLoadFailure()
        let secondFailure = LocalTaggerLoadFailure()
        let loader = FailingLocalTaggerLoader(failures: [firstFailure, secondFailure])
        let harness = try Self.makeHarness(loadLocalTagger: { _ in try loader.load() })
        defer { harness.cleanUp() }

        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectLocalLoadFailure({ _ = try harness.factory.localModelIdentity() }, identicalTo: firstFailure)
        #expect(loader.attemptCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentRequestsShareOneLoad() async throws {
        let failure = LocalTaggerLoadFailure()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let release = DispatchSemaphore(value: 0)
        let loadCounter = ThreadSafeLocalTaggerLoadCounter()
        let harness = try Self.makeHarness(loadLocalTagger: { _ in
            loadCounter.recordLoad()
            startedContinuation.yield(())
            startedContinuation.finish()
            release.wait()
            throw failure
        })
        defer { harness.cleanUp() }

        let factory = harness.factory
        async let firstRequest = makeCoordinatorOnThread(factory, failure: failure)
        async let secondRequest = makeCoordinatorOnThread(factory, failure: failure)
        async let thirdRequest = makeCoordinatorOnThread(factory, failure: failure)

        var startedIterator = started.makeAsyncIterator()
        let loadDidStart: Void? = await startedIterator.next()
        try #require(loadDidStart != nil)
        await factory.waitForPendingLoadWaiters(2)
        #expect(factory.pendingLoadWaiterCount == 2)
        #expect(loadCounter.loadCount == 1)

        release.signal()
        let results = await (firstRequest, secondRequest, thirdRequest)
        #expect(results.0)
        #expect(results.1)
        #expect(results.2)
        #expect(loadCounter.loadCount == 1)
    }

    @Test
    func coordinatorProvenanceIdentifiesTheLoadedModel() async throws {
        let modelID = "synthetic-local-model"
        let revision = String(repeating: "b", count: 64)
        let identity = try DecisionModelIdentity(model: modelID, modelRevision: revision)
        let coordinator = DecisionCoordinator(
            provider: SyntheticLocalDecisionProvider(inputTokens: 1),
            identity: identity,
            usageCounter: DecisionUsageCounter()
        )

        Self.expectLocalProvenance(coordinator.boundaryProvenance(mode: "final"), modelID: modelID, revision: revision)
        Self.expectLocalProvenance(coordinator.priorityProvenance(mode: "final"), modelID: modelID, revision: revision)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CLAUSE_TAGGER_TESTS"] == "1"))
    func factoryRunsTrainedModelFromAnIsolatedCopyAndCachesIt() async throws {
        let sourceDirectory = try Self.requiredModelDirectory()
        let loadCounter = ThreadSafeLocalTaggerLoadCounter()
        let harness = try Self.makeHarness(loadLocalTagger: { modelDirectory in
            loadCounter.recordLoad()
            return try LocalClauseTagger(modelDirectory: modelDirectory)
        })
        defer { harness.cleanUp() }

        let fileManager = FileManager.default
        let modelDirectory = harness.modelDirectory
        let sourcePackage = sourceDirectory.appending(path: "ClauseTagger.mlpackage", directoryHint: .isDirectory)
        let sourceTokenizer = sourceDirectory.appending(path: "tokenizer.json")
        let copiedPackage = modelDirectory.appending(path: "ClauseTagger.mlpackage", directoryHint: .isDirectory)
        let copiedTokenizer = modelDirectory.appending(path: "tokenizer.json")
        guard !Self.isAtOrBelow(modelDirectory, root: sourceDirectory),
              !Self.isAtOrBelow(sourceDirectory, root: modelDirectory) else {
            throw FactoryTestSetupError.unsafeCopyLocation
        }
        guard fileManager.fileExists(atPath: sourcePackage.path) else {
            throw FactoryTestSetupError.missingModelArtifact(sourcePackage.path)
        }
        guard fileManager.fileExists(atPath: sourceTokenizer.path) else {
            throw FactoryTestSetupError.missingModelArtifact(sourceTokenizer.path)
        }

        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourcePackage, to: copiedPackage)
        try fileManager.copyItem(at: sourceTokenizer, to: copiedTokenizer)

        let fixture = try Self.loadModelFixtureIdentity()
        #expect(fixture.modelID == "sbintuitions/modernbert-ja-30m-multitagger")
        #expect(Self.isLowercaseSHA256(fixture.modelRevision))
        let confirmedIdentity = try harness.factory.localModelIdentity()
        #expect(confirmedIdentity.modelID == fixture.modelID)
        #expect(confirmedIdentity.revision == fixture.modelRevision)
        #expect(loadCounter.loadCount == 1)

        let coordinator = try harness.factory.makeCoordinator()
        #expect(loadCounter.loadCount == 1)
        Self.expectLocalProvenance(
            coordinator.boundaryProvenance(mode: "live"),
            modelID: confirmedIdentity.modelID,
            revision: confirmedIdentity.revision
        )
        Self.expectLocalProvenance(
            coordinator.priorityProvenance(mode: "live"),
            modelID: confirmedIdentity.modelID,
            revision: confirmedIdentity.revision
        )

        let source = try SegmentTextReference(
            segmentationRunID: "provider-fixture-run",
            segmentID: "fixture-segment-1",
            asrRunID: "provider-fixture-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "provider-fixture-run",
            segmentID: "fixture-segment-2",
            asrRunID: "provider-fixture-asr",
            asrEventSeq: 2
        )
        let next = try NextSegmentHead(source: nextSource, text: "そうですね。")
        let boundaryRequest = try ClauseBoundaryRequest(
            source: source,
            text: "今日は天気がいいですけど、明日は雨が降るそうです",
            next: next
        )
        let boundaryRecord: DecisionRequestRecord
        switch await coordinator.assessBoundaries(boundaryRequest) {
        case .answered(let response, let record):
            boundaryRecord = record
            #expect(response.inputTokens == record.inputTokens)
        case .failed(let message):
            Issue.record("The trained local boundary request failed: \(message)")
            return
        case .cancelled:
            Issue.record("The trained local boundary request was unexpectedly cancelled.")
            return
        }

        let priorityTargets = [
            PriorityTextTarget(key: "u0001", text: "今日は天気がいいですけど"),
            PriorityTextTarget(key: "u0002", text: "明日は雨が降るそうです")
        ]
        let priorityRecord: DecisionRequestRecord
        switch await coordinator.classifyPriorities(priorityTargets) {
        case .answered(let response, let record):
            priorityRecord = record
            #expect(response.decisions.count == 2)
            #expect(response.decisions["u0001"] != nil)
            #expect(response.decisions["u0002"] != nil)
            #expect(response.inputTokens == record.inputTokens)
        case .failed(let message):
            Issue.record("The trained local priority request failed: \(message)")
            return
        case .cancelled:
            Issue.record("The trained local priority request was unexpectedly cancelled.")
            return
        }

        for record in [boundaryRecord, priorityRecord] {
            #expect(record.requestID.hasPrefix("decisionreq_"))
        }
        let boundaryTokens = boundaryRecord.inputTokens
        let priorityTokens = priorityRecord.inputTokens
        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 2)
        #expect(usage.successCount == 2)
        #expect(usage.failureCount == 0)
        #expect(usage.inputTokens == boundaryTokens + priorityTokens)
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.boundaryRequests.successCount == 1)
        #expect(usage.boundaryRequests.inputTokens == boundaryTokens)
        #expect(usage.priorityRequests.sendCount == 1)
        #expect(usage.priorityRequests.successCount == 1)
        #expect(usage.priorityRequests.inputTokens == priorityTokens)

        try fileManager.removeItem(at: copiedTokenizer)
        #expect(!fileManager.fileExists(atPath: copiedTokenizer.path))
        let cachedCoordinator = try harness.factory.makeCoordinator()
        Self.expectLocalProvenance(
            cachedCoordinator.boundaryProvenance(mode: "live"),
            modelID: fixture.modelID,
            revision: fixture.modelRevision
        )
        Self.expectLocalProvenance(
            cachedCoordinator.priorityProvenance(mode: "live"),
            modelID: fixture.modelID,
            revision: fixture.modelRevision
        )
        #expect(loadCounter.loadCount == 1)
    }

    private static func makeHarness(
        loadLocalTagger: @escaping @Sendable (URL) throws -> LocalClauseTagger = {
            try LocalClauseTagger(modelDirectory: $0)
        }
    ) throws -> FactoryTestHarness {
        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "mac-ambient-jev-decision-provider-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        ).standardizedFileURL
        guard FactoryTestHarness.isTestCreatedTemporaryRoot(temporaryRoot) else {
            throw FactoryTestSetupError.unsafeCopyLocation
        }
        let modelDirectory = temporaryRoot.appending(path: "clause-tagger", directoryHint: .isDirectory)
        let usageCounter = DecisionUsageCounter()
        let factory = DecisionProviderFactory(usageCounter: usageCounter) { try loadLocalTagger(modelDirectory) }
        return FactoryTestHarness(
            temporaryRoot: temporaryRoot, modelDirectory: modelDirectory, usageCounter: usageCounter, factory: factory
        )
    }

    private static func requiredModelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["CLAUSE_TAGGER_MODEL_DIRECTORY"] else {
            throw FactoryTestSetupError.missingModelDirectoryEnvironment
        }
        guard path.hasPrefix("/") else {
            throw FactoryTestSetupError.modelDirectoryMustBeAbsolute
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FactoryTestSetupError.modelDirectoryMustExist(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func loadModelFixtureIdentity() throws -> LocalMetadataFixtureIdentity {
        let fixtureURL = try #require(Bundle.module.url(forResource: "ClauseTaggerFixtures", withExtension: "json"))
        return try JSONDecoder().decode(LocalMetadataFixtureIdentity.self, from: Data(contentsOf: fixtureURL))
    }

    private static func isAtOrBelow(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func expectLocalLoadFailure(
        _ operation: () throws -> Void,
        identicalTo expected: LocalTaggerLoadFailure
    ) {
        do {
            try operation()
            Issue.record("The failing local tagger loader unexpectedly succeeded.")
        } catch {
            guard let actual = error as? LocalTaggerLoadFailure else {
                Issue.record("The local tagger loader returned an unexpected error: \(error)")
                return
            }
            #expect(actual === expected)
        }
    }

    private static func expectLocalProvenance(_ provenance: RunProvenance, modelID: String, revision: String) {
        #expect(provenance.engine == "coreml-clause-tagger")
        #expect(provenance.model == modelID)
        #expect(provenance.version == revision)
        #expect(provenance.configuration["model_id"] == modelID)
        #expect(provenance.configuration["model_revision"] == revision)
        #expect(provenance.configuration["unit_policy"] == "btsj-utterance-sentence")
        #expect(provenance.configuration["compute_units"] == "cpu-only")
    }
}
