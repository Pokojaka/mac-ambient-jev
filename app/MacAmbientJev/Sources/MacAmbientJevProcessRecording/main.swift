import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline
#if os(macOS)
import MacAmbientJevAppleSupport
import MacAmbientJevRuntime
import MLX
#else
import MacAmbientJevPortableRuntime
#endif

struct ProcessRecordingCommand {
    static func main() async throws {
        let invocation: ProcessRecordingInvocation
        do {
            invocation = try parseCommandLine(
                Array(CommandLine.arguments.dropFirst()),
                platform: .current,
                logicalCPUCount: ProcessInfo.processInfo.processorCount
            )
        } catch ProcessRecordingError.invalidArguments {
            printUsage()
            throw ProcessRecordingError.invalidArguments
        }

        let root: URL
        switch invocation.input {
        case .importFile(_, _, let value, _, _), .inspect(_, let value), .resume(_, let value, _, _):
            root = value
        }
        let defaults = try AppPaths.systemDefault(fileManager: .default)
        let validatedRoot = try SessionsRootPolicy.validated(
            root,
            protectedRoots: defaults.protectedSessionsRoots,
            fileManager: .default
        )
        if case .inspect(let sessionID, _) = invocation.input {
            try inspect(sessionID: sessionID, root: validatedRoot)
            return
        }
        if case .resume(let sessionID, _, let outputURL, _) = invocation.input {
            _ = try resolveResumeSession(
                sessionID: sessionID,
                root: validatedRoot,
                outputURL: outputURL
            )
        }

        let paths = AppPaths(
            applicationSupportURL: defaults.applicationSupportURL,
            cacheURL: defaults.cacheURL,
            sessionsRootOverride: validatedRoot
        )
        let service = makeService(
            paths: paths,
            protectedRoots: defaults.protectedSessionsRoots,
            pacingMode: pacingMode(for: invocation.input),
            threads: invocation.threads,
            logicalCPUCount: ProcessInfo.processInfo.processorCount
        )
        let eventRenderer = ProcessRecordingEventRenderer()
        let result: SessionProcessingResult
        #if os(macOS)
        let monitor = try invocation.measurement.map { measurement in
            try RunMonitor(
                runID: measurement.runID,
                metricsURL: URL(fileURLWithPath: measurement.metricsPath),
                thermalURL: URL(fileURLWithPath: measurement.thermalPath),
                memoryURL: URL(fileURLWithPath: measurement.memoryPath)
            )
        }
        let monitorTask: Task<Void, Never>? = monitor.map { monitor in
            Task { await monitor.run() }
        }
        let callbacks = makeCallbacks(
            eventRenderer: eventRenderer,
            shouldPause: {
                if let monitor { return await monitor.shouldPause() }
                return MacThermalMonitor().isCritical
            },
            onPhase: { phase in await monitor?.setPhase(phase) }
        )
        do {
            result = try await execute(
                input: invocation.input,
                service: service,
                callbacks: callbacks,
                withDecisions: invocation.withDecisions
            )
        } catch {
            monitorTask?.cancel()
            await monitorTask?.value
            if let monitor {
                try await monitor.write(.failed(
                    message: error.localizedDescription, metrics: nil, retained: nil
                ))
            }
            throw error
        }
        monitorTask?.cancel()
        await monitorTask?.value
        if let monitor { try await monitor.write(result) }
        #else
        let callbacks = makeCallbacks(
            eventRenderer: eventRenderer,
            shouldPause: { false },
            onPhase: { _ in }
        )
        result = try await execute(
            input: invocation.input,
            service: service,
            callbacks: callbacks,
            withDecisions: invocation.withDecisions
        )
        #endif

        guard result.disposition == .completed else {
            throw ProcessRecordingError.processingFailed(result.message ?? result.disposition.rawValue)
        }
        if case .importFile(_, _, _, let keepSession, _) = invocation.input {
            try await eventRenderer.printSuccessfulImportNotice(keepSession: keepSession)
        }
    }

