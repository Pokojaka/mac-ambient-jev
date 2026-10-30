import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevPortableRuntime

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PortableModelPreparationProgress] = []
    private var events: [String] = []

    func progress(_ value: PortableModelPreparationProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        events.append("progress")
    }

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    var snapshot: (progress: [PortableModelPreparationProgress], events: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (values, events)
    }
}

private struct FakeFailure: Error, LocalizedError {
    var errorDescription: String? { "fake failure" }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PortableModelPreparationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func asset(_ name: String, _ contents: String, in directory: URL, byteCount: Bool = true) throws -> PortableAssetFile {
    let data = Data(contents.utf8)
    try data.write(to: directory.appending(path: name))
    return PortableAssetFile(
        name: name,
        byteCount: byteCount ? Int64(data.count) : nil,
        sha256: FileSHA256.hexDigest(of: data)
    )
}

struct PortableModelPreparationTests {
    @Test func verifierAcceptsMatchingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [try asset("a.bin", "alpha", in: directory), try asset("b.bin", "beta", in: directory, byteCount: false)]
        try PortableAssetVerifier.verify(model: .asr, files: files, directory: directory, installCommand: "fetch")
    }

    @Test func verifierReportsAMissingDirectoryByItsExactPath() throws {
        let directory = try temporaryDirectory().appending(path: "absent")
        #expect(throws: PortableModelPreparationError.missing(model: .diarization, path: directory.path, installCommand: "fetch it")) {
            try PortableAssetVerifier.verify(
                model: .diarization,
                files: [PortableAssetFile(name: "x", byteCount: nil, sha256: "00")],
                directory: directory,
                installCommand: "fetch it"
            )
        }
    }

    @Test func verifierReportsAMissingFileByItsExactPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let present = try asset("a.bin", "alpha", in: directory)
        let absent = PortableAssetFile(name: "b.bin", byteCount: 1, sha256: "00")
        let expected = PortableModelPreparationError.missing(
            model: .asr, path: directory.appending(path: "b.bin").path, installCommand: "fetch it"
        )
        #expect(throws: expected) {
            try PortableAssetVerifier.verify(model: .asr, files: [present, absent], directory: directory, installCommand: "fetch it")
        }
        #expect(expected.errorDescription?.contains("fetch it") == true)
    }

    @Test func verifierRejectsWrongSizeCorruptBytesAndNonRegularFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try asset("a.bin", "alpha", in: directory)

        let wrongSize = PortableAssetFile(name: good.name, byteCount: good.byteCount! + 1, sha256: good.sha256)
        let corrupt = PortableAssetFile(name: good.name, byteCount: good.byteCount, sha256: String(repeating: "0", count: 64))
        try FileManager.default.createDirectory(at: directory.appending(path: "dir.bin"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "link.bin"), withDestinationURL: directory.appending(path: "a.bin")
        )
        let notRegular = [
            PortableAssetFile(name: "dir.bin", byteCount: nil, sha256: good.sha256),
            PortableAssetFile(name: "link.bin", byteCount: nil, sha256: good.sha256),
        ]

        for (file, fragment) in [(wrongSize, "サイズ"), (corrupt, "SHA-256")] + notRegular.map({ ($0, "通常ファイル") }) {
            do {
                try PortableAssetVerifier.verify(model: .vad, files: [file], directory: directory, installCommand: "fetch")
                Issue.record("accepted \(file.name)")
            } catch let error as PortableModelPreparationError {
                guard case let .invalid(model, path, detail, command) = error else {
                    Issue.record("not invalid: \(error)"); continue
                }
                #expect(model == .vad)
                #expect(path == directory.appending(path: file.name).path)
                #expect(detail.contains(fragment))
                #expect(command == "fetch")
            }
        }
    }

    @Test func everyModelIsValidatedBeforeAnyIsLoadedAndProgressIsReported() async throws {
        let log = ProgressLog()
        let steps = PortableModelKind.allCases.map { model in
            PortableModelPreparationService.Step(
                model: model,
                validate: { log.record("validate \(model.rawValue)") },
                load: { log.record("load \(model.rawValue)") }
            )
        }
        try await PortableModelPreparationService.run(steps: steps, onProgress: { log.progress($0) })

        let snapshot = log.snapshot
        let kinds = PortableModelKind.allCases
        let domain = snapshot.events.filter { $0 != "progress" }
        #expect(domain == kinds.map { "validate \($0.rawValue)" } + kinds.map { "load \($0.rawValue)" })

        var expected: [PortableModelPreparationProgress] = []
        for stage in [PortableModelPreparationStage.validating, .loading] {
            for (index, model) in kinds.enumerated() {
                expected.append(.init(stage: stage, model: model, completed: index, total: kinds.count))
            }
            expected.append(.init(stage: stage, model: nil, completed: kinds.count, total: kinds.count))
        }
        #expect(snapshot.progress == expected)
    }

    @Test func aValidationFailureLoadsNothingAndStopsTheRun() async throws {
        let log = ProgressLog()
        let failure = PortableModelPreparationError.missing(model: .asr, path: "/p", installCommand: "c")
        let steps = [
            PortableModelPreparationService.Step(model: .vad, validate: {}, load: { log.record("load vad") }),
            PortableModelPreparationService.Step(model: .asr, validate: { throw failure }, load: { log.record("load asr") }),
            PortableModelPreparationService.Step(model: .diarization, validate: { log.record("validate diarization") }, load: {}),
        ]
        await #expect(throws: failure) {
            try await PortableModelPreparationService.run(steps: steps, onProgress: { log.progress($0) })
        }
        #expect(!log.snapshot.events.contains("load vad"))
        #expect(!log.snapshot.events.contains("validate diarization"))
    }

    @Test func aLoadFailurePropagatesAndSkipsLaterModels() async throws {
        let log = ProgressLog()
        let steps = [
            PortableModelPreparationService.Step(model: .vad, validate: {}, load: { throw FakeFailure() }),
            PortableModelPreparationService.Step(model: .asr, validate: {}, load: { log.record("load asr") }),
        ]
        await #expect(throws: FakeFailure.self) {
            try await PortableModelPreparationService.run(steps: steps, onProgress: { _ in })
        }
        #expect(log.snapshot.events.isEmpty)
    }

    @Test func installedLayoutFollowsThePinnedIdentities() throws {
        let root = URL(fileURLWithPath: "/models", isDirectory: true)
        let layout = PortableInstalledModelLayout(modelsRoot: root)
        #expect(layout.sileroModelURL.path == "/models/silero/\(SileroVADModel.revision)/silero_vad_16k_op15.onnx")
        for size in ASRModelSize.allCases {
            #expect(layout.qwen3Directory(size: size).path == "/models/qwen3-asr-\(size.rawValue)-int4-\(size.commit)")
        }
        let diarization = try layout.diarizationDirectory()
        #expect(diarization.deletingLastPathComponent().path == "/models/community1")
        #expect(diarization.lastPathComponent.count == 64)
        let source = try ClauseTaggerManifest.bundled().source
        #expect(source.commit == "5c0213592cf8d59fc0b665183ab7536ddde05d1f")
        #expect(try layout.clauseTaggerDirectory().path == "/models/clause-tagger/\(source.commit)/clause-tagger-onnx")
    }

    @Test func installedConfigurationSharesThreadValidationAndDecisionSelection() throws {
        let layout = PortableInstalledModelLayout(modelsRoot: URL(fileURLWithPath: "/models", isDirectory: true))
        let withDecisions = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .large, threads: 2, logicalCPUCount: 8, withDecisions: true
        )
        #expect(withDecisions.clauseTaggerModelDirectory == (try layout.clauseTaggerDirectory()))
        #expect(withDecisions.qwen3Size == .large)
        #expect(withDecisions.threads == 2)
        #expect(try PortableModelPreparationService.steps(for: withDecisions).map(\.model) == PortableModelKind.allCases)

        let without = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 8, withDecisions: false
        )
        #expect(without.clauseTaggerModelDirectory == nil)
        #expect(try PortableModelPreparationService.steps(for: without).map(\.model) == [.vad, .asr, .diarization])

        for threads in [0, 5] {
            #expect(throws: PortableProcessingConfigurationError.self) {
                try PortableProcessingConfiguration.installed(
                    layout: layout, qwen3Size: .small, threads: threads, logicalCPUCount: 8, withDecisions: false
                )
            }
        }
        #expect(throws: PortableProcessingConfigurationError.self) {
            try PortableProcessingConfiguration.installed(
                layout: layout, qwen3Size: .small, threads: 3, logicalCPUCount: 2, withDecisions: false
            )
        }
    }

    @Test func missingClauseTaggerPreparationStepReportsItsInstallCommand() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tagger = root.appending(path: "clause-tagger", directoryHint: .isDirectory)
        let configuration = PortableProcessingConfiguration(
            sileroModelURL: root.appending(path: "silero/model.onnx"),
            qwen3ModelDirectory: root.appending(path: "qwen3", directoryHint: .isDirectory),
            qwen3Size: .small,
            diarizationModelDirectory: root.appending(path: "diarization", directoryHint: .isDirectory),
            clauseTaggerModelDirectory: tagger,
            threads: 1
        )
        let steps = try PortableModelPreparationService.steps(for: configuration)
        let step = try #require(steps.first { $0.model == .clauseTagger })

        do {
            try step.validate()
            Issue.record("validated a missing clause tagger")
        } catch let error as PortableModelPreparationError {
            guard case let .missing(model, path, command) = error else {
                Issue.record("not missing: \(error)")
                return
            }
            #expect(model == .clauseTagger)
            #expect(path == tagger.path)
            #expect(command.contains("--format onnx"))
            #expect(command.contains(tagger.path))
        }
    }

    @Test func prepareOnAnEmptyModelsDirectoryFailsWithTheExpectedPathAndCreatesNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(modelsRoot: root)
        let configuration = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 4, withDecisions: true
        )
        do {
            try await PortableModelPreparationService().prepare(configuration: configuration, onProgress: { _ in })
            Issue.record("prepared without models")
        } catch let error as PortableModelPreparationError {
            guard case let .missing(model, path, command) = error else { Issue.record("not missing: \(error)"); return }
            #expect(model == .vad)
            #expect(path == layout.sileroModelURL.deletingLastPathComponent().path)
            #expect(command.contains("scripts/fetch_silero_vad.py"))
            #expect(command.contains(layout.sileroModelURL.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aCorruptSileroFileFailsPreparationWithItsPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(modelsRoot: root)
        try FileManager.default.createDirectory(
            at: layout.sileroModelURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a model".utf8).write(to: layout.sileroModelURL)
        let configuration = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 4, withDecisions: false
        )
        do {
            try await PortableModelPreparationService().prepare(configuration: configuration, onProgress: { _ in })
            Issue.record("prepared with a corrupt model")
        } catch let error as PortableModelPreparationError {
            guard case let .invalid(model, path, detail, _) = error else { Issue.record("not invalid: \(error)"); return }
            #expect(model == .vad)
            #expect(path == layout.sileroModelURL.path)
            #expect(detail.contains("SHA-256"))
        }
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1",
            "Set RUN_MODEL_TESTS=1 and the portable model environment variables to load the real models."
        )
    )
    func preparesTheRealModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = try PortableProcessingConfiguration.resolve(
            environment: environment,
            threads: 2,
            logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount,
            withDecisions: environment[PortableProcessingConfiguration.clauseTaggerDirectoryKey] != nil
        )
        let log = ProgressLog()
        try await PortableModelPreparationService().prepare(configuration: configuration, onProgress: { log.progress($0) })
        let progress = log.snapshot.progress
        let models = configuration.clauseTaggerModelDirectory == nil ? 3 : 4
        #expect(progress.count == 2 * (models + 1))
        #expect(progress.last == .init(stage: .loading, model: nil, completed: models, total: models))
    }
}
