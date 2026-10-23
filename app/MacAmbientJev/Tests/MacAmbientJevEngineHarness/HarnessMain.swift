import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineE2ESupport
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

private let harnessUsage = "Usage: MacAmbientJevEngineHarness --root <absolute-existing-directory> --fixture <absolute-file> --sample-rate <16000|44100|48000> --channels <1..8>"

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
            let options = try HarnessOptions.parse(arguments)
            let paths = AppPaths(
                applicationSupportURL: options.root,
                cacheURL: options.root.appending(path: "Caches", directoryHint: .isDirectory),
                sessionsRootOverride: nil
            )
            let rootLock = try ApplicationRootLock.acquire(paths: paths)
            defer { rootLock.release() }
            return try await serve(options: options, paths: paths)
        } catch {
            EngineLog.write(error.localizedDescription)
            return EngineExit.startupFailed("").processExitCode
        }
    }

    private static func serve(options: HarnessOptions, paths: AppPaths) async throws -> Int32 {
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
        let application = EngineApplication(
            configuration: EngineApplicationConfiguration(
                paths: paths,
                logicalCPUCount: 1,
                sleep: { try await Task.sleep(for: $0) },
                shutdownPauseTimeout: .seconds(30)
            ),
            capture: capture,
            inference: DeterministicInferenceProvider(),
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

private struct HarnessOptions {
    let root: URL
    let fixture: URL
    let sampleRate: Double
    let channels: Int

    static func parse(_ arguments: [String]) throws -> HarnessOptions {
        let recognized: Set<String> = ["--root", "--fixture", "--sample-rate", "--channels"]
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
        return HarnessOptions(root: root, fixture: fixture, sampleRate: sampleRate, channels: channels)
    }
}

private enum HarnessLaunchError: Error, LocalizedError {
    case usage(String)

    var errorDescription: String? {
        guard case .usage(let reason) = self else { return nil }
        return "\(reason)\n\(harnessUsage)"
    }
}
