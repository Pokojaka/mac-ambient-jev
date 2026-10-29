import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineE2ESupport
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline
#if os(Linux) || os(Windows)
import MacAmbientJevPortableRuntime
#endif

private let harnessUsage = "Usage: MacAmbientJevEngineHarness --root <absolute-existing-directory> --fixture <absolute-file> --sample-rate <16000|44100|48000> --channels <1..8> --inference <deterministic|portable> --threads <1..min(4, logical CPU count)>"

@main
@MainActor
struct HarnessMain {
    static func main() async {
        _ = EngineLog.snapshot()
        let processExitCode = await run(arguments: Array(CommandLine.arguments.dropFirst()))
        EngineLog.close(timeout: 0.25)
        exit(processExitCode)
    }

    private static func run(arguments: [String]) async -> Int32 {
        do {
            let logicalCPUCount = ProcessInfo.processInfo.processorCount
            let options = try HarnessOptions.parse(arguments, logicalCPUCount: logicalCPUCount)
            let paths = AppPaths(
                applicationSupportURL: options.root,
                cacheURL: options.root.appending(path: "Caches", directoryHint: .isDirectory),
                sessionsRootOverride: nil
            )
            let rootLock = try ApplicationRootLock.acquire(paths: paths)
            defer { rootLock.release() }
            return try await serve(options: options, paths: paths, logicalCPUCount: logicalCPUCount)
        } catch {
            EngineLog.write(error.localizedDescription)
            return EngineExit.startupFailed("").processExitCode
        }
    }

    private static func serve(
        options: HarnessOptions,
        paths: AppPaths,
        logicalCPUCount: Int
    ) async throws -> Int32 {
        let inference: any EngineInferenceProviding
        switch options.inference {
        case .deterministic:
            inference = DeterministicInferenceProvider()
        case .portable:
            #if os(Linux) || os(Windows)
            inference = try HarnessPortableInferenceProvider(
                environment: ProcessInfo.processInfo.environment,
                threads: options.threads,
                logicalCPUCount: logicalCPUCount
            )
            #else
            throw HarnessLaunchError.usage("Portable inference is available only on Linux and Windows")
            #endif
        }

        let capture = try FileCaptureProvider(
            fixtureURL: options.fixture,
            sampleRate: options.sampleRate,
            channels: options.channels
        )
        let source = try HarnessPipeIO.makeSource()
        let sink: any EngineByteSink
        do {
            sink = try HarnessPipeIO.makeSink()
        } catch {
            source.close()
            throw error
        }

        let transport = EngineTransport(source: source, sink: sink, limits: .production)
        let resourceMonitor = HarnessResourceMonitor()
        let application = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: logicalCPUCount,
                resourceMonitor: resourceMonitor,
                memoryProber: resourceMonitor,
                sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(30)
            ),
            capture: capture,
            inference: inference,
            events: EngineEventEmitter(transport: transport)
        )
        let controller = EngineController(
            transport: transport,
            handlers: application.handlers,
            admission: .production
        )

        application.start()
        let engineExit = await controller.run()
        if case .startupFailed(let reason) = engineExit {
            do {
                try await application.handlers.shutdown.shutdown(reason: .outputFailed)
            } catch {
                EngineLog.write("startup failure shutdown failed: \(error)")
            }
            EngineLog.write("engine startup failed: \(reason)")
        } else if engineExit.processExitCode != 0 {
            EngineLog.write("engine stopped: \(engineExit)")
        }
        await application.waitForStartupRecovery()
        return engineExit.processExitCode
    }
}

private final class HarnessResourceMonitor: InferenceResourceMonitoring, InferenceMemoryProbing {
    var signal: InferenceResourceSignal { .healthy }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any InferenceResourceObservation {
        HarnessEmptyResourceObservation()
    }

    func memoryFacts() throws -> InferenceMemoryFacts {
        InferenceMemoryFacts(
            physicalMemoryBytes: UInt64(16) << 30,
            freePhysicalMemoryBytes: UInt64(8) << 30,
            commitHeadroomBytes: UInt64(8) << 30,
            lowMemorySignal: false
        )
    }
}

private final class HarnessEmptyResourceObservation: InferenceResourceObservation {}

private enum HarnessInferenceSelection: Equatable {
    case deterministic
    case portable
}

