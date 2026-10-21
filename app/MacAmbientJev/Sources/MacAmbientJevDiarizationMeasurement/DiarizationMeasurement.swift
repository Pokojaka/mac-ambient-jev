import Foundation
import MacAmbientJevCore
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DiarizationMeasurementError: Error, LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The options of a measurement command: `--audio`, one model option, optionally `--threads`, and `--output`.
/// Each is required exactly once; nothing has a default.
public struct DiarizationMeasurementArguments: Sendable, Equatable {
    public let audioURL: URL
    public let modelDirectory: URL
    public let threads: Int?
    public let outputURL: URL

    public static func parse(
        _ arguments: [String],
        modelOption: String,
        requiresThreads: Bool
    ) throws -> Self {
        var options = ["--audio", modelOption, "--output"]
        if requiresThreads { options.append("--threads") }

        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard options.contains(option) else {
                throw DiarizationMeasurementError("不明なオプションまたは余分な引数です: \(option)")
            }
            guard values[option] == nil else {
                throw DiarizationMeasurementError("オプションを重複して指定できません: \(option)")
            }
            guard index + 1 < arguments.count, !arguments[index + 1].isEmpty, !options.contains(arguments[index + 1]) else {
                throw DiarizationMeasurementError("\(option) の値がありません。")
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        for option in options where values[option] == nil {
            throw DiarizationMeasurementError("必須オプションがありません: \(option)")
        }

        var threads: Int?
        if requiresThreads {
            guard let value = values["--threads"], let parsed = Int(value), parsed > 0, Int32(exactly: parsed) != nil else {
                throw DiarizationMeasurementError("--threads は 1 以上 Int32.max 以下の整数で指定してください。")
            }
            threads = parsed
        }

        let audioURL = canonical(values["--audio"]!)
        let modelDirectory = canonical(values[modelOption]!)
        let outputURL = canonical(values["--output"]!)
        try requireType(.typeRegular, at: audioURL, description: "入力音声ファイル")
        try requireType(.typeDirectory, at: modelDirectory, description: "モデルディレクトリ")
        try requireType(.typeDirectory, at: outputURL.deletingLastPathComponent(), description: "出力先ディレクトリ")
        guard audioURL.path != outputURL.path else {
            throw DiarizationMeasurementError("出力ファイルが入力音声ファイルと同じです: \(outputURL.path)")
        }
        if (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) != nil {
            throw DiarizationMeasurementError("出力先は既に存在します: \(outputURL.path)")
        }
        return Self(audioURL: audioURL, modelDirectory: modelDirectory, threads: threads, outputURL: outputURL)
    }

    private static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func requireType(_ type: FileAttributeType, at url: URL, description: String) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw DiarizationMeasurementError("\(description)の情報を取得できません (\(url.path)): \(error.localizedDescription)")
        }
        guard attributes[.type] as? FileAttributeType == type else {
            throw DiarizationMeasurementError("\(description)の種類が不正です: \(url.path)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw DiarizationMeasurementError("\(description)を読み取れません: \(url.path)")
        }
    }
}

/// One diarization run in the schema shared by the portable CLI and the Mac oracle.
public struct DiarizationMeasurementRun: Encodable, Sendable {
    public struct Audio: Encodable, Sendable {
        public let sha256: String
        public let sampleCount: Int64
        public let sampleRate: Int

        enum CodingKeys: String, CodingKey {
            case sha256
            case sampleCount = "sample_count"
            case sampleRate = "sample_rate"
        }
    }

