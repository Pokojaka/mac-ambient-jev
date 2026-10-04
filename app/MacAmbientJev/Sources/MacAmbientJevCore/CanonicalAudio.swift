import Foundation

public enum CanonicalAudio {
    public static let sampleRate: Double = 16_000
    public static let channelCount = 1
    public static let sampleFormat = PCMSampleFormat.float32LE

    public static func validate(sampleRate: Double, channelCount: Int, sampleFormat: PCMSampleFormat) throws {
        guard sampleRate == Self.sampleRate, channelCount == Self.channelCount,
              sampleFormat == Self.sampleFormat else { throw CanonicalAudioError.noncanonicalFormat }
    }

    /// Half-open boundaries map cumulatively: round(n * 16000 / sourceRate), ties away from zero.
    public static func boundary(_ sourceFrame: Int64, sampleRate: Double) throws -> Int64 {
        guard sourceFrame >= 0, sampleRate.isFinite, sampleRate > 0 else {
            throw CanonicalAudioError.invalidSourceFormat
        }
        let value = (Double(sourceFrame) * Self.sampleRate / sampleRate).rounded()
        guard value < Double(Int64.max) else { throw CanonicalAudioError.invalidSourceFormat }
        return Int64(value)
    }
}

public enum CanonicalAudioError: LocalizedError {
    case noncanonicalFormat
    case invalidSourceFormat
    case invalidSamples
    case alreadyFinished
    case conversionFailed(String)
    case frameCountMismatch(expected: Int64, actual: Int64)

    public var errorDescription: String? {
        switch self {
        case .noncanonicalFormat: "Internal audio must be 16000 Hz, mono, float32 PCM"
        case .invalidSourceFormat: "Invalid source audio rate or frame extent"
        case .invalidSamples: "Invalid PCM buffer or non-finite audio samples"
        case .alreadyFinished: "Cannot feed audio after converter end-of-stream"
        case .conversionFailed(let cause): "Canonical audio conversion failed: \(cause)"
        case .frameCountMismatch(let expected, let actual):
            "Canonical converter produced \(actual) frames; expected \(expected)"
        }
    }
}

/// Owned exclusively by the serialized ingress lane; input is already downmixed mono.
public protocol CanonicalAudioConverting: Sendable {
    var sourceSampleRate: Double { get }
    func convert(mono: [Float]) throws -> [Float]
    func finish() throws -> [Float]
}
