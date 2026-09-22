#!/usr/bin/env swift

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 || arguments.count == 3 else {
    FileHandle.standardError.write(
        Data(
            """
            使い方:
              swift tools/evaluate-session.swift <manifest.json> <segments.json> [scene-transitions.json]

            """.utf8
        )
    )
    throw NSError(
        domain: "MacAmbientJevEvaluateSession",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "引数が不足しています"]
    )
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift",
    "run",
    "--package-path",
    "app/MacAmbientJev",
    "MacAmbientJevEvaluateSession"
] + arguments
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "MacAmbientJevEvaluateSession",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "評価コマンドが失敗しました"]
    )
}
