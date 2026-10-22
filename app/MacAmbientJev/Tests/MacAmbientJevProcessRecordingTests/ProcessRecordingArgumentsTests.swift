import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevProcessRecording

private func temporaryPath(_ name: String = "path") -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "ProcessRecordingArgumentsTests-\(UUID().uuidString)")
        .appending(path: name)
        .path
}

private func importArguments(root: String, audio: String) -> [String] {
    ["--sessions-root", root, audio]
}

private func measurementArguments(under directory: String) -> [String] {
    [
        "--run-id", "run-1",
        "--metrics-output", URL(fileURLWithPath: directory).appending(path: "metrics.json").path,
        "--thermal-output", URL(fileURLWithPath: directory).appending(path: "thermal.jsonl").path,
        "--memory-output", URL(fileURLWithPath: directory).appending(path: "memory.jsonl").path,
    ]
}

private func parse(
    _ arguments: [String],
    platform: ProcessRecordingPlatform,
    logicalCPUCount: Int = 8
) throws -> ProcessRecordingInvocation {
    try ProcessRecordingCommand.parseCommandLine(
        arguments,
        platform: platform,
        logicalCPUCount: logicalCPUCount
    )
}

@Test
func macOSAcceptsCompleteMeasurementOptionsForImportAndResume() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("recordings/input.wav")
    let measurement = measurementArguments(under: temporaryPath("measurements"))

    let imported = try parse(
        measurement + importArguments(root: root, audio: audio),
        platform: .macOS
    )
    guard case .importFile = imported.input else {
        Issue.record("complete measurements should be accepted for import")
        return
    }
    #expect(imported.measurement?.runID == "run-1")

    let id = UUID()
    let resumeOutput = temporaryPath("resumed.json")
    let resumed = try parse(
        measurement + [
            "--resume-session", id.uuidString,
            "--sessions-root", root,
            resumeOutput,
        ],
        platform: .macOS
    )
    guard case let .resume(sessionID, _, output, _) = resumed.input else {
        Issue.record("complete measurements should be accepted for resume")
        return
    }
    #expect(sessionID == id)
    #expect(output.path == URL(fileURLWithPath: resumeOutput).standardizedFileURL.path)
}

@Test
func macOSRejectsThreads() throws {
    let args = ["--threads", "1"] + importArguments(root: temporaryPath("sessions"), audio: temporaryPath("input.wav"))
    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(args, platform: .macOS)
    }
}

@Test
func portableImportAndResumeRequireBoundedPositiveThreads() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("input.wav")
    let id = UUID().uuidString
    for operation in [
        importArguments(root: root, audio: audio),
        ["--resume-session", id, "--sessions-root", root, temporaryPath("output.json")],
    ] {
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(operation, platform: .portable, logicalCPUCount: 8)
        }
    }

    for cpuCount in [1, 2, 6] {
        for threads in 1...min(4, cpuCount) {
            let importCommand = ["--threads", String(threads)] + importArguments(root: root, audio: audio)
            let resumeCommand = ["--threads", String(threads), "--resume-session", id,
                                 "--sessions-root", root, temporaryPath("output.json")]
            #expect(try parse(importCommand, platform: .portable, logicalCPUCount: cpuCount).threads == threads)
            #expect(try parse(resumeCommand, platform: .portable, logicalCPUCount: cpuCount).threads == threads)
        }
    }

    for invalid in ["0", "-1", "+1", "１", " 1", "1 ", "1.0", String(Int.max) + "0", "5"] {
        let args = ["--threads", invalid] + importArguments(root: root, audio: audio)
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(args, platform: .portable, logicalCPUCount: 8)
        }
    }
    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(["--threads", "1"] + importArguments(root: root, audio: audio),
                      platform: .portable, logicalCPUCount: 0)
    }
}

