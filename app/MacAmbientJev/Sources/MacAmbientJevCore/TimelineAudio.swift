import Foundation

/// Canonical audio coordinates of a session, independent of how the samples are stored.
public struct TimelineAudioInfo: Codable, Sendable, Equatable {
    public let committedFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let gapEvents: [AudioGapEvent]

    private enum CodingKeys: String, CodingKey {
        case committedFrames, sampleRate, channelCount, gapEvents
    }

    public init(committedFrames: Int64, gapEvents: [AudioGapEvent]) throws {
        guard committedFrames >= 0,
              gapEvents.allSatisfy({ $0.startFrame >= 0 && $0.frameCount > 0
                  && $0.startFrame < committedFrames && $0.frameCount <= committedFrames - $0.startFrame }) else {
            throw TimelineAudioError.invalidInfo
        }
        self.committedFrames = committedFrames
        self.sampleRate = CanonicalAudio.sampleRate
        self.channelCount = CanonicalAudio.channelCount
        self.gapEvents = gapEvents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Double.self, forKey: .sampleRate) == CanonicalAudio.sampleRate,
              try container.decode(Int.self, forKey: .channelCount) == CanonicalAudio.channelCount else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        try self.init(
            committedFrames: container.decode(Int64.self, forKey: .committedFrames),
            gapEvents: container.decode([AudioGapEvent].self, forKey: .gapEvents)
        )
    }

    public var durationSeconds: Double { Double(committedFrames) / sampleRate }

    /// Replacement silence fills the timeline but is not captured input.
    public var hasCapturedAudio: Bool {
        guard committedFrames > 0 else { return false }
        var coveredThrough: Int64 = 0
        for gap in gapEvents.sorted(by: { $0.startFrame < $1.startFrame }) {
            if gap.startFrame > coveredThrough { return true }
            coveredThrough = max(coveredThrough, gap.startFrame + gap.frameCount)
            if coveredThrough >= committedFrames { return false }
        }
        return coveredThrough < committedFrames
    }
}

public enum TimelineAudioError: LocalizedError, Equatable {
    case invalidInfo

    public var errorDescription: String? {
        switch self {
        case .invalidInfo: "保存済み音声の長さまたは欠落記録が不正です"
        }
    }
}

/// Bounded random-access reads of a session's canonical 16-kHz mono samples.
public protocol TimelineAudioReading: Sendable {
    var info: TimelineAudioInfo { get }
    /// Reads `frameRange` only; never the whole recording.
    func readSamples(frameRange: Range<Int64>) throws -> [Float]
    /// Checks the stored audio against `info` before it is used.
    func validateAudio() throws
}

extension AudioCheckpoint {
    public var info: TimelineAudioInfo {
        get throws { try TimelineAudioInfo(committedFrames: committedFrames, gapEvents: gapEvents) }
    }
}
