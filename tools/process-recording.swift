#!/usr/bin/env swift

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || arguments.count == 2 else {
    print(
        """
        使い方:
          swift tools/process-recording.swift <audio-file> [segments.json]
        """
    )
    throw NSError(
        domain: "MacAmbientJevProcessRecording",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "引数が不正です"]
    )
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift",
    "run",
    "--package-path",
    "app/MacAmbientJev",
    "MacAmbientJevProcessRecording"
] + arguments
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "MacAmbientJevProcessRecording",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "録音データ処理が失敗しました"]
    )
}
