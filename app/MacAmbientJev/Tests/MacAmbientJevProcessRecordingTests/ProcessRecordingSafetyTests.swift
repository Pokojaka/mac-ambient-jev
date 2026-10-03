import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime
import Testing
@testable import MacAmbientJevProcessRecording

@Test
func explicitOutputCannotOverwriteImportedAudioThroughSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let audio = root.appending(path: "recording.wav")
    try Data([0, 1, 2, 3]).write(to: audio)
    let alias = root.appending(path: "output.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: audio)

    do {
        _ = try ProcessRecordingCommand.parseInput([audio.path, alias.path], measured: false)
        Issue.record("output alias must be rejected before importing audio")
    } catch ProcessRecordingError.invalidArguments {
    } catch {
        Issue.record("unexpected error: \(error)")
    }
    #expect(try Data(contentsOf: audio) == Data([0, 1, 2, 3]))
}

@Test
func measurementOutputsMustBePairwiseDistinct() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    for (index, pair) in [(0, 1), (0, 2), (1, 2)].enumerated() {
        let directory = root.appending(path: "case-\(index)")
        var paths = ["metrics.json", "thermal.json", "memory.json"].map {
            directory.appending(path: $0)
        }
        paths[pair.1] = paths[pair.0]
        #expect(throws: RunMonitorError.duplicateDestination) {
            try RunMonitor(
                runID: "run", metricsURL: paths[0], thermalURL: paths[1], memoryURL: paths[2]
            )
        }
    }
}

@Test
func measurementOutputsCannotAliasThroughSymlinkedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

    #expect(throws: RunMonitorError.duplicateDestination) {
        try RunMonitor(
            runID: "run", metricsURL: root.appending(path: "metrics.json"),
            thermalURL: alias.appending(path: "metrics.json"),
            memoryURL: root.appending(path: "memory.json")
        )
    }
}

@Test
func unwritableSampleFailsTheMeasuredRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let metrics = root.appending(path: "metrics.json")
    let thermal = root.appending(path: "thermal.jsonl")
    let memory = root.appending(path: "memory.jsonl")
    let monitor = try RunMonitor(runID: "run", metricsURL: metrics, thermalURL: thermal, memoryURL: memory)
    try FileManager.default.createDirectory(at: thermal, withIntermediateDirectories: false)

    await monitor.setPhase(.asr)
    await monitor.setPhase(.postprocessing)

    do {
        try await monitor.write(SessionProcessingResult.completed(metrics: nil, noSpeech: false))
        Issue.record("a failed sample must fail the measured run")
    } catch RunMonitorError.samplingFailed(let path, _) {
        #expect(path == thermal.path)
    }
    #expect(FileManager.default.fileExists(atPath: metrics.path))
    #expect(!FileManager.default.fileExists(atPath: memory.path))
}

@Test
func resumeOutputCannotResolveInsideTheRecoveredSession() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let session = root.appending(path: id.uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: session)

    for output in [
        session.appending(path: "events.jsonl").path,
        alias.appending(path: "session.json").path,
        root.appending(path: id.uuidString.lowercased()).appending(path: "processing_metadata.json").path,
    ] {
        #expect(throws: ProcessRecordingError.self) {
            _ = try ProcessRecordingCommand.parseInput(
                ["--resume-session", id.uuidString, "--sessions-root", root.path, output],
                measured: false
            )
        }
    }
    _ = try ProcessRecordingCommand.parseInput(
        ["--resume-session", id.uuidString, "--sessions-root", root.path, root.appending(path: "segments.json").path],
        measured: false
    )
}
