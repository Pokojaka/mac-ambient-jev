#!/usr/bin/env swift

import Foundation

enum RecordingTestError: LocalizedError {
    case invalidArguments
    case commandFailed(String, Int32)
    case missingGeneratedFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "音声ファイルを1つ指定してください"
        case .commandFailed(let command, let status):
            return "\(command) が終了コード \(status) で失敗しました"
        case .missingGeneratedFile(let path):
            return "生成物が見つかりません: \(path)"
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else {
    print(
        """
        使い方:
          swift tools/test-recording.swift <audio-file>

        1. 音声をVAD・ASR・話者分離まで処理
        2. segments.json を生成
        3. manifest.json を読み込み
        4. report.json を生成
        """
    )
    throw RecordingTestError.invalidArguments
}

let audioURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
let corpusDirectory = audioURL.deletingLastPathComponent()
let segmentsURL = corpusDirectory.appending(path: "segments.json")
let manifestURL = corpusDirectory.appending(path: "manifest.json")
let reportURL = corpusDirectory.appending(path: "report.json")
let sceneTransitionsURL = corpusDirectory.appending(path: "scene-transitions.json")

func run(_ command: [String], captureOutput: Bool = false) throws -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command

    let pipe = captureOutput ? Pipe() : nil
    if let pipe {
        process.standardOutput = pipe
    } else {
        process.standardOutput = FileHandle.standardOutput
    }
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw RecordingTestError.commandFailed(
            command.joined(separator: " "),
            process.terminationStatus
        )
    }

    return pipe?.fileHandleForReading.readDataToEndOfFile()
}

_ = try run([
    "swift",
    "tools/process-recording.swift",
    audioURL.path
])

guard FileManager.default.fileExists(atPath: segmentsURL.path) else {
    throw RecordingTestError.missingGeneratedFile(segmentsURL.path)
}
guard FileManager.default.fileExists(atPath: manifestURL.path) else {
    throw RecordingTestError.missingGeneratedFile(manifestURL.path)
}

var evaluationCommand = [
    "swift",
    "tools/evaluate-session.swift",
    manifestURL.path,
    segmentsURL.path
]

if FileManager.default.fileExists(atPath: sceneTransitionsURL.path) {
    evaluationCommand.append(sceneTransitionsURL.path)
}

let report = try run(evaluationCommand, captureOutput: true) ?? Data()
try report.write(to: reportURL, options: .atomic)

print("評価レポートを生成しました: \(reportURL.path)")