@Test
func portableRejectsMeasurementOptionsWithoutFilesystemSideEffects() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("input.wav")
    let measurement = measurementArguments(under: temporaryPath("measurement-output"))
    let optionNames = ["--run-id", "--metrics-output", "--thermal-output", "--memory-output"]
    for option in optionNames {
        let optionIndex = measurement.firstIndex(of: option)!
        let standalone = [option, measurement[optionIndex + 1]]
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(["--threads", "1"] + standalone + importArguments(root: root, audio: audio),
                          platform: .portable)
        }
        #expect(!FileManager.default.fileExists(atPath: root))

        let index = optionIndex
        var partialMeasurement = Array(measurement[..<index])
        partialMeasurement += Array(measurement[(index + 2)...])
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(["--threads", "1"] + partialMeasurement + importArguments(root: root, audio: audio),
                          platform: .portable)
        }
        #expect(!FileManager.default.fileExists(atPath: root))
    }
    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(["--threads", "1"] + measurement + importArguments(root: root, audio: audio),
                      platform: .portable)
    }
    #expect(!FileManager.default.fileExists(atPath: root))
}

@Test
func inspectAcceptsWithoutProcessingOptionsAndRejectsDisallowedOptions() throws {
    let root = temporaryPath("sessions")
    let id = UUID().uuidString
    let inspect = ["--inspect-session", id, "--sessions-root", root]
    for platform in [ProcessRecordingPlatform.macOS, .portable] {
        let invocation = try parse(inspect, platform: platform, logicalCPUCount: 0)
        guard case let .inspect(sessionID, _) = invocation.input else {
            Issue.record("inspect command should parse without processing")
            continue
        }
        #expect(sessionID.uuidString.lowercased() == id.lowercased())
        #expect(invocation.threads == nil)
        #expect(invocation.measurement == nil)

        for disallowed in [
            ["--threads", "1"],
            ["--with-decisions"],
            ["--low-heat"],
            ["--keep-session"],
            measurementArguments(under: temporaryPath("inspect-measurement")),
            [temporaryPath("unexpected.wav")],
        ] {
            #expect(throws: ProcessRecordingError.self) {
                _ = try parse(inspect + disallowed, platform: platform)
            }
        }
    }
}

@Test
func decisionsAndImportFlagsArePreservedOnBothPlatforms() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("nested/input.wav")
    for platform in [ProcessRecordingPlatform.macOS, .portable] {
        let threadArgument = platform == .portable ? ["--threads", "2"] : []
        let invocation = try parse(
            threadArgument + ["--with-decisions", "--keep-session", "--low-heat"]
                + importArguments(root: root, audio: audio),
            platform: platform,
            logicalCPUCount: 2
        )
        #expect(invocation.withDecisions)
        guard case let .importFile(parsedAudio, output, parsedRoot, keepSession, pacing) = invocation.input else {
            Issue.record("expected import input")
            continue
        }
        #expect(parsedAudio.path == URL(fileURLWithPath: audio).standardizedFileURL.path)
        #expect(output.path == URL(fileURLWithPath: audio).deletingLastPathComponent()
            .appending(path: "segments.json").standardizedFileURL.path)
        #expect(parsedRoot.path == URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path)
        #expect(keepSession)
        #expect(pacing == .lowHeat)

        let decisionOnly = try parse(
            threadArgument + ["--with-decisions"] + importArguments(root: root, audio: audio),
            platform: platform,
            logicalCPUCount: 2
        )
        #expect(decisionOnly.withDecisions)
    }

    let resumeRoot = temporaryPath("resume-sessions")
    let resumeID = UUID()
    let resumeOutput = temporaryPath("parent/result.json")
    for platform in [ProcessRecordingPlatform.macOS, .portable] {
        let threads = platform == .portable ? ["--threads", "1"] : []
        let resumed = try parse(
            threads + ["--low-heat", "--resume-session", resumeID.uuidString,
                       "--sessions-root", resumeRoot, resumeOutput],
            platform: platform
        )
        guard case let .resume(_, _, output, pacing) = resumed.input else {
            Issue.record("expected resume input")
            continue
        }
        #expect(output.path == URL(fileURLWithPath: resumeOutput).standardizedFileURL.path)
        #expect(pacing == .lowHeat)
    }
}