private struct HarnessOptions {
    let root: URL
    let fixture: URL
    let sampleRate: Double
    let channels: Int
    let inference: HarnessInferenceSelection
    let threads: Int

    static func parse(_ arguments: [String], logicalCPUCount: Int) throws -> HarnessOptions {
        let recognized: Set<String> = [
            "--root", "--fixture", "--sample-rate", "--channels", "--inference", "--threads"
        ]
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard recognized.contains(key) else {
                throw HarnessLaunchError.usage("Unknown argument: \(key)")
            }
            guard values[key] == nil else {
                throw HarnessLaunchError.usage("\(key) must be specified exactly once")
            }
            index += 1
            guard index < arguments.count else {
                throw HarnessLaunchError.usage("Missing value for \(key)")
            }
            values[key] = arguments[index]
            index += 1
        }
        guard values.count == recognized.count else {
            let missing = recognized.subtracting(values.keys).sorted().joined(separator: ", ")
            throw HarnessLaunchError.usage("Missing required arguments: \(missing)")
        }

        guard let rootPath = values["--root"], (rootPath as NSString).isAbsolutePath else {
            throw HarnessLaunchError.usage("--root requires an absolute existing directory")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDirectory),
              rootIsDirectory.boolValue else {
            throw HarnessLaunchError.usage("--root requires an absolute existing directory: \(rootPath)")
        }

        guard let fixturePath = values["--fixture"], (fixturePath as NSString).isAbsolutePath else {
            throw HarnessLaunchError.usage("--fixture requires an absolute existing file")
        }
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: false)
        var fixtureIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fixture.path, isDirectory: &fixtureIsDirectory),
              !fixtureIsDirectory.boolValue else {
            throw HarnessLaunchError.usage("--fixture requires an absolute existing file: \(fixturePath)")
        }

        guard let sampleRateArgument = values["--sample-rate"] else {
            throw HarnessLaunchError.usage("--sample-rate must be 16000, 44100, or 48000")
        }
        let sampleRate: Double
        switch sampleRateArgument {
        case "16000": sampleRate = 16_000
        case "44100": sampleRate = 44_100
        case "48000": sampleRate = 48_000
        default: throw HarnessLaunchError.usage("Unsupported --sample-rate: \(sampleRateArgument)")
        }

        guard let channelsArgument = values["--channels"],
              let channels = Int(channelsArgument), (1...8).contains(channels) else {
            throw HarnessLaunchError.usage("--channels must be an integer from 1 through 8")
        }

        guard let inferenceArgument = values["--inference"] else {
            throw HarnessLaunchError.usage("--inference must be deterministic or portable")
        }
        let inference: HarnessInferenceSelection
        switch inferenceArgument {
        case "deterministic": inference = .deterministic
        case "portable": inference = .portable
        default: throw HarnessLaunchError.usage("Unsupported --inference: \(inferenceArgument)")
        }

        guard let threadsArgument = values["--threads"], let threads = Int(threadsArgument) else {
            throw HarnessLaunchError.usage("--threads must be an integer from 1 through min(4, logical CPU count)")
        }
        if inference == .deterministic {
            let upperBound = min(4, logicalCPUCount)
            guard threads >= 1, threads <= upperBound else {
                throw HarnessLaunchError.usage("--threads must be from 1 through \(upperBound) (specified: \(threads))")
            }
        }
        return HarnessOptions(
            root: root,
            fixture: fixture,
            sampleRate: sampleRate,
            channels: channels,
            inference: inference,
            threads: threads
        )
    }
}

#if os(Linux) || os(Windows)
struct HarnessPortableInferenceProvider: EngineInferenceProviding {
    let configuration: PortableProcessingConfiguration
    let threads: Int
    let clauseTaggerInspection: PortableClauseTaggerInspection
    let usageCounter = DecisionUsageCounter()

    init(environment: [String: String], threads: Int, logicalCPUCount: Int) throws {
        let configuration = try PortableProcessingConfiguration.resolve(
            environment: environment,
            threads: threads,
            logicalCPUCount: logicalCPUCount,
            withDecisions: true
        )
        guard let clauseTaggerModelDirectory = configuration.clauseTaggerModelDirectory else {
            throw EngineAdapterError(
                code: .invalidSettings,
                message: "Portable inference configuration requires a clause tagger model directory",
                recoveryAction: .replaceSettings,
                details: []
            )
        }
        self.configuration = configuration
        self.threads = threads
        self.clauseTaggerInspection = PortableClauseTaggerInspection(modelDirectory: clauseTaggerModelDirectory)
    }

