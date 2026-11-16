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

    public init(text: String, detectedLanguage: String?) {
        self.text = text
        self.detectedLanguage = detectedLanguage
    }
}

public struct ASRAudioInput: Sendable, Equatable {
    public static let minimumDurationSeconds = 0.02
    public static let maximumDurationSeconds = 30.0

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
    var provenance: RunProvenance { get }
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

public struct ASRAudioLoader: Sendable {
    public let reader: any TimelineAudioReading

    public init(reader: any TimelineAudioReading) {
        self.reader = reader
    }

    public func load(segment: SegmentReference) throws -> ASRAudioInput {
        var samples: [Float] = []
        samples.reserveCapacity(segment.speechRanges.reduce(0) { $0 + Int($1.count) })
        for range in segment.speechRanges {
            samples.append(contentsOf: try reader.readSamples(frameRange: range))
        }
        return ASRAudioInput(samples: samples, sampleRate: Int(CanonicalAudio.sampleRate))
    }
}
