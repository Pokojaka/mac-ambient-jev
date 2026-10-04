import Foundation
import MacAmbientJevCapture
import MacAmbientJevCore
import MacAmbientJevRuntime

enum CaptureSystemAudioError: LocalizedError, Equatable {
    case usage
    case unsafeSessionsRoot
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: MacAmbientJevCaptureSystemAudio --duration SECONDS --sessions-root DIRECTORY [--transcribe] [--ready-file PATH]"
        case .unsafeSessionsRoot:
            "--sessions-root must be an explicit directory outside the real app data root"
        case .transcriptionFailed(let message):
            "Offline transcription failed: \(message)"
        }
    }
}

struct CaptureSystemAudioOptions {
    let duration: Double
    let sessionsRoot: URL
    let transcribe: Bool
    let readyFile: URL?

    static func parse(
        _ arguments: [String],
        appPaths: AppPaths
    ) throws -> CaptureSystemAudioOptions {
        var duration: Double?
        var root: URL?
        var transcribe = false
        var readyFile: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                guard duration == nil, index + 1 < arguments.count,
                      let seconds = Double(arguments[index + 1]),
                      seconds.isFinite, seconds > 0,
                      seconds < Double(Int64.max / 1_000_000_000) else {
                    throw CaptureSystemAudioError.usage
                }
                duration = seconds
                index += 2
            case "--sessions-root":
                guard root == nil, index + 1 < arguments.count,
                      !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("-") else {
                    throw CaptureSystemAudioError.usage
                }
                root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                    .standardizedFileURL
                index += 2
            case "--ready-file":
                guard readyFile == nil, index + 1 < arguments.count,
                      !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("-") else {
                    throw CaptureSystemAudioError.usage
                }
                readyFile = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                index += 2
            case "--transcribe":
                guard !transcribe else { throw CaptureSystemAudioError.usage }
                transcribe = true
                index += 1
            default:
                throw CaptureSystemAudioError.usage
            }
        }
        guard let duration, let root else { throw CaptureSystemAudioError.usage }

        let selected: URL
        do {
            selected = try SessionsRootPolicy.validated(
                root, protectedRoots: appPaths.protectedSessionsRoots, fileManager: .default
            )
        } catch {
            throw CaptureSystemAudioError.unsafeSessionsRoot
        }
        return CaptureSystemAudioOptions(
            duration: duration, sessionsRoot: selected, transcribe: transcribe,
            readyFile: readyFile
        )
    }

}

private struct CaptureSummary: Encodable {
    let sessionID: String?
    let sessionPath: String?
    let frames: Int64?
    let sampleRate: Double?
    let dropoutCount: UInt64?
    let gapCount: Int?
    let totalGapFrames: Int64?
    let sleepAssertionHeld: Bool?
    let permission: String?
    let errors: [String]
    let transcribed: Bool?
    let transcriptText: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionPath = "path"
        case frames = "frames_written"
        case sampleRate = "sample_rate"
        case dropoutCount = "dropout_count"
        case gapCount = "gap_count"
        case totalGapFrames = "total_gap_frames"
        case sleepAssertionHeld = "sleep_assertion_held"
        case permission
        case errors
        case transcribed
        case transcriptText = "transcript_text"
    }

    static func empty(error: Error) -> CaptureSummary {
        CaptureSummary(
            sessionID: nil, sessionPath: nil, frames: nil, sampleRate: nil,
            dropoutCount: nil, gapCount: nil, totalGapFrames: nil,
            sleepAssertionHeld: nil, permission: nil,
            errors: [error.localizedDescription], transcribed: nil, transcriptText: nil
        )
    }
}

@MainActor
private final class CaptureFailureLog {
    private(set) var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
}

@main
struct CaptureSystemAudioCommand {
    @MainActor
    static func main() async {
        do {
            let options = try CaptureSystemAudioOptions.parse(
                Array(CommandLine.arguments.dropFirst()), appPaths: try AppPaths.systemDefault(fileManager: .default)
            )
            let summary = try await run(options)
            if !emit(summary) || !summary.errors.isEmpty { exit(1) }
        } catch {
            emit(.empty(error: error))
            if case CaptureSystemAudioError.usage = error { exit(2) }
            exit(1)
        }
    }

