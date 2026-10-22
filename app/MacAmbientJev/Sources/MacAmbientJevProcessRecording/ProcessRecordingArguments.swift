import Foundation
import MacAmbientJevCore

enum ProcessRecordingError: LocalizedError, Sendable {
    case invalidArguments
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "引数が不正です。使い方とプラットフォーム別の必須・禁止オプションを確認してください"
        case .processingFailed(let message):
            "録音データの処理に失敗しました: \(message)"
        }
    }
}

enum RecordingInput: Sendable {
    case importFile(audio: URL, output: URL, root: URL, keepSession: Bool, pacing: ASRPacingMode)
    case inspect(sessionID: UUID, root: URL)
    case resume(sessionID: UUID, root: URL, output: URL, pacing: ASRPacingMode)
}

enum ProcessRecordingPlatform: Sendable, Equatable {
    case macOS
    case portable

    static var current: Self {
        #if os(macOS)
        .macOS
        #else
        .portable
        #endif
    }
}

struct ProcessRecordingMeasurement: Sendable {
    let runID: String
    let metricsPath: String
    let thermalPath: String
    let memoryPath: String
}

struct ProcessRecordingInvocation: Sendable {
    let input: RecordingInput
    let measurement: ProcessRecordingMeasurement?
    let withDecisions: Bool
    let threads: Int?
}

extension ProcessRecordingCommand {
    static func parseCommandLine(
        _ originalArguments: [String],
        platform: ProcessRecordingPlatform,
        logicalCPUCount: Int
    ) throws -> ProcessRecordingInvocation {
        try validateValueOptions(in: originalArguments)
        var arguments = originalArguments
        let withDecisions = try removeFlag("--with-decisions", from: &arguments)
        let rawThreads = try removeOption("--threads", from: &arguments)
        let threads = try rawThreads.map(parseThreads)
        let runID = try removeOption("--run-id", from: &arguments)
        let metricsPath = try removeOption("--metrics-output", from: &arguments)
        let thermalPath = try removeOption("--thermal-output", from: &arguments)
        let memoryPath = try removeOption("--memory-output", from: &arguments)
        let providedMeasurementValues = [runID, metricsPath, thermalPath, memoryPath].compactMap { $0 }
        guard providedMeasurementValues.isEmpty || providedMeasurementValues.count == 4 else {
            throw ProcessRecordingError.invalidArguments
        }
        if let runID {
            guard !runID.isEmpty, !runID.contains("/"), !runID.contains("\\") else {
                throw ProcessRecordingError.invalidArguments
            }
        }
        let measurement: ProcessRecordingMeasurement?
        if let runID, let metricsPath, let thermalPath, let memoryPath {
            guard !metricsPath.isEmpty, !thermalPath.isEmpty, !memoryPath.isEmpty else {
                throw ProcessRecordingError.invalidArguments
            }
            measurement = ProcessRecordingMeasurement(
                runID: runID,
                metricsPath: metricsPath,
                thermalPath: thermalPath,
                memoryPath: memoryPath
            )
        } else {
            measurement = nil
        }

        let input = try parseInput(arguments, measured: measurement != nil)
        if case .inspect = input {
            guard !withDecisions, threads == nil else {
                throw ProcessRecordingError.invalidArguments
            }
        }
        switch platform {
        case .macOS:
            guard threads == nil else { throw ProcessRecordingError.invalidArguments }
        case .portable:
            guard measurement == nil else { throw ProcessRecordingError.invalidArguments }
            switch input {
            case .inspect:
                break
            case .importFile, .resume:
                guard logicalCPUCount > 0,
                      let threads,
                      threads >= 1,
                      threads <= min(4, logicalCPUCount) else {
                    throw ProcessRecordingError.invalidArguments
                }
            }
        }
        return ProcessRecordingInvocation(
            input: input,
            measurement: measurement,
            withDecisions: withDecisions,
            threads: threads
        )
    }

    static func parseInput(_ originalArguments: [String], measured: Bool) throws -> RecordingInput {
        try validateValueOptions(in: originalArguments)
        var arguments = originalArguments
        let keepSession = try removeFlag("--keep-session", from: &arguments)
        let hasLowHeat = try removeFlag("--low-heat", from: &arguments)
        let pacingMode: ASRPacingMode = hasLowHeat ? .lowHeat : .normal
        let resumeID = try removeOption("--resume-session", from: &arguments)
        let inspectID = try removeOption("--inspect-session", from: &arguments)
        let rootPath = try removeOption("--sessions-root", from: &arguments)
        guard let rootPath, !rootPath.isEmpty else { throw ProcessRecordingError.invalidArguments }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard !arguments.contains(where: { $0.hasPrefix("--") }) else {
            throw ProcessRecordingError.invalidArguments
        }
        if resumeID != nil || inspectID != nil {
            guard (resumeID == nil) != (inspectID == nil),
                  !keepSession,
                  let id = UUID(uuidString: resumeID ?? inspectID ?? "") else {
                throw ProcessRecordingError.invalidArguments
            }
            if inspectID != nil {
                guard !measured, !hasLowHeat, arguments.isEmpty else {
                    throw ProcessRecordingError.invalidArguments
                }
                return .inspect(sessionID: id, root: root)
            }
            guard arguments.count == 1, !arguments[0].isEmpty else {
                throw ProcessRecordingError.invalidArguments
            }
            let output = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            return .resume(sessionID: id, root: root, output: output, pacing: pacingMode)
        }
        guard (arguments.count == 1 || arguments.count == 2),
              !arguments[0].isEmpty,
              arguments.count == 1 || !arguments[1].isEmpty else {
            throw ProcessRecordingError.invalidArguments
        }
        let audioURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let outputURL = arguments.count == 2
            ? URL(fileURLWithPath: arguments[1]).standardizedFileURL
            : audioURL.deletingLastPathComponent().appending(path: "segments.json")
        guard !sameResolvedPath(audioURL, outputURL) else {
            throw ProcessRecordingError.invalidArguments
        }
        return .importFile(
            audio: audioURL,
            output: outputURL,
            root: root,
            keepSession: keepSession,
            pacing: pacingMode
        )
    }

    private static func validateValueOptions(in arguments: [String]) throws {
        let valueOptions: Set<String> = [
            "--threads",
            "--run-id",
            "--metrics-output",
            "--thermal-output",
            "--memory-output",
            "--sessions-root",
            "--resume-session",
            "--inspect-session",
        ]
        for (index, argument) in arguments.enumerated() where valueOptions.contains(argument) {
            guard index + 1 < arguments.count,
                  !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--") else {
                throw ProcessRecordingError.invalidArguments
            }
        }
    }

    private static func removeOption(_ option: String, from arguments: inout [String]) throws -> String? {
        let matches = arguments.indices.filter { arguments[$0] == option }
        guard matches.count <= 1 else { throw ProcessRecordingError.invalidArguments }
        guard let index = matches.first else { return nil }
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
            throw ProcessRecordingError.invalidArguments
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func removeFlag(_ flag: String, from arguments: inout [String]) throws -> Bool {
        let matches = arguments.indices.filter { arguments[$0] == flag }
        guard matches.count <= 1 else { throw ProcessRecordingError.invalidArguments }
        guard let index = matches.first else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func parseThreads(_ rawValue: String) throws -> Int {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ (48...57).contains($0) }),
              let value = Int(rawValue), value > 0 else {
            throw ProcessRecordingError.invalidArguments
        }
        return value
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
            == rhs.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map { $0.lowercased() }
    }
}
