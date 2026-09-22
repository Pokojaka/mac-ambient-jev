#!/usr/bin/env swift

import Foundation

enum CorpusTestError: LocalizedError {
    case rootNotFound(String)
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .rootNotFound(let path):
            return "corpus ディレクトリが見つかりません: \(path)"
        case .commandFailed(let path, let status):
            return "\(path) の評価が終了コード \(status) で失敗しました"
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let force = arguments.contains("--force")
arguments.removeAll { $0 == "--force" }

let rootPath = arguments.first ?? "test-data/recordings/local"
let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(
    atPath: rootURL.path,
    isDirectory: &isDirectory
), isDirectory.boolValue else {
    throw CorpusTestError.rootNotFound(rootURL.path)
}

let supportedExtensions = Set([
    "wav", "m4a", "mp3", "aac", "caf", "aiff", "aif", "flac"
])

let directories = try FileManager.default.contentsOfDirectory(
    at: rootURL,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
)
.filter {
    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}
.sorted { $0.lastPathComponent < $1.lastPathComponent }

var processed = 0
var skipped = 0
var failures: [(String, Int32)] = []

for directory in directories {
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    guard let audioURL = files
        .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        .first else {
        continue
    }

    let reportURL = directory.appending(path: "report.json")
    if !force && FileManager.default.fileExists(atPath: reportURL.path) {
        print("SKIP  \(directory.lastPathComponent) — report.json が既にあります")
        skipped += 1
        continue
    }

    print("RUN   \(directory.lastPathComponent) — \(audioURL.lastPathComponent)")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift",
        "tools/test-recording.swift",
        audioURL.path
    ]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus == 0 {
        processed += 1
    } else {
        failures.append((
            directory.lastPathComponent,
            process.terminationStatus
        ))
    }
}

print("")
print("処理完了: \(processed)")
print("スキップ: \(skipped)")
print("失敗: \(failures.count)")

if !failures.isEmpty {
    for failure in failures {
        FileHandle.standardError.write(
            Data("FAIL  \(failure.0) — exit \(failure.1)\n".utf8)
        )
    }
    throw CorpusTestError.commandFailed(
        failures[0].0,
        failures[0].1
    )
}
