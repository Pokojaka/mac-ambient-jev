import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

struct PortableClauseTaggerInspectionTests {
    @Test func verifiesTinyNonONNXAssetsWithoutOpeningAnONNXSession() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }

        let identity = try PortableClauseTaggerInspection.validateAssets(
            modelDirectory: fixture.root,
            manifest: fixture.manifest
        )

        #expect(identity == (try fixture.manifest.identity()))
        #expect(identity.backend == "onnx-clause-tagger")
    }

    @Test func missingDirectoryUsesPortableMissingError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let missing = fixture.root.appendingPathComponent("not-installed", isDirectory: true)

        let error = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: missing, manifest: fixture.manifest)
        })
        guard case let .missing(model, path, installCommand) = error else {
            Issue.record("expected missing, got \(error)")
            return
        }
        #expect(model == .clauseTagger)
        #expect(path == missing.path)
        #expect(installCommand.contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func publicValidationLoadsBundledManifestAndReportsMissingDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableClauseTaggerInspection-missing-\(UUID().uuidString)", isDirectory: true)

        let error = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: missing)
        })
        guard case let .missing(model, path, command) = error else {
            Issue.record("expected missing, got \(error)")
            return
        }
        #expect(model == .clauseTagger)
        #expect(path == missing.path)
        #expect(command.contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func sameSizeHashMismatchIsPortableInvalidWithSHA256Detail() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let original = try #require(fixture.payloads["ClauseTagger.onnx"])
        try Data(original.map { $0 ^ 0xFF }).write(to: fixture.root.appendingPathComponent("ClauseTagger.onnx"))

        let error = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: fixture.root, manifest: fixture.manifest)
        })
        guard case let .invalid(model, path, detail, command) = error else {
            Issue.record("expected invalid, got \(error)")
            return
        }
        #expect(model == .clauseTagger)
        #expect(path.hasSuffix("ClauseTagger.onnx"))
        #expect(detail.contains("SHA-256"))
        #expect(command.contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func wrongSizeAndMissingMemberAreReportedAsPortableErrors() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        try Data("wrong size".utf8).write(to: fixture.root.appendingPathComponent("tokenizer.json"))

        let sizeError = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: fixture.root, manifest: fixture.manifest)
        })
        guard case let .invalid(_, path, detail, _) = sizeError else {
            Issue.record("expected invalid size, got \(sizeError)")
            return
        }
        #expect(path.hasSuffix("tokenizer.json"))
        #expect(detail.contains("サイズ"))

        try Data(fixture.payloads["tokenizer.json"]!).write(to: fixture.root.appendingPathComponent("tokenizer.json"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("export.json"))
        let missingError = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: fixture.root, manifest: fixture.manifest)
        })
        guard case let .missing(model, path, _) = missingError else {
            Issue.record("expected missing member, got \(missingError)")
            return
        }
        #expect(model == .clauseTagger)
        #expect(path.hasSuffix("export.json"))
    }

    @Test func invalidManifestAndNonFileDirectoryArePortableInvalid() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let badManifest = ClauseTaggerManifest(
            schemaVersion: 2,
            release: fixture.manifest.release,
            model: fixture.manifest.model,
            onnx: fixture.manifest.onnx,
            members: fixture.manifest.members
        )

        let manifestError = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: fixture.root, manifest: badManifest)
        })
        guard case let .invalid(_, _, detail, _) = manifestError else {
            Issue.record("expected invalid manifest, got \(manifestError)")
            return
        }
        #expect(!detail.isEmpty)

        let regularFile = fixture.root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: regularFile)
        let directoryError = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: regularFile, manifest: fixture.manifest)
        })
        guard case let .invalid(model, path, _, _) = directoryError else {
            Issue.record("expected invalid directory, got \(directoryError)")
            return
        }
        #expect(model == .clauseTagger)
        #expect(path == regularFile.path)

        let relative = try #require(URL(string: "relative/models"))
        let relativeError = try #require(preparationFailure {
            try PortableClauseTaggerInspection.validateAssets(modelDirectory: relative, manifest: fixture.manifest)
        })
        guard case let .invalid(relativeModel, relativePath, _, _) = relativeError else {
            Issue.record("expected invalid relative URL, got \(relativeError)")
            return
        }
        #expect(relativeModel == .clauseTagger)
        #expect(relativePath == relative.path)
    }

    @Test func concurrentCallersShareOneFlightButLaterCallsRevalidate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let identity = try fixture.manifest.identity()
        let gate = AsyncGate()
        let validations = ValidationCounter()
        let joins = JoinRecorder()
        let validator = FixtureValidator(root: fixture.root, manifest: fixture.manifest)
        let inspection = PortableClauseTaggerInspection(validate: {
            try await validations.run(gate: gate) { try validator.validate() }
        })
        let callerCount = 6
        let callers = (0..<callerCount).map { _ in
            Task { try await inspection.inspect(onJoined: { joins.record() }) }
        }

        await joins.waitUntilCount(callerCount)
        await gate.waitUntilStarted()
        await gate.release()
        var identities: [ClauseTaggerModelIdentity] = []
        for caller in callers { identities.append(try await caller.value) }

        #expect(identities == Array(repeating: identity, count: callerCount))
        #expect(await validations.count() == 1)
        #expect(joins.currentCount() == callerCount)

        #expect(try await inspection.inspect() == identity)
        #expect(await validations.count() == 2)
    }

    @Test func joinRecorderWaitReturnsWhenTargetWasAlreadyRecorded() async {
        let joins = JoinRecorder()
        joins.record()

        await joins.waitUntilCount(1)

        #expect(joins.currentCount() == 1)
    }

    @Test func sharedFailureIsClearedAndTheNextInspectionRetries() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let identity = try fixture.manifest.identity()
        let gate = AsyncGate()
        let validation = RetryValidation(gate: gate, identity: identity)
        let joins = JoinRecorder()
        let inspection = PortableClauseTaggerInspection(validate: { try await validation.run() })
        let first = Task { try await inspection.inspect(onJoined: { joins.record() }) }
        let second = Task { try await inspection.inspect(onJoined: { joins.record() }) }

        await joins.waitUntilCount(2)
        await gate.waitUntilStarted()
        await gate.release()
        await #expect(throws: InspectionTestFailure.self) { _ = try await first.value }
        await #expect(throws: InspectionTestFailure.self) { _ = try await second.value }
        #expect(await validation.count() == 1)

        #expect(try await inspection.inspect() == identity)
        #expect(await validation.count() == 2)
    }

    @Test func changedAssetsAreRevalidatedInsteadOfReturningStaleSuccess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let validator = FixtureValidator(root: fixture.root, manifest: fixture.manifest)
        let inspection = PortableClauseTaggerInspection(validate: { try validator.validate() })

        #expect(try await inspection.inspect() == (try fixture.manifest.identity()))
        let original = try #require(fixture.payloads["ClauseTagger.onnx"])
        try Data(original.map { $0 ^ 0xFF }).write(to: fixture.root.appendingPathComponent("ClauseTagger.onnx"))

        await #expect(throws: PortableModelPreparationError.self) { try await inspection.inspect() }
    }

    @Test func injectedCancellationErrorPropagates() async throws {
        let inspection = PortableClauseTaggerInspection(validate: { throw CancellationError() })

        await #expect(throws: CancellationError.self) { try await inspection.inspect() }
    }

    @Test func preCancelledCallerDoesNotStartValidation() async throws {
        let validations = ValidationCounter()
        let inspection = PortableClauseTaggerInspection(validate: {
            await validations.increment()
            throw InspectionTestFailure.failed
        })
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await inspection.inspect()
        }

        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        #expect(await validations.count() == 0)
    }

    @Test func cancelledJoinedWaiterDoesNotCancelSharedValidation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let identity = try fixture.manifest.identity()
        let gate = AsyncGate()
        let validations = ValidationCounter()
        let joins = JoinRecorder()
        let validator = FixtureValidator(root: fixture.root, manifest: fixture.manifest)
        let inspection = PortableClauseTaggerInspection(validate: {
            try await validations.run(gate: gate) { try validator.validate() }
        })
        let surviving = Task { try await inspection.inspect(onJoined: { joins.record() }) }
        await gate.waitUntilStarted()
        let cancelled = Task { try await inspection.inspect(onJoined: { joins.record() }) }
        await joins.waitUntilCount(2)
        cancelled.cancel()
        await gate.release()

        #expect(try await surviving.value == identity)
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(await validations.count() == 1)
    }

    private func preparationFailure(
        _ body: () throws -> ClauseTaggerModelIdentity
    ) -> PortableModelPreparationError? {
        do {
            _ = try body()
            return nil
        } catch let error as PortableModelPreparationError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    private struct Fixture {
        let root: URL
        let manifest: ClauseTaggerManifest
        let payloads: [String: Data]
    }

    private func makeFixture() throws -> Fixture {
        let bundled = try ClauseTaggerManifest.bundled()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortableClauseTaggerInspectionTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("clause-tagger-onnx", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var members: [ClauseTaggerManifest.Member] = []
        var payloads: [String: Data] = [:]
        for member in bundled.members {
            let payload = Data("invalid test payload for \(member.name)".utf8)
            try payload.write(to: root.appendingPathComponent(member.name))
            payloads[member.name] = payload
            members.append(.init(
                role: member.role,
                name: member.name,
                byteCount: payload.count,
                sha256: FileSHA256.hexDigest(of: payload)
            ))
        }
        let tokenizerHash = try #require(members.first(where: { $0.role == .tokenizer })?.sha256)
        let model = ClauseTaggerManifest.Model(
            id: bundled.model.id,
            revision: bundled.model.revision,
            tokenizerSHA256: tokenizerHash,
            encodingRevision: bundled.model.encodingRevision,
            unitPolicy: bundled.model.unitPolicy,
            trainingStatus: bundled.model.trainingStatus
        )
        let manifest = ClauseTaggerManifest(
            schemaVersion: bundled.schemaVersion,
            release: bundled.release,
            model: model,
            onnx: bundled.onnx,
            members: members
        )
        let manifestURL = parent.appendingPathComponent("clause_tagger_model.json")
        let manifestData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": manifest.schemaVersion,
            "release": [
                "repository": manifest.release.repository,
                "tag": manifest.release.tag,
                "asset": manifest.release.asset,
                "byteCount": manifest.release.byteCount,
                "sha256": manifest.release.sha256,
                "directory": manifest.release.directory,
            ],
            "model": [
                "id": manifest.model.id,
                "revision": manifest.model.revision,
                "tokenizerSHA256": manifest.model.tokenizerSHA256,
                "encodingRevision": manifest.model.encodingRevision,
                "unitPolicy": manifest.model.unitPolicy,
                "trainingStatus": manifest.model.trainingStatus,
            ],
            "onnx": [
                "opset": manifest.onnx.opset,
                "minimumSequenceLength": manifest.onnx.minimumSequenceLength,
                "maximumSequenceLength": manifest.onnx.maximumSequenceLength,
                "inputs": manifest.onnx.inputs.map { tensor in
                    [
                        "name": tensor.name,
                        "dtype": tensor.dtype,
                        "shape": tensor.shape.map { dimension in
                            switch dimension {
                            case let .fixed(value): value as Any
                            case let .symbolic(value): value as Any
                            }
                        },
                    ]
                },
                "outputs": manifest.onnx.outputs.map { tensor in
                    [
                        "name": tensor.name,
                        "dtype": tensor.dtype,
                        "shape": tensor.shape.map { dimension in
                            switch dimension {
                            case let .fixed(value): value as Any
                            case let .symbolic(value): value as Any
                            }
                        },
                    ]
                },
            ],
            "members": manifest.members.map { member in
                [
                    "role": member.role.rawValue,
                    "name": member.name,
                    "byteCount": member.byteCount,
                    "sha256": member.sha256,
                ]
            },
        ], options: [.sortedKeys])
        try manifestData.write(to: manifestURL)
        let parsedManifest = try ClauseTaggerManifest.parse(Data(contentsOf: manifestURL))
        return Fixture(root: root, manifest: parsedManifest, payloads: payloads)
    }
}

