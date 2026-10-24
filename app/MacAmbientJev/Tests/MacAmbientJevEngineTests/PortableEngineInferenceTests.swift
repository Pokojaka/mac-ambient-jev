import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
@testable import MacAmbientJevPortableRuntime
@testable import MacAmbientJevEngine

private struct InspectionFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? { "injected inspection failure" }
}

private actor InspectionStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite struct PortableEngineInferenceTests {
    private func temporaryModelsRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "portable-engine-inference-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func inference(modelsRoot: URL) -> PortableEngineInference {
        PortableEngineInference(
            layout: PortableInstalledModelLayout(modelsRoot: modelsRoot),
            logicalCPUCount: 1
        )
    }

    private func inference(
        modelsRoot: URL,
        clauseTaggerInspection: PortableClauseTaggerInspection
    ) -> PortableEngineInference {
        PortableEngineInference(
            layout: PortableInstalledModelLayout(modelsRoot: modelsRoot),
            logicalCPUCount: 1,
            clauseTaggerInspection: clauseTaggerInspection
        )
    }

    private func settings() throws -> EngineSettings {
        try EngineSettings(
            schemaVersion: 1,
            source: .microphone,
            device: .default,
            asrSize: .small,
            executionProvider: .cpu,
            threads: 1,
            lowHeat: false,
            decisionsEnabled: true,
            automaticExport: false,
            exportDestinationPath: nil
        )
    }

    @Test func missingClauseTaggerIsReportedAsModelMissing() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }

        do {
            _ = try await inference(modelsRoot: modelsRoot).inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded without installed assets")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelMissing)
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: modelsRoot.path))
    }

    @Test func malformedClauseTaggerIsReportedAsModelCorrupt() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }
        let layout = PortableInstalledModelLayout(modelsRoot: modelsRoot)
        let taggerDirectory = try layout.clauseTaggerDirectory()
        try FileManager.default.createDirectory(at: taggerDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: taggerDirectory.appending(path: "ClauseTagger.onnx"), options: [])

        do {
            _ = try await inference(modelsRoot: modelsRoot).inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded with a malformed asset")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelCorrupt)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == "clause_tagger")
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
    }

    @Test func tinyInvalidOnnxAndTokenizerAssetsReturnIdentityWithoutChangingUsage() async throws {
        let fixture = try makeTinyClauseTaggerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inference = inference(fixture: fixture)
        let before = try await inference.decisionUsage()

        let identity = try await inference.inspectClauseTagger()
        let after = try await inference.decisionUsage()

        #expect(identity == (try fixture.manifest.identity()))
        #expect(before == after)
        #expect(after.sendCount == 0)
        #expect(after.inputTokens == 0)
    }

    @Test func tinyFixtureDirectoryRemovalMapsThroughAdapterToModelMissing() async throws {
        let fixture = try makeTinyClauseTaggerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inference = inference(fixture: fixture)
        try FileManager.default.removeItem(at: fixture.modelDirectory)

        do {
            _ = try await inference.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded without the fixture directory")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelMissing)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == "clause_tagger")
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
    }

    @Test func sameSizeTinyFixtureModelMutationMapsThroughAdapterToModelCorrupt() async throws {
        let fixture = try makeTinyClauseTaggerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inference = inference(fixture: fixture)
        let modelURL = fixture.modelDirectory.appending(path: "ClauseTagger.onnx")
        let modifiedModel = Data(fixture.modelPayload.map { $0 ^ 0xFF })
        try modifiedModel.write(to: modelURL)
        #expect(modifiedModel.count == fixture.modelPayload.count)

        do {
            _ = try await inference.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded with a hash-mismatched fixture")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelCorrupt)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.message.contains("SHA-256"))
            #expect(error.message.contains("一致しません"))
            #expect(error.details.count == 1)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == "clause_tagger")
            #expect(error.details.first?.message == error.localizedDescription)
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
    }

    @Test func modelErrorMappingMatchesSequence38CorpusFailure() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let corpusURL = sourceDirectory
            .appending(path: "MacAmbientJevEngineProtocolTests", directoryHint: .isDirectory)
            .appending(path: "Fixtures", directoryHint: .isDirectory)
            .appending(path: "wire-v1.ndjson")
        let lines = try String(contentsOf: corpusURL, encoding: .utf8).split(whereSeparator: \.isNewline)
        let record = try #require(lines.first { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return false
            }
            return object["sequence"] as? String == "38"
        })
        let output = try EngineCodec.decodeOutput(Data(record.utf8))
        #expect(output.sequence.value == 38)
        let modelsInspection: EngineModelsInspection
        guard case let .completed(.modelsInspect(inspection)) = output.event else {
            Issue.record("sequence 38 is not a completed models.inspect event")
            return
        }
        modelsInspection = inspection
        let corpusFailure: EngineFailure
        guard case let .invalid(failure) = modelsInspection.clauseTagger else {
            Issue.record("sequence 38 does not contain an invalid clause tagger result")
            return
        }
        corpusFailure = failure

        let modelDirectory = "C:/Users/Aki/AppData/Local/mac-ambient-jev/models/clause-tagger/clause-tagger-onnx-90501ea3-v1/clause-tagger-onnx"
        let preparationError = PortableModelPreparationError.invalid(
            model: .clauseTagger,
            path: "\(modelDirectory)/ClauseTagger.onnx",
            detail: "サイズが一致しません (期待: 146889561, 実際: 1)",
            installCommand: "python3 scripts/fetch_clause_tagger.py を実行し、出力されたディレクトリの内容を \(modelDirectory) に置く"
        )
        let mappedError = PortableEngineInference.modelError(preparationError)

        #expect(mappedError.code == corpusFailure.code)
        #expect(mappedError.message == corpusFailure.message)
        #expect(mappedError.recoveryAction == corpusFailure.recoveryAction)
        #expect(mappedError.details == corpusFailure.details)
    }

    @Test func preCancelledInspectionPropagatesCancellation() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }
        let inference = inference(modelsRoot: modelsRoot)
        let gate = InspectionStartGate()
        let task = Task {
            await gate.wait()
            return try await inference.inspectClauseTagger()
        }

        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("pre-cancelled inspection unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("pre-cancelled inspection threw an unexpected error: \(error)")
        }
    }

    @Test func preparationAndInspectionMapMissingModelsConsistently() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }
        let inference = inference(modelsRoot: modelsRoot)
        let settings = try settings()

        do {
            try await inference.prepare(settings: settings) { _ in }
            Issue.record("preparation unexpectedly succeeded without installed models")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelMissing)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.details.contains { $0.domain == "models" })
        } catch {
            Issue.record("preparation threw an unexpected error: \(error)")
        }

        do {
            _ = try await inference.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded without installed assets")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelMissing)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.details.contains { $0.domain == "models" })
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: modelsRoot.path))
    }

    @Test func modelErrorMapsEveryPreparationFailureKind() {
        let preparationErrors: [(PortableModelPreparationError, EngineErrorCode)] = [
            (.missing(model: .clauseTagger, path: "/models/missing", installCommand: "install"), .modelMissing),
            (.invalid(model: .clauseTagger, path: "/models/invalid", detail: "corrupt", installCommand: "install"), .modelCorrupt),
            (.loadFailed(model: .clauseTagger, path: "/models/load", detail: "load failure"), .modelFailure)
        ]

        for (preparationError, expectedCode) in preparationErrors {
            let error = PortableEngineInference.modelError(preparationError)
            #expect(error.code == expectedCode)
            #expect(error.message == preparationError.localizedDescription)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.details.count == 1)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == preparationError.model.rawValue)
            #expect(error.details.first?.message == preparationError.localizedDescription)
        }
    }

    @Test func injectedResolverCancellationPropagatesWithoutAdapterConversion() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }
        let inspection = PortableClauseTaggerInspection(modelDirectory: { throw CancellationError() })
        let inference = inference(modelsRoot: modelsRoot, clauseTaggerInspection: inspection)

        do {
            _ = try await inference.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded")
        } catch is CancellationError {
        } catch let error as EngineAdapterError {
            Issue.record("cancellation was converted into an adapter error: \(error.code)")
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }
    }

    @Test func inspectionDoesNotChangeZeroDecisionUsage() async throws {
        let modelsRoot = temporaryModelsRoot()
        defer { try? FileManager.default.removeItem(at: modelsRoot) }
        let inspection = PortableClauseTaggerInspection(modelDirectory: { throw InspectionFailure() })
        let inference = inference(modelsRoot: modelsRoot, clauseTaggerInspection: inspection)
        let before = try await inference.decisionUsage()

        do {
            _ = try await inference.inspectClauseTagger()
            Issue.record("injected inspection unexpectedly succeeded")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelFailure)
        }

        let after = try await inference.decisionUsage()
        #expect(before == after)
        #expect(after.sendCount == 0)
        #expect(after.inputTokens == 0)
        #expect(after.successCount == 0)
        #expect(after.failureCount == 0)
        #expect(after.pendingBoundarySegmentCount == 0)
        #expect(after.pendingPriorityClauseCount == 0)
        #expect(after.boundaryRequests.sendCount == 0)
        #expect(after.boundaryRequests.inputTokens == 0)
        #expect(after.boundaryRequests.successCount == 0)
        #expect(after.boundaryRequests.failureCount == 0)
        #expect(after.priorityRequests.sendCount == 0)
        #expect(after.priorityRequests.inputTokens == 0)
        #expect(after.priorityRequests.successCount == 0)
        #expect(after.priorityRequests.failureCount == 0)
    }

    private func inference(fixture: TinyClauseTaggerFixture) -> PortableEngineInference {
        let validator = TinyFixtureValidator(modelDirectory: fixture.modelDirectory, manifest: fixture.manifest)
        let inspection = PortableClauseTaggerInspection(validate: { try validator.validate() })
        return inference(modelsRoot: fixture.root, clauseTaggerInspection: inspection)
    }

    private func makeTinyClauseTaggerFixture() throws -> TinyClauseTaggerFixture {
        let root = temporaryModelsRoot()
        let modelDirectory = root.appending(path: "tagger", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let files: [(role: String, name: String, data: Data)] = [
            ("model", "ClauseTagger.onnx", Data("not an ONNX model".utf8)),
            ("tokenizer", "tokenizer.json", Data("not a tokenizer".utf8)),
            ("export", "export.json", Data("{}".utf8)),
            ("license", "LICENSE.txt", Data("fixture license".utf8))
        ]
        for file in files {
            try file.data.write(to: modelDirectory.appending(path: file.name))
        }
        let tokenizer = try #require(files.first { $0.role == "tokenizer" })
        let manifestObject: [String: Any] = [
            "schemaVersion": 1,
            "release": [
                "repository": "test",
                "tag": "test",
                "asset": "fixture.tar.gz",
                "byteCount": 1,
                "sha256": String(repeating: "a", count: 64),
                "directory": "tagger"
            ],
            "model": [
                "id": "fixture",
                "revision": String(repeating: "b", count: 64),
                "tokenizerSHA256": FileSHA256.hexDigest(of: tokenizer.data),
                "encodingRevision": "1",
                "unitPolicy": "fixture",
                "trainingStatus": "trained"
            ],
            "onnx": [
                "opset": 18,
                "minimumSequenceLength": 2,
                "maximumSequenceLength": 192,
                "inputs": [["name": "input_ids", "dtype": "int64", "shape": [1, "sequence"]]],
                "outputs": [["name": "boundary_probs", "dtype": "float32", "shape": [1, "sequence", 2]]]
            ],
            "members": files.map { file in
                [
                    "role": file.role,
                    "name": file.name,
                    "byteCount": file.data.count,
                    "sha256": FileSHA256.hexDigest(of: file.data)
                ]
            }
        ]
        let manifestURL = root.appending(path: "clause_tagger_model.json")
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
        try manifestData.write(to: manifestURL)
        let manifest = try ClauseTaggerManifest.parse(Data(contentsOf: manifestURL))
        let modelPayload = try #require(files.first { $0.role == "model" }?.data)
        return TinyClauseTaggerFixture(
            root: root,
            modelDirectory: modelDirectory,
            manifest: manifest,
            modelPayload: modelPayload
        )
    }
}

private struct TinyClauseTaggerFixture {
    let root: URL
    let modelDirectory: URL
    let manifest: ClauseTaggerManifest
    let modelPayload: Data
}

private struct TinyFixtureValidator: @unchecked Sendable {
    let modelDirectory: URL
    let manifest: ClauseTaggerManifest

    func validate() throws -> ClauseTaggerModelIdentity {
        try PortableClauseTaggerInspection.validateAssets(modelDirectory: modelDirectory, manifest: manifest)
    }
}
