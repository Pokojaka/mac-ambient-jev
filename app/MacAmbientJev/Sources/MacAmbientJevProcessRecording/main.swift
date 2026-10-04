import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime
import MLX

enum ProcessRecordingError: LocalizedError {
    case invalidArguments
    case audioFileNotFound(String)
    case processingFailed(String)
    case invalidSession(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "音声ファイルを指定してください"
        case .audioFileNotFound(let path):
            return "音声ファイルが見つかりません: \(path)"
        case .processingFailed(let message):
            return "録音データの処理に失敗しました: \(message)"
        case .invalidSession(let message):
            return "復旧対象が不正です: \(message)"
        }
    }
}

private actor ProcessingResultCollector {
    private var segments: [MaterializedTranscriptSegment] = []
    private var state: ProcessingState = .idle

    func update(
        segments: [MaterializedTranscriptSegment],
        state: ProcessingState
    ) {
        self.segments = segments
        self.state = state
    }

    func snapshot() -> (
        segments: [MaterializedTranscriptSegment],
        state: ProcessingState
    ) {
        (segments, state)
    }
}

enum RecordingInput {
    case importFile(audio: URL, output: URL, keepSession: Bool, pacing: ASRPacingMode)
    case inspect(sessionID: UUID, root: URL)
    case resume(sessionID: UUID, root: URL, output: URL, pacing: ASRPacingMode)
}

@main
struct ProcessRecordingCommand {
    static func main() async throws {
        let invocation: Invocation
        do {
            invocation = try parseCommandLine(Array(CommandLine.arguments.dropFirst()))
        } catch ProcessRecordingError.invalidArguments {
            printUsage()
            throw ProcessRecordingError.invalidArguments
        }
        let input = invocation.input
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
        let result: SessionProcessingResult
        do {
            result = try await execute(input: input, monitor: monitor)
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
        guard result.disposition == .completed else {
            throw ProcessRecordingError.processingFailed(result.message ?? result.disposition.rawValue)
        }
    }

    private struct Measurement {
        let runID: String
        let metricsPath: String
        let thermalPath: String
        let memoryPath: String
    }

    private struct Invocation {
        let input: RecordingInput
        let measurement: Measurement?
    }

    private static func parseCommandLine(_ originalArguments: [String]) throws -> Invocation {
        var arguments = originalArguments
        let runID = try removeOption("--run-id", from: &arguments)
        let metricsPath = try removeOption("--metrics-output", from: &arguments)
        let thermalPath = try removeOption("--thermal-output", from: &arguments)
        let memoryPath = try removeOption("--memory-output", from: &arguments)
        let provided = [runID, metricsPath, thermalPath, memoryPath].compactMap { $0 }
        guard provided.isEmpty || provided.count == 4 else {
            throw ProcessRecordingError.invalidArguments
        }
        if let runID {
            guard !runID.isEmpty, !runID.contains("/") else {
                throw ProcessRecordingError.invalidArguments
            }
        }
        let input = try parseInput(arguments, measured: runID != nil)
        guard let runID, let metricsPath, let thermalPath, let memoryPath else {
            return Invocation(input: input, measurement: nil)
        }
        return Invocation(input: input, measurement: Measurement(
            runID: runID,
            metricsPath: metricsPath,
            thermalPath: thermalPath,
            memoryPath: memoryPath
        ))
    }

    static func parseInput(_ originalArguments: [String], measured: Bool) throws -> RecordingInput {
        var arguments = originalArguments
        let keepSession = try removeFlag("--keep-session", from: &arguments)
        let pacingMode: ASRPacingMode = try removeFlag("--low-heat", from: &arguments)
            ? .lowHeat : .normal
        let resumeID = try removeOption("--resume-session", from: &arguments)
        let inspectID = try removeOption("--inspect-session", from: &arguments)
        let rootPath = try removeOption("--sessions-root", from: &arguments)
        guard !arguments.contains(where: { $0.hasPrefix("--") }) else {
            throw ProcessRecordingError.invalidArguments
        }
        if resumeID != nil || inspectID != nil {
            guard let rootPath,
                  (resumeID == nil) != (inspectID == nil),
                  !keepSession,
                  let id = UUID(uuidString: resumeID ?? inspectID ?? "") else {
                throw ProcessRecordingError.invalidArguments
            }
            let root = URL(fileURLWithPath: rootPath).standardizedFileURL
            if inspectID != nil {
                guard !measured, pacingMode == .normal, arguments.isEmpty else {
                    throw ProcessRecordingError.invalidArguments
                }
                return .inspect(sessionID: id, root: root)
            } else {
                guard arguments.count == 1 else { throw ProcessRecordingError.invalidArguments }
                let output = URL(fileURLWithPath: arguments[0]).standardizedFileURL
                return .resume(sessionID: id, root: root, output: output, pacing: pacingMode)
            }
        }
        guard rootPath == nil else { throw ProcessRecordingError.invalidArguments }
        guard arguments.count == 1 || arguments.count == 2 else {
            throw ProcessRecordingError.invalidArguments
        }
        let audioURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let outputURL = arguments.count == 2
            ? URL(fileURLWithPath: arguments[1]).standardizedFileURL
            : audioURL.deletingLastPathComponent().appending(path: "segments.json")
        if arguments.count == 2,
           audioURL.resolvingSymlinksInPath().standardizedFileURL
            == outputURL.resolvingSymlinksInPath().standardizedFileURL {
            throw ProcessRecordingError.invalidArguments
        }
        return .importFile(audio: audioURL, output: outputURL, keepSession: keepSession, pacing: pacingMode)
    }

    private static func execute(input: RecordingInput, monitor: RunMonitor?) async throws -> SessionProcessingResult {
        switch input {
        case .inspect(let id, let root):
            try inspect(sessionID: id, root: root)
            return .completed(metrics: nil, noSpeech: false)
        case .resume(let id, let root, let output, let pacingMode):
            return try await resume(
                sessionID: id, root: root, outputURL: output,
                pacingMode: pacingMode, monitor: monitor
            )
        case .importFile(let audioURL, let outputURL, let keepSession, let pacingMode):
            try checkStart(pacingMode: pacingMode)
            return try await importFile(
                audioURL: audioURL, outputURL: outputURL,
                keepSession: keepSession, pacingMode: pacingMode, monitor: monitor
            )
        }
    }

    private static func checkStart(pacingMode: ASRPacingMode) throws {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != .nominal && thermal != .fair {
            throw ProcessRecordingError.processingFailed("熱状態が落ち着くまで開始できません")
        }
        if pacingMode == .lowHeat {
            Memory.cacheLimit = min(Memory.cacheLimit, 2 * 1024 * 1024 * 1024)
        }
    }

    private static func importFile(
        audioURL: URL,
        outputURL: URL,
        keepSession: Bool,
        pacingMode: ASRPacingMode,
        monitor: RunMonitor?
    ) async throws -> SessionProcessingResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ProcessRecordingError.audioFileNotFound(audioURL.path)
        }