    public struct Span: Encodable, Sendable {
        public let speakerID: String
        public let startFrame: Int64
        public let endFrame: Int64
        public let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case speakerID = "speaker_id"
            case startFrame = "start_frame"
            case endFrame = "end_frame"
            case confidence
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(speakerID, forKey: .speakerID)
            try container.encode(startFrame, forKey: .startFrame)
            try container.encode(endFrame, forKey: .endFrame)
            try container.encode(confidence, forKey: .confidence)
        }
    }

    public let schemaVersion = 1
    public let audio: Audio
    public let provenance: RunProvenance
    public let rawSpans: [Span]
    public let rawSpeakerCount: Int
    public let prepareSeconds: Double
    public let wallTimeSeconds: Double
    public let peakRSSBytes: UInt64

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case audio
        case provenance
        case rawSpans = "raw_spans"
        case rawSpeakerCount = "raw_speaker_count"
        case prepareSeconds = "prepare_seconds"
        case wallTimeSeconds = "wall_time_seconds"
        case peakRSSBytes = "peak_rss_bytes"
    }

    /// Loads the engine, diarizes the canonical CAF once and returns the timed run.
    public static func measure(engine: some DiarizationEngine, audioURL: URL) async throws -> Self {
        let sessionURL = audioURL.deletingLastPathComponent()
        let sampleCount = try CanonicalCAFReader(url: audioURL, sessionURL: sessionURL).sampleCount
        guard sampleCount > 0 else {
            throw DiarizationMeasurementError("入力音声にサンプルがありません: \(audioURL.path)")
        }
        let digest = try FileSHA256.hexDigest(ofFileAt: audioURL)

        let prepareStart = DispatchTime.now().uptimeNanoseconds
        try await engine.prepare()
        let diarizeStart = DispatchTime.now().uptimeNanoseconds
        let spans = try await engine.diarize(
            fileURL: audioURL,
            canonicalSampleRate: CanonicalAudio.sampleRate,
            sessionURL: sessionURL
        )
        let end = DispatchTime.now().uptimeNanoseconds
        await engine.unload()

        for (index, span) in spans.enumerated() {
            guard !span.speakerID.isEmpty, span.startFrame >= 0, span.startFrame < span.endFrame, span.endFrame <= sampleCount else {
                throw DiarizationMeasurementError("生の区間 \(index) が不正です: \(span.speakerID) \(span.startFrame)..<\(span.endFrame) (サンプル数 \(sampleCount))")
            }
        }
        return Self(
            audio: Audio(sha256: digest, sampleCount: sampleCount, sampleRate: Int(CanonicalAudio.sampleRate)),
            provenance: engine.provenance,
            rawSpans: spans.map {
                Span(speakerID: $0.speakerID, startFrame: $0.startFrame, endFrame: $0.endFrame, confidence: $0.confidence)
            },
            rawSpeakerCount: Set(spans.map(\.speakerID)).count,
            prepareSeconds: Double(diarizeStart - prepareStart) / 1e9,
            wallTimeSeconds: Double(end - diarizeStart) / 1e9,
            peakRSSBytes: try peakRSSBytes()
        )
    }

    /// Writes the JSON to a file that must not exist yet; an existing file is never replaced.
    public func writeNew(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self) + Data([0x0A])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            // moveItem fails when the destination exists, so a finished file is never replaced.
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw DiarizationMeasurementError("計測結果を書き込めません (\(url.path)): \(error.localizedDescription)")
        }
    }

    /// Peak resident set size of this process in bytes.
    public static func peakRSSBytes() throws -> UInt64 {
        #if os(Windows)
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        guard K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) else {
            throw DiarizationMeasurementError("ピークメモリを取得できません (Windows error \(GetLastError()))。")
        }
        return UInt64(counters.PeakWorkingSetSize)
        #else
        var usage = rusage()
        #if os(Linux)
        let status = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)  // Glibc imports RUSAGE_SELF as an enum case.
        #else
        let status = getrusage(RUSAGE_SELF, &usage)
        #endif
        guard status == 0, usage.ru_maxrss > 0 else {
            throw DiarizationMeasurementError("ピークメモリを取得できません (getrusage)。")
        }
        #if os(Linux)
        return UInt64(usage.ru_maxrss) * 1024  // Linux reports KiB; macOS reports bytes.
        #else
        return UInt64(usage.ru_maxrss)
        #endif
        #endif
    }
}
