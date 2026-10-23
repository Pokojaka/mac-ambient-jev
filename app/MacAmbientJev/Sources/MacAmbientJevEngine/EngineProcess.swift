import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevPortableRuntime
import MacAmbientJevWindowsSupport

enum EngineLaunchError: Error, LocalizedError {
    case usage(String)
    case startup(String)

    var errorDescription: String? {
        switch self {
        case let .usage(reason):
            "\(reason)\n使い方: MacAmbientJevEngine [--local-app-data <絶対パス>]"
        case let .startup(reason):
            reason
        }
    }
}

struct EngineLaunchOptions: Equatable {
    /// Replaces the LocalAppData folder that holds `mac-ambient-jev`. Absent means the user's LocalAppData.
    let localAppData: URL?

    static func parse(_ arguments: [String]) throws -> EngineLaunchOptions {
        var localAppData: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument == "--local-app-data" else {
                throw EngineLaunchError.usage("不明な引数です: \(argument)")
            }
            guard localAppData == nil else {
                throw EngineLaunchError.usage("--local-app-data は 1 回だけ指定できます")
            }
            index += 1
            guard index < arguments.count, (arguments[index] as NSString).isAbsolutePath else {
                throw EngineLaunchError.usage("--local-app-data には絶対パスを指定してください")
            }
            localAppData = URL(fileURLWithPath: arguments[index], isDirectory: true)
            index += 1
        }
        return EngineLaunchOptions(localAppData: localAppData)
    }
}

/// The engine process: stdin/stdout NDJSON, one controller, diagnostics on stderr only.
enum EngineProcess {
    /// How long a requested shutdown waits for running finalization to pause before it fails.
    static let shutdownPauseTimeout = Duration.seconds(30)

    /// Returns the process exit code: 0 for a requested shutdown or a client disconnect, non-zero otherwise.
    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        _ = EngineLog.snapshot()
        defer { EngineLog.close(timeout: 0.25) }

        do {
            let options = try EngineLaunchOptions.parse(arguments)
            return try await serve(options: options)
        } catch {
            log("\(error.localizedDescription)")
            return EngineExit.startupFailed("").processExitCode
        }
    }

    static func resolvePaths(_ options: EngineLaunchOptions) throws -> AppPaths {
        if let localAppData = options.localAppData {
            return AppPaths(
                applicationSupportURL: localAppData,
                cacheURL: localAppData.appending(path: "Caches", directoryHint: .isDirectory),
                sessionsRootOverride: nil
            )
        }
        return try AppPaths.systemDefault(fileManager: .default)
    }

    @MainActor
    static func withLockedRoot(
        paths: AppPaths,
        operation: @MainActor () async throws -> Int32
    ) async throws -> Int32 {
        let lock = try ApplicationRootLock.acquire(paths: paths)
        defer { EngineLog.close(timeout: 0.25); lock.release() }

        do {
            return try await operation()
        } catch {
            log(error.localizedDescription)
            return EngineExit.startupFailed("").processExitCode
        }
    }

    @MainActor
    private static func serve(options: EngineLaunchOptions) async throws -> Int32 {
        let paths = try resolvePaths(options)
        return try await withLockedRoot(paths: paths) {
            let stdout = try WindowsPipeByteSink.claimStandardOutput()
            let diagnostics = try WindowsDiagnosticCapture.redirectStandardOutput(onChunk: { EngineLog.write($0) })
            defer { diagnostics.close() }

            let logicalCPUCount = ProcessInfo.processInfo.activeProcessorCount
            let transport = EngineTransport(
                source: WindowsPipeByteSource(handle: try WindowsPipeByteSource.standardInput()),
                sink: WindowsPipeByteSink(handle: stdout),
                limits: .production
            )
            let application = EngineApplication(
                configuration: EngineApplicationConfiguration(
                    paths: paths,
                    logicalCPUCount: logicalCPUCount,
                    sleep: { try await Task.sleep(for: $0) },
                    shutdownPauseTimeout: shutdownPauseTimeout
                ),
                capture: WindowsEngineCapture(factory: WindowsWASAPICaptureFactory()),
                inference: PortableEngineInference(
                    layout: PortableInstalledModelLayout(modelsRoot: paths.modelsRoot), logicalCPUCount: logicalCPUCount
                ),
                events: EngineEventEmitter(transport: transport)
            )
            application.start()
            let controller = EngineController(transport: transport, handlers: application.handlers, admission: .production)
            let exit = await controller.run()
            if case .startupFailed = exit {
                do {
                    try await application.handlers.shutdown.shutdown(reason: .outputFailed)
                } catch {
                    log("startup failure shutdown failed: \(error)")
                }
            }
            await application.waitForStartupRecovery()
            if exit.processExitCode != 0 { log("engine stopped: \(exit)") }
            return exit.processExitCode
        }
    }

    static func log(_ message: String) {
        EngineLog.write(message)
    }
}
