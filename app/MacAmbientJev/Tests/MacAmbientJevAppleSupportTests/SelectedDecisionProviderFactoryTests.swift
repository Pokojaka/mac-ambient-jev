import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevAppleSupport

private enum SecretStoreMockError: Error, Sendable {
    case unexpectedOperation
}

private final class ThreadSafeMockSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let loadResult: Result<String?, SecretStoreMockError>
    private var loads = 0
    private var loadedAccounts: [String] = []

    init(loadResult: Result<String?, SecretStoreMockError> = .success(nil)) {
        self.loadResult = loadResult
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var loadAccounts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadedAccounts
    }

    func load(account: String) throws -> String? {
        lock.lock()
        loads += 1
        loadedAccounts.append(account)
        lock.unlock()
        return try loadResult.get()
    }

    func save(_ value: String, account: String) throws {
        throw SecretStoreMockError.unexpectedOperation
    }

    func contains(account: String) throws -> Bool {
        throw SecretStoreMockError.unexpectedOperation
    }

    func delete(account: String) throws {
        throw SecretStoreMockError.unexpectedOperation
    }
}

private func blockingWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

private final class LocalTaggerLoadFailure: Error, @unchecked Sendable {}

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
            throw SecretStoreMockError.unexpectedOperation
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
    let defaultsSuiteName: String
    let paths: AppPaths
    let defaults: UserDefaults
    let secretStore: ThreadSafeMockSecretStore
    let usageCounter: DecisionUsageCounter
    let factory: SelectedDecisionProviderFactory

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
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
        let namePrefix = "mac-ambient-jev-selected-provider-"
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
    case unavailableDefaultsSuite
    case missingModelDirectoryEnvironment
    case modelDirectoryMustBeAbsolute
    case modelDirectoryMustExist(String)
    case missingModelArtifact(String)
    case unsafeCopyLocation

    var errorDescription: String? {
        switch self {
        case .unavailableDefaultsSuite:
            "Could not create an isolated UserDefaults suite for the factory test."
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
    let metadata: DecisionResponseMetadata

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        ClauseBoundaryResponse(
            probabilities: Dictionary(uniqueKeysWithValues: request.candidates.map { ($0.id, 0.75) }),
            continuationProbability: request.next == nil ? nil : 0.5,
            metadata: metadata
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
            metadata: metadata
        )
    }
}

