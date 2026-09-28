import Foundation

public enum ASREngineState: Sendable, Equatable {
    case stopped
    case loadingModel
    case ready
    case transcribing(segmentID: String)
    case failed(message: String)
}

public struct ASRResult: Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?

    public init(text: String, detectedLanguage: String? = nil) {
        self.text = text
        self.detectedLanguage = detectedLanguage
    }
}

public struct ASRAudioInput: Sendable, Equatable {
    public static let minimumDurationSeconds = 0.02

    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var isShorterThanMinimumASRDuration: Bool {
        sampleRate > 0
            && samples.count < Int((Self.minimumDurationSeconds * Double(sampleRate)).rounded())
    }
}

public protocol ASREngine: Sendable {
    func prepare() async throws
    func prepare(onProgress: @escaping @Sendable (Double, String) -> Void) async throws
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult
    func unload() async
}

public extension ASREngine {
    func prepare(onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        try await prepare()
    }
}

public struct ModelStore: Sendable {
    public static let qwen3ASRModelID = "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public var qwen3ASRCacheRoot: URL {
        paths.modelsRoot.appending(
            path: "qwen3-asr-1.7b-mlx-8bit",
            directoryHint: .isDirectory
        )
    }

    public func prepareQwen3ASRDirectory() throws -> URL {
        let url = qwen3ASRCacheRoot
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public struct ASRAudioLoader: Sendable {
    public let reader: ProcessingTimelineReader

    public init(reader: ProcessingTimelineReader) {
        self.reader = reader
    }

    public func load(segment: SegmentReference) throws -> ASRAudioInput {
        guard segment.startFrame <= segment.endFrame else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        let interleaved = try reader.readSamples(
            frameRange: segment.startFrame..<segment.endFrame
        )
        let channels = reader.checkpoint.channelCount
        let mono: [Float]

        if channels == 1 {
            mono = interleaved
        } else {
            let frameCount = interleaved.count / channels
            var result = Array(repeating: Float.zero, count: frameCount)

            for frame in 0..<frameCount {
                let base = frame * channels
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved[base + channel]
                }
                result[frame] = sum / Float(channels)
            }
            mono = result
        }

        return ASRAudioInput(
            samples: mono,
            sampleRate: Int(reader.checkpoint.sampleRate.rounded())
        )
    }
}