private final class FixtureValidator: @unchecked Sendable {
    private let root: URL
    private let manifest: ClauseTaggerManifest

    init(root: URL, manifest: ClauseTaggerManifest) {
        self.root = root
        self.manifest = manifest
    }

    func validate() throws -> ClauseTaggerModelIdentity {
        try PortableClauseTaggerInspection.validateAssets(modelDirectory: root, manifest: manifest)
    }
}

private enum InspectionTestFailure: Error {
    case failed
}

private actor AsyncGate {
    private var isOpen = false
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { blocked.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isOpen = true
        let waiters = blocked
        blocked.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ValidationCounter {
    private var validations = 0

    func run(
        gate: AsyncGate,
        validate: @Sendable () throws -> ClauseTaggerModelIdentity
    ) async throws -> ClauseTaggerModelIdentity {
        validations += 1
        await gate.wait()
        return try validate()
    }

    func increment() {
        validations += 1
    }

    func count() -> Int { validations }
}

private actor RetryValidation {
    private let gate: AsyncGate
    private let identity: ClauseTaggerModelIdentity
    private var attempts = 0

    init(gate: AsyncGate, identity: ClauseTaggerModelIdentity) {
        self.gate = gate
        self.identity = identity
    }

    func run() async throws -> ClauseTaggerModelIdentity {
        attempts += 1
        if attempts == 1 {
            await gate.wait()
            throw InspectionTestFailure.failed
        }
        return identity
    }

    func count() -> Int { attempts }
}

private final class JoinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record() {
        lock.lock()
        count += 1
        let ready = waiters.filter { count >= $0.0 }
        waiters.removeAll { count >= $0.0 }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }

    func waitUntilCount(_ target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if count >= target {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((target, continuation))
                lock.unlock()
            }
        }
    }

    func currentCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