    @MainActor
    private static func run(_ options: CaptureSystemAudioOptions) async throws -> CaptureSummary {
        let defaults = try AppPaths.systemDefault(fileManager: .default)
        let paths = AppPaths(
            applicationSupportURL: defaults.applicationSupportURL,
            cacheURL: defaults.cacheURL,
            sessionsRootOverride: options.sessionsRoot
        )
        let sessionID = UUID()
        let sessionURL = try SessionBootstrapper(fileManager: .default).createSession(
            paths: paths, sessionID: sessionID, source: .recording(.systemAudio),
            createdAt: Date(), timeZone: .current
        )
        let failures = CaptureFailureLog()
        let engine = AudioCaptureEngine(paths: paths)
        var result: AudioCaptureStopResult?
        var errors: [String] = []
        do {
            try await engine.start(
                sessionID: sessionID, source: .systemAudio,
                onFailure: { failures.record($0) },
                onWarning: { _ in },
                onPermissionWaiting: {},
                onDropouts: { _ in },
                onSilenceChanged: { _ in }
            )
            if let readyFile = options.readyFile {
                try Data().write(to: readyFile, options: .atomic)
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(options.duration))
            while clock.now < deadline {
                if !failures.messages.isEmpty { break }
                try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(250)), deadline))
            }
            result = try await engine.stop()
        } catch {
            errors = failures.messages
            if !errors.contains(error.localizedDescription) {
                errors.append(error.localizedDescription)
            }
            if engine.isRecording {
                do {
                    result = try await engine.stop()
                } catch {
                    if !errors.contains(error.localizedDescription) {
                        errors.append(error.localizedDescription)
                    }
                }
            }
        }

        for failure in failures.messages where !errors.contains(failure) {
            errors.append(failure)
        }
        if let writerFailure = result?.writerFailure, !errors.contains(writerFailure) {
            errors.append(writerFailure)
        }
        if let releaseFailure = result?.systemAudioReleaseFailure {
            errors.append(releaseFailure)
        }
        if result?.didOverflow == true {
            errors.append("Audio input was lost during capture")
        }
        var transcriptText: String?
        if options.transcribe, let result, errors.isEmpty {
            let processor = NativeSessionProcessor(
                paths: paths, engines: .production(paths: paths), contentPriority: .disabled
            )
            let processing = await processor.processSession(
                sessionID: sessionID,
                source: .recordedPCM(result.checkpoint),
                pacingMode: .normal,
                shouldPause: { ProcessInfo.processInfo.thermalState == .critical },
                onPhase: { _ in },
                metadataPolicy: .reject,
                onStatus: { _ in },
                onUpdate: { _, _ in }
            )
            if processing.disposition == .completed {
                do {
                    transcriptText = try loadTranscriptText(
                        sessionURL: sessionURL, sampleRate: result.checkpoint.sampleRate
                    )
                } catch {
                    errors.append(error.localizedDescription)
                }
            } else {
                errors.append(CaptureSystemAudioError.transcriptionFailed(
                    processing.message ?? processing.disposition.rawValue
                ).localizedDescription)
            }
        }
        let permission: String?
        switch engine.systemAudioPermissionResult {
        case .authorized: permission = "authorized"
        case .grantedNow: permission = "granted-now"
        case nil: permission = nil
        }
        return CaptureSummary(
            sessionID: sessionID.uuidString, sessionPath: sessionURL.path,
            frames: result?.checkpoint.committedFrames,
            sampleRate: result?.checkpoint.sampleRate,
            dropoutCount: result?.dropoutCount,
            gapCount: result?.gapCount,
            totalGapFrames: result?.totalGapFrames,
            sleepAssertionHeld: result?.sleepAssertionHeld,
            permission: permission, errors: errors,
            transcribed: options.transcribe ? errors.isEmpty : nil,
            transcriptText: transcriptText
        )
    }

    private static func loadTranscriptText(sessionURL: URL, sampleRate: Double) throws -> String {
        guard let runs = try ProcessingMetadataStore(sessionURL: sessionURL).load()?.activeRuns,
              runs.scope != nil else {
            throw CaptureSystemAudioError.transcriptionFailed("Completed transcript runs are missing")
        }
        let recovered = try SessionRecovery.recoverJSONL(
            Data(contentsOf: sessionURL.appending(path: "events.jsonl"))
        )
        guard !recovered.droppedIncompleteTail else {
            throw CaptureSystemAudioError.transcriptionFailed("Transcript event log has an incomplete tail")
        }
        let events = try EventLogTranscriptReader().events(
            lines: recovered.lines, activeRuns: runs
        )
        return TranscriptMaterializer(sampleRate: sampleRate)
            .materialize(events: events, activeRuns: runs)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @discardableResult
    private static func emit(_ summary: CaptureSummary) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            FileHandle.standardOutput.write(try encoder.encode(summary) + Data([0x0A]))
            return true
        } catch {
            FileHandle.standardOutput.write(
                Data(#"{"errors":["Failed to encode capture summary"]}"#.utf8) + Data([0x0A])
            )
            return false
        }
    }
}