    static func inspect(sessionID: UUID, root: URL) throws {
        let defaults = try AppPaths.systemDefault(fileManager: .default)
        let validatedRoot = try SessionsRootPolicy.validated(
            root,
            protectedRoots: defaults.protectedSessionsRoots,
            fileManager: .default
        )
        let paths = AppPaths(
            applicationSupportURL: defaults.applicationSupportURL,
            cacheURL: defaults.cacheURL,
            sessionsRootOverride: validatedRoot
        )
        let service = makeService(
            paths: paths,
            protectedRoots: defaults.protectedSessionsRoots,
            pacingMode: .normal,
            threads: nil,
            logicalCPUCount: ProcessInfo.processInfo.processorCount
        )
        let inspection = try service.inspect(sessionID: sessionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(inspection)
        print(String(decoding: data, as: UTF8.self))
    }

    static func resolveResumeSession(sessionID: UUID, root: URL, outputURL: URL) throws -> URL {
        do {
            return try SessionFileProcessingService.resolveResumeSession(
                sessionID: sessionID,
                root: root,
                outputURL: outputURL
            )
        } catch SessionFileProcessingError.invalidOutput {
            throw ProcessRecordingError.invalidArguments
        }
    }

    private static func execute(
        input: RecordingInput,
        service: SessionFileProcessingService,
        callbacks: SessionFileProcessingService.Callbacks,
        withDecisions: Bool
    ) async throws -> SessionProcessingResult {
        switch input {
        case .importFile(let audio, let output, _, let keepSession, let pacing):
            return try await service.importFile(
                .init(
                    audioURL: audio,
                    outputURL: output,
                    keepSession: keepSession,
                    pacingMode: pacing,
                    withDecisions: withDecisions
                ),
                callbacks: callbacks
            )
        case .resume(let sessionID, _, let output, let pacing):
            return try await service.resume(
                .init(
                    sessionID: sessionID,
                    outputURL: output,
                    pacingMode: pacing,
                    withDecisions: withDecisions
                ),
                callbacks: callbacks
            )
        case .inspect:
            throw ProcessRecordingError.invalidArguments
        }
    }

    private static func makeService(
        paths: AppPaths,
        protectedRoots: [URL],
        pacingMode: ASRPacingMode,
        threads: Int?,
        logicalCPUCount: Int
    ) -> SessionFileProcessingService {
        #if os(macOS)
        let timelineBuilder: any ImportedAudioTimelineBuilding = AudioFileTimelineBuilder()
        let makeResources: @Sendable (Bool) throws -> SessionFileProcessingResources = { withDecisions in
            try checkStart(pacingMode: pacingMode)
            let engines = SessionProcessingEngines.production(paths: paths)
            let contentPriority: ContentPriorityAccess
            let decisionProviderFactory: DecisionProviderFactory?
            if withDecisions {
                let modelDirectory = try localClauseTaggerModelDirectory(
                    environment: ProcessInfo.processInfo.environment
                )
                let usageCounter = DecisionUsageCounter()
                let factory = DecisionProviderFactory(
                    usageCounter: usageCounter,
                    loadProvider: {
                        let tagger = try LocalClauseTagger(modelDirectory: modelDirectory)
                        return LoadedDecisionProvider(provider: tagger, identity: tagger.identity)
                    }
                )
                decisionProviderFactory = factory
                contentPriority = .localTagger(
                    { try factory.makeCoordinator() },
                    usageCounter: usageCounter
                )
            } else {
                decisionProviderFactory = nil
                contentPriority = .disabled
            }
            return SessionFileProcessingResources(
                engines: engines,
                contentPriority: contentPriority,
                decisionProviderFactory: decisionProviderFactory
            )
        }
        #else
        let timelineBuilder: any ImportedAudioTimelineBuilding = PortableImportedAudioTimelineBuilder()
        let makeResources: @Sendable (Bool) throws -> SessionFileProcessingResources = { withDecisions in
            guard let threads else { throw ProcessRecordingError.invalidArguments }
            let configuration = try PortableProcessingConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment,
                threads: threads,
                logicalCPUCount: logicalCPUCount,
                withDecisions: withDecisions
            )
            let usageCounter = DecisionUsageCounter()
            let bundle = try PortableSessionEngineBundle(configuration: configuration, usageCounter: usageCounter)
            return SessionFileProcessingResources(
                engines: bundle.engines,
                contentPriority: bundle.contentPriority,
                decisionProviderFactory: bundle.decisionProviderFactory
            )
        }
        #endif
        return SessionFileProcessingService(
            paths: paths,
            protectedRoots: protectedRoots,
            timelineBuilder: timelineBuilder,
            makeResources: makeResources,
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    #if os(macOS)
    private static func checkStart(pacingMode: ASRPacingMode) throws {
        let thermal = MacThermalMonitor().pressure
        guard thermal == .nominal || thermal == .fair else {
            throw ProcessRecordingError.processingFailed("熱状態が落ち着くまで開始できません")
        }
        if pacingMode == .lowHeat {
            Memory.cacheLimit = min(Memory.cacheLimit, 2 * 1024 * 1024 * 1024)
        }
    }

    private static func localClauseTaggerModelDirectory(environment: [String: String]) throws -> URL {
        let key = "MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY"
        guard let path = environment[key], !path.isEmpty,
              (path as NSString).isAbsolutePath else {
            throw ProcessRecordingError.processingFailed(
                "\(key) must name a nonempty absolute directory"
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProcessRecordingError.processingFailed("\(key) is not an existing directory: \(path)")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    #endif

    private static func makeCallbacks(
        eventRenderer: ProcessRecordingEventRenderer,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler
    ) -> SessionFileProcessingService.Callbacks {
        SessionFileProcessingService.Callbacks(
            onEvent: { event in await eventRenderer.render(event) },
            onStatus: { message in print(message) },
            onUpdate: { _, _ in },
            shouldPause: shouldPause,
            onPhase: onPhase
        )
    }

    private static func pacingMode(for input: RecordingInput) -> ASRPacingMode {
        switch input {
        case .importFile(_, _, _, _, let pacing), .resume(_, _, _, let pacing): pacing
        case .inspect: .normal
        }
    }

    private static func printUsage() {
        FileHandle.standardError.write(Data(
            """
            使い方:
              MacAmbientJevProcessRecording --sessions-root <path> [--keep-session] [--low-heat] [--with-decisions] [--threads N] <audio-file> [segments.json]
              MacAmbientJevProcessRecording --inspect-session <UUID> --sessions-root <path>
              MacAmbientJevProcessRecording --resume-session <UUID> --sessions-root <path> [--low-heat] [--with-decisions] [--threads N] <segments.json>
              UUID は session.json の完全 ID。保存 root 直下の実フォルダーを検索します。
              resume の出力先は解決したセッションフォルダーの外に指定してください。

            Portable platform では import/resume に --threads N が必須です（1 から最大4、論理 CPU 数以下）。
            macOS では --threads は指定できません。--with-decisions は Mac と Portable で利用できます。
            macOS の decisions は MAC_AMBIENT_JEV_CLAUSE_TAGGER_MODEL_DIRECTORY を必要とします。
            Portable の decisions は portable model environment variables を必要とします。
            計測は macOS の import/resume のみ対応し、--run-id、--metrics-output、
            --thermal-output、--memory-output を全て指定してください。

            出力先を省略すると、音声ファイルと同じディレクトリへ
            segments.json を生成します。

            通常はテスト用セッションを処理後に削除します。
            デバッグ用にセッションを残す場合だけ --keep-session を指定します。
            --low-heat は発話区間の文字起こし完了ごとに約2秒休止します。

            """.utf8
        ))
    }
}

private actor ProcessRecordingEventRenderer {
    private var createdSessionURL: URL?

    func render(_ event: SessionFileProcessingService.Event) {
        switch event {
        case .sessionCreated(let sessionID, let sessionURL):
            createdSessionURL = sessionURL
            print("session_id: \(sessionID.uuidString)")
        case .exported(let outputURL):
            print("segments.json を生成しました: \(outputURL.path)")
        case .cleanupFailed(let message):
            FileHandle.standardError.write(
                Data("一時セッションを削除できませんでした: \(message)\n".utf8)
            )
        }
    }

    func printSuccessfulImportNotice(keepSession: Bool) throws {
        guard let createdSessionURL else {
            throw ProcessRecordingError.processingFailed(
                "import が完了しましたが sessionCreated 通知がありません"
            )
        }
        if keepSession {
            print("セッションデータを保持しました: \(createdSessionURL.path)")
        } else {
            print("テスト用セッションは処理終了後に削除します")
        }
    }
}

try await ProcessRecordingCommand.main()
