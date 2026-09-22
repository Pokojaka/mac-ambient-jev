import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime

private enum ProcessRecordingError: LocalizedError {
    case invalidArguments
    case audioFileNotFound(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "音声ファイルを指定してください"
        case .audioFileNotFound(let path):
            return "音声ファイルが見つかりません: \(path)"
        case .processingFailed(let message):
            return "録音データの処理に失敗しました: \(message)"
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

@main
struct ProcessRecordingCommand {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let keepSession = removeFlag("--keep-session", from: &arguments)

        guard arguments.count == 1 || arguments.count == 2 else {
            printUsage()
            throw ProcessRecordingError.invalidArguments
        }

        let audioURL = URL(
            fileURLWithPath: arguments[0]
        ).standardizedFileURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ProcessRecordingError.audioFileNotFound(audioURL.path)
        }

        let outputURL: URL
        if arguments.count == 2 {
            outputURL = URL(
                fileURLWithPath: arguments[1]
            ).standardizedFileURL
        } else {
            outputURL = audioURL
                .deletingLastPathComponent()
                .appending(path: "segments.json")
        }

        let corpusDirectory = outputURL.deletingLastPathComponent()
        let manifestURL = corpusDirectory.appending(path: "manifest.json")

        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.createDirectory(
                at: corpusDirectory,
                withIntermediateDirectories: true
            )
            let manifest = GoldenCorpusManifest(
                id: corpusDirectory.lastPathComponent,
                audio: audioURL.lastPathComponent,
                annotations: GoldenCorpusAnnotations(
                    sceneTransitions: [],
                    mustKeepTerms: [],
                    mustNotBeLowPriority: [],
                    mustNotBeBackground: []
                )
            )
            let manifestEncoder = JSONEncoder()
            manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try manifestEncoder.encode(manifest).write(
                to: manifestURL,
                options: .atomic
            )
            print("manifest.json を生成しました: \(manifestURL.path)")
        }

        let paths = AppPaths.systemDefault()
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper().createSession(
            paths: paths,
            sessionID: sessionID,
            sourceKind: .importedFile,
            originalFilename: audioURL.lastPathComponent
        )

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
        let processor = NativeSessionProcessor(paths: paths)

        print("処理を開始します: \(audioURL.path)")

        await processor.processImportedSession(
            sessionID: sessionID,
            originalURL: imported.originalURL,
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

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.segments).write(
            to: outputURL,
            options: .atomic
        )

        print("segments.json を生成しました: \(outputURL.path)")
        if keepSession {
            print("セッションデータを保持しました: \(sessionURL.path)")
        } else {
            print("テスト用セッションは処理終了後に削除します")
        }
    }

    private static func removeFlag(
        _ flag: String,
        from arguments: inout [String]
    ) -> Bool {
        guard let index = arguments.firstIndex(of: flag) else {
            return false
        }
        arguments.remove(at: index)
        return true
    }

    private static func printUsage() {
        print(
            """
            使い方:
              MacAmbientJevProcessRecording [--keep-session] <audio-file> [segments.json]

            出力先を省略すると、音声ファイルと同じディレクトリへ
            segments.json を生成します。

            通常はテスト用セッションを処理後に削除します。
            デバッグ用にセッションを残す場合だけ --keep-session を指定します。
            """
        )
    }
}