    init(configuration: PortableProcessingConfiguration, clauseTaggerModelDirectory: URL, threads: Int) {
        self.configuration = configuration
        self.threads = threads
        self.clauseTaggerInspection = PortableClauseTaggerInspection(modelDirectory: clauseTaggerModelDirectory)
    }

    func prepare(
        settings: EngineSettings,
        onProgress: @escaping @Sendable (EngineModelProgress) -> Void
    ) async throws {
        try validate(settings: settings)
        do {
            try await PortableModelPreparationService().prepare(configuration: configuration) { progress in
                let stage: EngineModelProgress.Stage = progress.stage == .validating ? .validating : .loading
                onProgress(EngineModelProgress(stage: stage, completed: progress.completed, total: progress.total))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PortableModelPreparationError {
            throw Self.modelError(error)
        } catch {
            throw EngineAdapterError(
                code: .modelFailure,
                message: "モデルを準備できません: \(error.localizedDescription)",
                recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
    }

    func decisionUsage() async throws -> DecisionUsageSnapshot {
        await usageCounter.snapshot()
    }

    func inspectClauseTagger() async throws -> ClauseTaggerModelIdentity {
        do {
            return try await clauseTaggerInspection.inspect()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PortableModelPreparationError {
            throw Self.modelError(error)
        } catch {
            throw EngineAdapterError(
                code: .modelFailure,
                message: "発話文モデルを確認できません: \(error.localizedDescription)",
                recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
    }

    func makeInference(settings: EngineSettings) throws -> EngineInference {
        try validate(settings: settings)
        let bundle: PortableSessionEngineBundle
        do {
            bundle = try PortableSessionEngineBundle(configuration: configuration, usageCounter: usageCounter)
        } catch {
            throw EngineAdapterError(
                code: .modelFailure,
                message: "モデルを構成できません: \(error.localizedDescription)",
                recoveryAction: .prepareModels,
                details: [EngineAdapterError.detail(for: error)]
            )
        }
        return EngineInference(
            engines: bundle.engines,
            contentPriority: bundle.contentPriority,
            timelineBuilder: PortableImportedAudioTimelineBuilder(),
            makeLiveVADSession: { processingDirectory, sessionURL, checkpoint, runID in
                try SileroLiveVADSessionFactory.make(
                    environment: bundle.vadEnvironment,
                    modelURL: bundle.configuration.sileroModelURL,
                    intraOpThreads: 1,
                    processingDirectory: processingDirectory,
                    sessionURL: sessionURL,
                    initialCheckpoint: checkpoint,
                    measureMicInputLevels: false,
                    segmentationRunID: runID
                )
            }
        )
    }

    private static func modelError(_ error: PortableModelPreparationError) -> EngineAdapterError {
        let code: EngineErrorCode
        switch error {
        case .missing: code = .modelMissing
        case .invalid: code = .modelCorrupt
        case .loadFailed: code = .modelFailure
        }
        return EngineAdapterError(
            code: code,
            message: error.localizedDescription,
            recoveryAction: .prepareModels,
            details: [EngineAdapterError.detail(domain: "models", code: error.model.rawValue, message: error.localizedDescription)]
        )
    }

    private func validate(settings: EngineSettings) throws {
        let mismatch: String?
        if settings.asrSize.rawValue != configuration.qwen3Size.rawValue {
            mismatch = "ASR size does not match the portable model configuration"
        } else if settings.threads != threads {
            mismatch = "Thread count does not match --threads"
        } else if !settings.decisionsEnabled {
            mismatch = "Portable harness inference requires decisions to be enabled"
        } else {
            mismatch = nil
        }
        guard let mismatch else { return }
        throw EngineAdapterError(
            code: .invalidSettings,
            message: mismatch,
            recoveryAction: .replaceSettings,
            details: []
        )
    }
}
#endif

private enum HarnessLaunchError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        guard case .usage(let reason) = self else { return nil }
        return "\(reason)\n\(harnessUsage)"
    }
}