@Test
func duplicateFlagsOptionsAndUnknownFlagsAreRejected() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("input.wav")
    let ordinary = importArguments(root: root, audio: audio)
    let measurement = measurementArguments(under: temporaryPath("measurements"))
    let duplicateCases: [[String]] = [
        ["--with-decisions", "--with-decisions"],
        ["--keep-session", "--keep-session"],
        ["--low-heat", "--low-heat"],
        ["--threads", "1", "--threads", "1"],
        ["--run-id", "run-a", "--run-id", "run-b"] + Array(measurement.dropFirst(2)),
        ["--metrics-output", temporaryPath("metrics-a.json"), "--metrics-output", temporaryPath("metrics-b.json"),
         "--run-id", "run", "--thermal-output", temporaryPath("thermal.jsonl"),
         "--memory-output", temporaryPath("memory.jsonl")],
        ["--thermal-output", temporaryPath("thermal-a.jsonl"), "--thermal-output", temporaryPath("thermal-b.jsonl"),
         "--run-id", "run", "--metrics-output", temporaryPath("metrics.json"),
         "--memory-output", temporaryPath("memory.jsonl")],
        ["--memory-output", temporaryPath("memory-a.jsonl"), "--memory-output", temporaryPath("memory-b.jsonl"),
         "--run-id", "run", "--metrics-output", temporaryPath("metrics.json"),
         "--thermal-output", temporaryPath("thermal.jsonl")],
        ["--sessions-root", root, "--sessions-root", root],
        ["--resume-session", UUID().uuidString, "--resume-session", UUID().uuidString,
         "--sessions-root", root, temporaryPath("output.json")],
        ["--inspect-session", UUID().uuidString, "--inspect-session", UUID().uuidString,
         "--sessions-root", root],
    ]
    for duplicate in duplicateCases {
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(duplicate + ordinary, platform: .macOS)
        }
    }
    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(["--unknown-flag"] + ordinary, platform: .macOS)
    }
}

@Test
func missingInvalidAndEmptyValuesAndPositionalsAreRejected() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("input.wav")
    let ordinary = importArguments(root: root, audio: audio)
    let valueOptions = [
        "--threads", "--run-id", "--metrics-output", "--thermal-output", "--memory-output",
        "--sessions-root", "--resume-session", "--inspect-session",
    ]
    for option in valueOptions {
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(ordinary + [option], platform: .macOS)
        }
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(ordinary + [option, ""], platform: .macOS)
        }
        #expect(throws: ProcessRecordingError.self) {
            _ = try ProcessRecordingCommand.parseInput(
                ordinary + [option, "--keep-session", audio], measured: false
            )
        }
    }

    for args in [
        ["--sessions-root", "", audio],
        ["--sessions-root", root, ""],
        ["--sessions-root", root, audio, ""],
        ["--resume-session", "not-a-uuid", "--sessions-root", root, temporaryPath("output.json")],
        ["--resume-session", UUID().uuidString, "--sessions-root", root],
        ["--resume-session", UUID().uuidString, "--sessions-root", root, ""],
        ["--inspect-session", "not-a-uuid", "--sessions-root", root],
        ["--run-id", "run/with/slash"] + measurementArguments(under: temporaryPath("measurements")).dropFirst(2)
            + ordinary,
        ["--run-id", "run", "--metrics-output", "", "--thermal-output", temporaryPath("thermal.jsonl"),
         "--memory-output", temporaryPath("memory.jsonl")] + ordinary,
    ] {
        #expect(throws: ProcessRecordingError.self) {
            _ = try parse(args, platform: .macOS)
        }
    }

    #expect(throws: ProcessRecordingError.self) {
        _ = try ProcessRecordingCommand.parseInput(
            ["--sessions-root", root, "--resume-session", UUID().uuidString], measured: false
        )
    }
}

@Test
func malformedOptionsCannotBeHealedByRemovingFlags() throws {
    let root = temporaryPath("sessions")
    let audio = temporaryPath("input.wav")

    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(
            ["--threads", "--with-decisions", "2", "--sessions-root", root, audio],
            platform: .portable,
            logicalCPUCount: 8
        )
    }
    #expect(throws: ProcessRecordingError.self) {
        _ = try parse(
            ["--sessions-root", "--keep-session", root, audio],
            platform: .macOS
        )
    }
    #expect(throws: ProcessRecordingError.self) {
        _ = try ProcessRecordingCommand.parseInput(
            ["--sessions-root", "--keep-session", root, audio], measured: false
        )
    }
}