        let paths = try AppPaths.systemDefault(fileManager: .default)
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths,
            sessionID: sessionID,
            source: .imported(originalFilename: audioURL.lastPathComponent),
            createdAt: Date(), timeZone: .current
        )
        print("session_id: \(sessionID.uuidString)")

        defer {
            if !keepSession {
                do {
                    try FileManager.default.removeItem(at: sessionURL)
                } catch {
                    FileHandle.standardError.write(
                        Data(
                            "一時セッションを削除できませんでした: \(error.localizedDescription)\n".utf8
                        )
                    )
                }
            }
        }

        let imported = try AudioImporter().importFile(
            audioURL,
            into: sessionURL
        )

        let collector = ProcessingResultCollector()
        let processor = NativeSessionProcessor(
            paths: paths, engines: .production(paths: paths), contentPriority: .disabled
        )

        print("処理を開始します: \(audioURL.path)")

        let processing = await processor.processImportedSession(
            sessionID: sessionID,
            originalURL: imported.originalURL,
            pacingMode: pacingMode,
            shouldPause: pauseCheck(monitor),
            onPhase: { phase in await monitor?.setPhase(phase) },
            metadataPolicy: .reject,
            onStatus: { message in
                print(message)
            },
            onUpdate: { segments, state in
                await collector.update(
                    segments: segments,
                    state: state
                )
            }
        )

        guard processing.disposition == .completed else { return processing }

        let result = await collector.snapshot()
        switch result.state {
        case .partialFailure(let message):
            throw ProcessRecordingError.processingFailed(message)
        case .idle, .running, .backlogged:
            throw ProcessRecordingError.processingFailed(
                "処理が完了状態へ到達しませんでした"
            )
        case .complete:
            break
        }

        try export(sessionURL: sessionURL, outputURL: outputURL)

        print("segments.json を生成しました: \(outputURL.path)")
        if keepSession {
            print("セッションデータを保持しました: \(sessionURL.path)")
        } else {
            print("テスト用セッションは処理終了後に削除します")
        }
        return processing
    }

    static func inspect(sessionID: UUID, root: URL) throws {
        let action: String
        do {
            switch try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID)?.action {
            case .finalize: action = "finalize"
            case .retryContentPriority: action = "retryContentPriority"
            case nil: action = "none"
            }
        } catch SessionRecoveryScannerError.missingAudio,
                SessionAudioSourceError.importedOriginalMissing {
            action = "unrecoverable"
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["session_id": sessionID.uuidString, "action": action],
            options: [.sortedKeys]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    static func resolveResumeSession(sessionID: UUID, root: URL, outputURL: URL) throws -> URL {
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: root, sessionID: sessionID)
        let sessionPath = sessionURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        let outputPath = outputURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: outputURL.lastPathComponent).resolvingSymlinksInPath()
            .pathComponents.map { $0.lowercased() }
        guard !outputPath.starts(with: sessionPath) else {
            throw ProcessRecordingError.invalidArguments
        }
        return sessionURL
    }

    private static func resume(
        sessionID: UUID,
        root: URL,
        outputURL: URL,
        pacingMode: ASRPacingMode,
        monitor: RunMonitor?
    ) async throws -> SessionProcessingResult {
        let sessionURL = try resolveResumeSession(sessionID: sessionID, root: root, outputURL: outputURL)
        let candidate = try SessionRecoveryScanner(sessionsRoot: root).inspect(sessionID: sessionID)
        try checkStart(pacingMode: pacingMode)

        let defaults = try AppPaths.systemDefault(fileManager: .default)
        let paths = AppPaths(
            applicationSupportURL: defaults.applicationSupportURL,
            cacheURL: defaults.cacheURL,
            sessionsRootOverride: root
        )
        let processor = NativeSessionProcessor(
            paths: paths, engines: .production(paths: paths), contentPriority: .disabled
        )
        let collector = ProcessingResultCollector()
        let onUpdate: NativeSessionProcessor.UpdateHandler = { segments, state in
            await collector.update(segments: segments, state: state)
        }
        let onStatus: NativeSessionProcessor.StatusHandler = { message in print(message) }
        let onPhase: NativeSessionProcessor.PhaseHandler = { phase in await monitor?.setPhase(phase) }
        let result: SessionProcessingResult?
        switch (candidate?.action, candidate?.source) {
        case (.retryContentPriority?, _):
            throw ProcessRecordingError.invalidSession("この復旧 action は CLI の対象外です")
        case (.finalize?, .recordedTimeline(let checkpoint)?):
            result = await processor.processFinalTranscript(
                sessionID: sessionID,
                checkpoint: checkpoint,
                pacingMode: pacingMode,
                shouldPause: pauseCheck(monitor),
                onPhase: onPhase,
                metadataPolicy: .reject,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        case (.finalize?, .importedOriginal(let originalURL)?):
            result = await processor.processImportedSession(
                sessionID: sessionID,
                originalURL: originalURL,
                pacingMode: pacingMode,
                shouldPause: pauseCheck(monitor),
                onPhase: onPhase,
                metadataPolicy: .reject,
                onStatus: onStatus,
                onUpdate: onUpdate
            )
        case (nil, _), (.finalize?, nil):
            result = nil
        }
        if let result, result.disposition != .completed { return result }
        if result != nil, await collector.snapshot().state != .complete {
            throw ProcessRecordingError.processingFailed("後処理が完了状態へ到達しませんでした")
        }
        try export(sessionURL: sessionURL, outputURL: outputURL)
        print("segments.json を生成しました: \(outputURL.path)")
        return result ?? .completed(metrics: nil, noSpeech: false)
    }

    /// Measured runs pause on the monitor's thermal policy; others pause at critical thermal state.
    private static func pauseCheck(_ monitor: RunMonitor?) -> NativeSessionProcessor.PauseCheck {
        if let monitor {
            return { await monitor.shouldPause() }
        }
        return { ProcessInfo.processInfo.thermalState == .critical }
    }

    private static func export(sessionURL: URL, outputURL: URL) throws {
        let metadata = try ProcessingMetadataStore(sessionURL: sessionURL).load()
        guard let runs = metadata?.activeRuns, runs.scope != nil else {
            throw ProcessRecordingError.processingFailed("音響範囲整理の run が完了していません")
        }
        let processingDirectory = sessionURL.appending(path: "audio/processing")
        guard let checkpoint = try AudioCheckpoint.loadRecovered(from: processingDirectory) else {
            throw ProcessRecordingError.processingFailed("録音チェックポイントがありません")
        }
        let recovered = try SessionRecovery.recoverJSONL(
            Data(contentsOf: sessionURL.appending(path: "events.jsonl"))
        )
        guard !recovered.droppedIncompleteTail else {
            throw ProcessRecordingError.processingFailed("イベントログの末尾が不完全です")
        }
        let events = try EventLogTranscriptReader().events(lines: recovered.lines, activeRuns: runs)
        let segments = TranscriptMaterializer(sampleRate: checkpoint.sampleRate).materialize(
            events: events, activeRuns: runs
        ).filter(\.hasRecognizedText)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(segments).write(to: outputURL, options: .atomic)
    }

    private static func removeOption(_ option: String, from arguments: inout [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: option) else { return nil }
        guard index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--"),
              !arguments[(index + 2)...].contains(option) else {
            throw ProcessRecordingError.invalidArguments
        }
        arguments.remove(at: index)
        return arguments.remove(at: index)
    }

    private static func removeFlag(
        _ flag: String,
        from arguments: inout [String]
    ) throws -> Bool {
        guard let index = arguments.firstIndex(of: flag) else {
            return false
        }
        arguments.remove(at: index)
        guard !arguments.contains(flag) else { throw ProcessRecordingError.invalidArguments }
        return true
    }

    private static func printUsage() {
        FileHandle.standardError.write(Data(
            """
            使い方:
              MacAmbientJevProcessRecording [--keep-session] [--low-heat] <audio-file> [segments.json]
              MacAmbientJevProcessRecording --inspect-session <UUID> --sessions-root <path>
              MacAmbientJevProcessRecording --resume-session <UUID> --sessions-root <path> [--low-heat] <segments.json>

            計測時は import または resume に --run-id、--metrics-output、
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