@Suite
struct SelectedDecisionProviderFactoryTests {
    @Test
    func missingLocalModelFailsWithoutCredentialReadsOrUsageAttempts() async throws {
        let harness = try Self.makeHarness(engine: DecisionEngineChoice.localModel.rawValue)
        defer { harness.cleanUp() }

        do {
            _ = try harness.factory.makeCoordinator()
            Issue.record("The selected local engine unexpectedly loaded without its model files.")
        } catch {
            #expect(error is ClauseTaggerTokenizerError || error is ClauseTaggerModelError)
        }

        #expect(harness.secretStore.loadCount == 0)
        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 0)
        #expect(usage.successCount == 0)
        #expect(usage.failureCount == 0)
    }

    @Test
    func localLoadFailureIsCachedUntilTheEngineSelectionChanges() throws {
        let firstFailure = LocalTaggerLoadFailure()
        let secondFailure = LocalTaggerLoadFailure()
        let loader = FailingLocalTaggerLoader(failures: [firstFailure, secondFailure])
        let harness = try Self.makeHarness(
            engine: DecisionEngineChoice.localModel.rawValue,
            loadLocalTagger: { _ in try loader.load() }
        )
        defer { harness.cleanUp() }

        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: firstFailure)
        Self.expectLocalLoadFailure({ _ = try harness.factory.localModelIdentity() }, identicalTo: firstFailure)
        #expect(loader.attemptCount == 1)

        harness.defaults.set(true, forKey: DecisionEnginePreference.pauseKey)
        switch try harness.factory.makeCoordinator() {
        case .stopped:
            break
        case .available, .unconfigured:
            Issue.record("A paused engine did not stop before local model access.")
        }
        Self.expectLocalLoadFailure({ _ = try harness.factory.localModelIdentity() }, identicalTo: firstFailure)

        harness.defaults.set(false, forKey: DecisionEnginePreference.pauseKey)
        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: firstFailure)
        #expect(loader.attemptCount == 1)

        try harness.factory.selectEngine(.jev)
        #expect(try DecisionEnginePreference.load(defaults: harness.defaults) == .jev)
        try harness.factory.selectEngine(.localModel)
        #expect(try DecisionEnginePreference.load(defaults: harness.defaults) == .localModel)
        Self.expectLocalLoadFailure({ _ = try harness.factory.makeCoordinator() }, identicalTo: secondFailure)
        #expect(loader.attemptCount == 2)
        #expect(harness.secretStore.loadCount == 0)
    }

    @Test
    func concurrentRequestsShareOneLoadAndSelectionChangesNeverWaitForIt() async throws {
        let failure = LocalTaggerLoadFailure()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let loadCounter = ThreadSafeLocalTaggerLoadCounter()
        let harness = try Self.makeHarness(
            engine: DecisionEngineChoice.localModel.rawValue,
            loadLocalTagger: { _ in
                loadCounter.recordLoad()
                started.signal()
                release.wait()
                throw failure
            }
        )
        defer { harness.cleanUp() }

        let factory = harness.factory
        let requests = (0..<3).map { _ in
            Task.detached { () -> Bool in
                do {
                    _ = try factory.makeCoordinator()
                    return false
                } catch {
                    return (error as AnyObject) === failure
                }
            }
        }
        await Task.detached { blockingWait(started) }.value
        try await Task.sleep(for: .milliseconds(300))

        try factory.selectEngine(.localModel)
        #expect(loadCounter.loadCount == 1)

        for _ in requests { release.signal() }
        for request in requests {
            #expect(await request.value)
        }
        #expect(loadCounter.loadCount == 1)
    }

    @Test
    func invalidEngineSelectionFailsStrictlyBeforeCredentialAccess() throws {
        let harness = try Self.makeHarness(engine: "unknown-engine")
        defer { harness.cleanUp() }

        do {
            _ = try harness.factory.makeCoordinator()
            Issue.record("An invalid engine preference unexpectedly selected a provider.")
        } catch let error as DecisionEnginePreferenceError {
            if case .invalidSelection = error {
                // The strict preference error is the expected result.
            } else {
                Issue.record("Unexpected preference error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error for an invalid engine preference: \(error)")
        }

        #expect(harness.secretStore.loadCount == 0)
    }

    @Test
    func selectingEngineDoesNotCorrectAnInvalidPreferenceOrResetTheCache() throws {
        let invalidSelection = "unknown-engine"
        let cachedFailure = LocalTaggerLoadFailure()
        let loader = FailingLocalTaggerLoader(failures: [cachedFailure])
        let harness = try Self.makeHarness(
            engine: DecisionEngineChoice.localModel.rawValue,
            loadLocalTagger: { _ in try loader.load() }
        )
        defer { harness.cleanUp() }

        Self.expectLocalLoadFailure({ _ = try harness.factory.localModelIdentity() }, identicalTo: cachedFailure)
        harness.defaults.set(invalidSelection, forKey: DecisionEnginePreference.key)

        do {
            try harness.factory.selectEngine(.jev)
            Issue.record("Selecting an engine unexpectedly corrected an invalid preference.")
        } catch let error as DecisionEnginePreferenceError {
            if case .invalidSelection = error {
                // The existing invalid preference must remain untouched.
            } else {
                Issue.record("Unexpected preference error: \(error)")
            }
        } catch {
            Issue.record("Unexpected error while selecting an engine: \(error)")
        }

        #expect(harness.defaults.object(forKey: DecisionEnginePreference.key) as? String == invalidSelection)
        harness.defaults.set(DecisionEngineChoice.localModel.rawValue, forKey: DecisionEnginePreference.key)
        Self.expectLocalLoadFailure({ _ = try harness.factory.localModelIdentity() }, identicalTo: cachedFailure)
        #expect(loader.attemptCount == 1)
    }

    @Test
    func pausedLocalEngineStopsBeforeCredentialOrModelAccess() async throws {
        let harness = try Self.makeHarness(engine: DecisionEngineChoice.localModel.rawValue, paused: true)
        defer { harness.cleanUp() }

        switch try harness.factory.makeCoordinator() {
        case .stopped:
            break
        case .available, .unconfigured:
            Issue.record("A paused local engine did not stop before provider selection.")
        }

        #expect(harness.secretStore.loadCount == 0)
        #expect(!FileManager.default.fileExists(atPath: LocalClauseTagger.modelDirectory(paths: harness.paths).path))
        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 0)
    }

    @Test
    func jevWithoutKeyIsUnconfiguredAndNeverAttemptsTheLocalModel() async throws {
        let harness = try Self.makeHarness(engine: DecisionEngineChoice.jev.rawValue)
        defer { harness.cleanUp() }

        switch try harness.factory.makeCoordinator() {
        case .unconfigured:
            break
        case .available, .stopped:
            Issue.record("Jev without a key did not report an unconfigured provider.")
        }

        #expect(harness.secretStore.loadCount == 1)
        #expect(harness.secretStore.loadAccounts == ["jev-api-key"])
        #expect(!FileManager.default.fileExists(atPath: LocalClauseTagger.modelDirectory(paths: harness.paths).path))
        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 0)
    }

    @Test
    func responseMetadataRoundTripsAndRejectsMissingOrInvalidIdentity() throws {
        let jevMetadata = try DecisionResponseMetadata(model: "jev-model-v1", inputTokens: 17, outputTokens: 4)
        let localRevision = String(repeating: "a", count: 64)
        let localMetadata = try DecisionResponseMetadata(
                identity: DecisionModelIdentity(provider: .localModel, model: "sbintuitions/modernbert-ja-30m-multitagger", modelRevision: localRevision),
                inputTokens: 29,
                outputTokens: 0
            )

        for metadata in [jevMetadata, localMetadata] {
            let encoded = try JSONEncoder().encode(metadata)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["provider"] as? String == metadata.provider.rawValue)
            #expect(object["model_revision"] as? String == metadata.modelRevision)
            #expect(try JSONDecoder().decode(DecisionResponseMetadata.self, from: encoded) == metadata)
        }
        #expect(jevMetadata.provider == .jev)
        #expect(localMetadata.provider == .localModel)
        #expect(localMetadata.model == "sbintuitions/modernbert-ja-30m-multitagger")
        #expect(localMetadata.modelRevision == localRevision)

        Self.expectMetadataDecodeFailure(#"{"model":"jev-model","model_revision":"jev-model","input_tokens":1,"output_tokens":0}"#)
        Self.expectMetadataDecodeFailure(#"{"provider":"jev","model":"jev-model","input_tokens":1,"output_tokens":0}"#)
        Self.expectMetadataDecodeFailure(#"{"provider":"jev","model":"jev-v1","model_revision":"jev-v2","input_tokens":1,"output_tokens":0}"#)
        Self.expectMetadataDecodeFailure(#"{"provider":"unknown","model":"jev-model","model_revision":"jev-model","input_tokens":1,"output_tokens":0}"#)
        Self.expectMetadataDecodeFailure(#"{"provider":"local-coreml","model":"local-model","model_revision":"not-a-sha256","input_tokens":1,"output_tokens":0}"#)
        Self.expectMetadataDecodeFailure(#"{"provider":"jev","model":"jev-model","model_revision":"jev-model","input_tokens":-1,"output_tokens":0}"#)
    }

    @Test
    func coordinatorProvenanceIdentifiesTheSelectedLocalModelWithoutEndpoint() async throws {
        let modelID = "synthetic-local-model"
        let revision = String(repeating: "b", count: 64)
        let metadata = try DecisionResponseMetadata(
                identity: DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision),
                inputTokens: 1,
                outputTokens: 0
            )
        let coordinator = DecisionCoordinator(
            provider: SyntheticLocalDecisionProvider(metadata: metadata), identity: try DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: revision), usageCounter: DecisionUsageCounter()
        )

        Self.expectLocalProvenance(coordinator.boundaryProvenance(mode: "final"), modelID: modelID, revision: revision)
        Self.expectLocalProvenance(coordinator.priorityProvenance(mode: "final"), modelID: modelID, revision: revision)

        let jevMetadata = try DecisionResponseMetadata(model: "jev-model", inputTokens: nil, outputTokens: nil)
        let jevCoordinator = DecisionCoordinator(
            provider: SyntheticLocalDecisionProvider(metadata: jevMetadata),
            identity: .jev,
            usageCounter: DecisionUsageCounter()
        )
        #expect(jevCoordinator.boundaryProvenance(mode: "final").configuration["unit_policy"] == "btsj-utterance-sentence")
        #expect(jevCoordinator.priorityProvenance(mode: "final").configuration["unit_policy"] == "btsj-utterance-sentence")
    }

    @Test
    func localRevisionMismatchRejectsTheWholeRequestAndStopsTheBatch() async throws {
        let modelID = "synthetic-local-model"
        let expectedRevision = String(repeating: "c", count: 64)
        let actualRevision = String(repeating: "d", count: 64)
        let wrongMetadata = try DecisionResponseMetadata(
                identity: DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: actualRevision),
                inputTokens: 2,
                outputTokens: 0
            )
        let usageCounter = DecisionUsageCounter()
        let coordinator = DecisionCoordinator(
            provider: SyntheticLocalDecisionProvider(metadata: wrongMetadata), identity: try DecisionModelIdentity(provider: .localModel, model: modelID, modelRevision: expectedRevision), usageCounter: usageCounter
        )
        let source = try SegmentTextReference(
            segmentationRunID: "identity-mismatch-run",
            segmentID: "source-1",
            asrRunID: "identity-mismatch-asr",
            asrEventSeq: 1
        )
        let request = try ClauseBoundaryRequest(source: source, text: "今日は天気、いいです", next: nil)

        switch await coordinator.assessBoundaries(request) {
        case .failed(let stopReason, let message):
            #expect(stopReason == .providerUnavailable)
            #expect(message == DecisionResponseError.invalidResponse.localizedDescription)
        case .answered, .cancelled:
            Issue.record("A local response with a mismatched model revision was accepted.")
        }

        let usage = await usageCounter.snapshot()
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.boundaryRequests.successCount == 0)
        #expect(usage.boundaryRequests.failureCount == 1)
        #expect(usage.priorityRequests.sendCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CLAUSE_TAGGER_TESTS"] == "1"))
    func selectedFactoryRunsTrainedModelFromAnIsolatedCopyAndCachesIt() async throws {
        let sourceDirectory = try Self.requiredModelDirectory()
        let loadCounter = ThreadSafeLocalTaggerLoadCounter()
        let harness = try Self.makeHarness(
            engine: DecisionEngineChoice.localModel.rawValue,
            secretLoadResult: .failure(.unexpectedOperation),
            loadLocalTagger: { modelDirectory in
                loadCounter.recordLoad()
                return try LocalClauseTagger(modelDirectory: modelDirectory)
            }
        )
        defer { harness.cleanUp() }

        let fileManager = FileManager.default
        let modelDirectory = LocalClauseTagger.modelDirectory(paths: harness.paths)
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

        guard case .available(let coordinator) = try harness.factory.makeCoordinator() else {
            Issue.record("The selected trained local model was not available from the test-owned copy.")
            return
        }
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
            segmentationRunID: "selected-provider-fixture-run",
            segmentID: "fixture-segment-1",
            asrRunID: "selected-provider-fixture-asr",
            asrEventSeq: 1
        )
        let nextSource = try SegmentTextReference(
            segmentationRunID: "selected-provider-fixture-run",
            segmentID: "fixture-segment-2",
            asrRunID: "selected-provider-fixture-asr",
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
            #expect(response.metadata == record.metadata)
        case .failed(_, let message):
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
            #expect(response.metadata == record.metadata)
        case .failed(_, let message):
            Issue.record("The trained local priority request failed: \(message)")
            return
        case .cancelled:
            Issue.record("The trained local priority request was unexpectedly cancelled.")
            return
        }

        for record in [boundaryRecord, priorityRecord] {
            #expect(record.metadata.provider == .localModel)
            #expect(record.metadata.model == fixture.modelID)
            #expect(record.metadata.modelRevision == fixture.modelRevision)
            #expect(record.requestID.hasPrefix("decisionreq_"))
        }
        let boundaryTokens = try #require(boundaryRecord.metadata.inputTokens)
        let priorityTokens = try #require(priorityRecord.metadata.inputTokens)
        let usage = await harness.usageCounter.snapshot()
        #expect(usage.sendCount == 2)
        #expect(usage.successCount == 2)
        #expect(usage.failureCount == 0)
        #expect(usage.unreportedTokenSuccessCount == 0)
        #expect(usage.reportedInputTokens == boundaryTokens + priorityTokens)
        #expect(usage.boundaryRequests.sendCount == 1)
        #expect(usage.boundaryRequests.successCount == 1)
        #expect(usage.boundaryRequests.reportedInputTokens == boundaryTokens)
        #expect(usage.boundaryRequests.unreportedTokenSuccessCount == 0)
        #expect(usage.priorityRequests.sendCount == 1)
        #expect(usage.priorityRequests.successCount == 1)
        #expect(usage.priorityRequests.reportedInputTokens == priorityTokens)
        #expect(usage.priorityRequests.unreportedTokenSuccessCount == 0)
        #expect(harness.secretStore.loadCount == 0)

        try fileManager.removeItem(at: copiedTokenizer)
        #expect(!fileManager.fileExists(atPath: copiedTokenizer.path))
        guard case .available(let cachedCoordinator) = try harness.factory.makeCoordinator() else {
            Issue.record("The cached trained local model was unavailable after removing its copied tokenizer.")
            return
        }
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
        #expect(harness.secretStore.loadCount == 0)
        #expect(loadCounter.loadCount == 1)
    }

    private static func makeHarness(
        engine: String? = nil,
        paused: Bool = false,
        secretLoadResult: Result<String?, SecretStoreMockError> = .success(nil),
        loadLocalTagger: @escaping @Sendable (URL) throws -> LocalClauseTagger = {
            try LocalClauseTagger(modelDirectory: $0)
        }
    ) throws -> FactoryTestHarness {
        let suiteName = "SelectedDecisionProviderFactoryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FactoryTestSetupError.unavailableDefaultsSuite
        }
        if let engine {
            defaults.set(engine, forKey: DecisionEnginePreference.key)
        }
        defaults.set(paused, forKey: DecisionEnginePreference.pauseKey)

        let temporaryRoot = FileManager.default.temporaryDirectory.appending(
            path: "mac-ambient-jev-selected-provider-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        ).standardizedFileURL
        guard FactoryTestHarness.isTestCreatedTemporaryRoot(temporaryRoot) else {
            throw FactoryTestSetupError.unsafeCopyLocation
        }
        let paths = AppPaths(
            applicationSupportURL: temporaryRoot,
            cacheURL: temporaryRoot.appending(path: "cache", directoryHint: .isDirectory),
            sessionsRootOverride: temporaryRoot.appending(path: "sessions", directoryHint: .isDirectory)
        )
        let secretStore = ThreadSafeMockSecretStore(loadResult: secretLoadResult)
        let usageCounter = DecisionUsageCounter()
        let factory = SelectedDecisionProviderFactory(
            paths: paths,
            defaults: defaults,
            secretStore: secretStore,
            usageCounter: usageCounter,
            loadLocalTagger: loadLocalTagger
        )
        return FactoryTestHarness(
            temporaryRoot: temporaryRoot,
            defaultsSuiteName: suiteName,
            paths: paths,
            defaults: defaults,
            secretStore: secretStore,
            usageCounter: usageCounter,
            factory: factory
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

    private static func expectMetadataDecodeFailure(_ json: String) {
        do {
            _ = try JSONDecoder().decode(DecisionResponseMetadata.self, from: Data(json.utf8))
            Issue.record("Invalid DecisionResponseMetadata unexpectedly decoded: \(json)")
        } catch {
            // Every malformed identity and negative token count must fail decoding.
        }
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
        #expect(provenance.engine == "local-coreml")
        #expect(provenance.model == modelID)
        #expect(provenance.version == revision)
        #expect(provenance.configuration["provider"] == "local-coreml")
        #expect(provenance.configuration["model_id"] == modelID)
        #expect(provenance.configuration["model_revision"] == revision)
        #expect(provenance.configuration["unit_policy"] == "btsj-utterance-sentence")
        #expect(provenance.configuration["endpoint"] == nil)
    }
}
