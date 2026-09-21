import Foundation

public enum PCMSampleFormat: String, Codable, Sendable, Equatable {
    case float32LE
}

public struct ProcessingTimeline: Codable, Sendable, Equatable {
    public let version: Int
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleFormat: PCMSampleFormat

    public init(
        version: Int = 1,
        sampleRate: Double,
        channelCount: Int,
        sampleFormat: PCMSampleFormat
    ) {
        self.version = version
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
    }

    public func milliseconds(forFrame frame: Int64) -> Int64 {
        Int64((Double(frame) * 1_000.0 / sampleRate).rounded(.towardZero))
    }
}
