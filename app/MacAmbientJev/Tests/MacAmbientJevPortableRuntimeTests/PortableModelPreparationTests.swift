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

struct PortableModelPreparationTests {
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
        let failure = PortableModelPreparationError.missing(model: .asr, path: "/p", guidance: "c")
        let steps = [
            PortableModelPreparationService.Step(model: .vad, validate: {}, load: { log.record("load vad") }),
            PortableModelPreparationService.Step(model: .asr, validate: { throw failure }, load: { log.record("load asr") }),
            PortableModelPreparationService.Step(model: .clauseTagger, validate: { log.record("validate clause tagger") }, load: {}),
        ]
        await #expect(throws: failure) {
            try await PortableModelPreparationService.run(steps: steps, onProgress: { log.progress($0) })
        }
        #expect(!log.snapshot.events.contains("load vad"))
        #expect(!log.snapshot.events.contains("validate clause tagger"))
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
        let layout = PortableInstalledModelLayout(
            bundledRoot: URL(fileURLWithPath: "/bundled", isDirectory: true),
            downloadedRoot: URL(fileURLWithPath: "/downloaded", isDirectory: true)
        )
        #expect(layout.sileroModelURL.path == "/bundled/silero/\(SileroVADModel.revision)/silero_vad_16k_op15.onnx")
        for size in Qwen3ASRModelSize.allCases {
            #expect(layout.qwen3Directory(size: size).path == "/downloaded/qwen3-asr-\(size.rawValue)-int4-\(size.commit)")
        }
        let source = try ClauseTaggerManifest.bundled().source
        #expect(source.commit == "5c0213592cf8d59fc0b665183ab7536ddde05d1f")
        #expect(try layout.clauseTaggerDirectory().path == "/bundled/clause-tagger/\(source.commit)/clause-tagger-onnx")
    }

    @Test func installedConfigurationSharesThreadValidationAndDecisionSelection() throws {
        let layout = PortableInstalledModelLayout(
            bundledRoot: URL(fileURLWithPath: "/models", isDirectory: true),
            downloadedRoot: URL(fileURLWithPath: "/models", isDirectory: true)
        )
        let withDecisions = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .large, threads: 2, logicalCPUCount: 8, withDecisions: true
        )
        #expect(withDecisions.clauseTaggerModelDirectory == (try layout.clauseTaggerDirectory()))
        #expect(withDecisions.qwen3Size == .large)
        #expect(withDecisions.threads == 2)
        #expect(PortableModelPreparationService.steps(for: withDecisions).map(\.model) == [.vad, .asr, .clauseTagger])

        let without = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 8, withDecisions: false
        )
        #expect(without.clauseTaggerModelDirectory == nil)
        #expect(PortableModelPreparationService.steps(for: without).map(\.model) == [.vad, .asr])

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
            clauseTaggerModelDirectory: tagger,
            threads: 1,
            sileroGuidance: "s",
            clauseTaggerGuidance: "g"
        )
        let steps = PortableModelPreparationService.steps(for: configuration)
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
            #expect(path == tagger.appending(path: "ClauseTagger.onnx").path)
            #expect(command == "g")
        }
    }

    @Test func prepareOnAnEmptyModelsDirectoryFailsWithTheExpectedPathAndCreatesNothing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(bundledRoot: root, downloadedRoot: root)
        let configuration = try PortableProcessingConfiguration.installed(
            layout: layout, qwen3Size: .small, threads: 1, logicalCPUCount: 4, withDecisions: true
        )
        do {
            try await PortableModelPreparationService().prepare(configuration: configuration, onProgress: { _ in })
            Issue.record("prepared without models")
        } catch let error as PortableModelPreparationError {
            guard case let .missing(model, path, command) = error else { Issue.record("not missing: \(error)"); return }
            #expect(model == .vad)
            #expect(path == layout.sileroModelURL.path)
            #expect(command == PortableInstalledModelLayout.bundledModelGuidance)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func aCorruptSileroFileFailsPreparationWithItsPath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = PortableInstalledModelLayout(bundledRoot: root, downloadedRoot: root)
        try FileManager.default.createDirectory(
            at: layout.sileroModelURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: Int(SileroVADModel.manifestFile.byteCount)).write(to: layout.sileroModelURL)
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
        let models = configuration.clauseTaggerModelDirectory == nil ? 2 : 3
        #expect(progress.count == 2 * (models + 1))
        #expect(progress.last == .init(stage: .loading, model: nil, completed: models, total: models))
    }
}
