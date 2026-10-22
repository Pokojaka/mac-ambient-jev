import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline
#if os(macOS)
import MacAmbientJevRuntime
#endif
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

#if os(macOS)
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
#endif

@Test
func resumeOutputCannotResolveInsideTheRecoveredSession() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let sessionsRoot = root.appending(path: "sessions", directoryHint: .isDirectory)
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: sessionsRoot)
    let session = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: session)

    for output in [
        session.appending(path: "events.jsonl").path,
        alias.appending(path: "session.json").path,
        sessionsRoot.appending(path: session.lastPathComponent.uppercased()).appending(path: "processing_metadata.json").path,
    ] {
        _ = try ProcessRecordingCommand.parseInput(
            ["--resume-session", id.uuidString, "--sessions-root", sessionsRoot.path, output],
            measured: false
        )
        #expect(throws: ProcessRecordingError.self) {
            _ = try ProcessRecordingCommand.resolveResumeSession(
                sessionID: id, root: sessionsRoot, outputURL: URL(fileURLWithPath: output)
            )
        }
    }
    #expect(try ProcessRecordingCommand.resolveResumeSession(
        sessionID: id, root: sessionsRoot, outputURL: root.appending(path: "segments.json")
    ) == session)
}

@Test
func diskInspectUsesManifestIdentityAndRejectsMissingOrAmbiguousSessions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
    let first = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    // A valid empty recording emits action "none" without constructing an engine.
    try ProcessRecordingCommand.inspect(sessionID: id, root: root)
    let absent = UUID()
    #expect(throws: SessionDirectoryLookupError.notFound(absent)) {
        try ProcessRecordingCommand.inspect(sessionID: absent, root: root)
    }
    let second = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: id, source: .recording(.microphone),
        createdAt: Date(timeIntervalSince1970: 1_700_000_001), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    #expect(throws: SessionDirectoryLookupError.multipleMatches(sessionID: id, folders: [first, second])) {
        try ProcessRecordingCommand.inspect(sessionID: id, root: root)
    }
    #expect(throws: SessionDirectoryLookupError.multipleMatches(sessionID: id, folders: [first, second])) {
        _ = try ProcessRecordingCommand.resolveResumeSession(
            sessionID: id, root: root, outputURL: root.deletingLastPathComponent().appending(path: "segments.json")
        )
    }
}
