import Foundation
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
        do {
            _ = try RunMonitor(
                runID: "run", metricsURL: paths[0], thermalURL: paths[1], memoryURL: paths[2]
            )
            Issue.record("duplicate measurement outputs must be rejected")
        } catch {
            #expect((error as NSError).domain == "RunMonitor")
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

    do {
        _ = try RunMonitor(
            runID: "run", metricsURL: root.appending(path: "metrics.json"),
            thermalURL: alias.appending(path: "metrics.json"),
            memoryURL: root.appending(path: "memory.json")
        )
        Issue.record("symlink alias must be rejected")
    } catch {
        #expect((error as NSError).domain == "RunMonitor")
    }
}
