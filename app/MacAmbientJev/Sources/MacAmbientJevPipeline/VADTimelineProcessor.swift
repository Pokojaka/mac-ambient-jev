import Foundation
import MacAmbientJevCore

public struct VADChunkOutput: Sendable {
    public let segments: [SegmentReference]
    public let micLevel: MicLevelWindow?

    public init(segments: [SegmentReference], micLevel: MicLevelWindow?) {
        self.segments = segments
        self.micLevel = micLevel
    }
}

public protocol VADChunkSegmenting: Sendable {
    var chunkSize: Int { get }
    func process16kChunk(_ samples: [Float]) async throws -> VADChunkOutput
    func finish(totalCanonicalFrames: Int64) async -> [SegmentReference]
}

enum VADTimelineProcessorError: LocalizedError {
    case checkpointMovedBackward

    var errorDescription: String? {
        switch self {
        case .checkpointMovedBackward:
            "録音の確定位置が巻き戻ったため、ライブVADを継続できません"
        }
    }
}

/// Incrementally consumes the durable processing timeline.
///
/// The cursor advances only to the supplied reader's `info.committedFrames`, so callers can
/// poll this actor while capture continues. Re-supplying the same extent is a no-op.
public actor VADTimelineProcessor {
    private let engine: any VADChunkSegmenting
    private let sourceFramesPerRead: Int64

    private var sourceStartFrame: Int64 = 0
    private var pending16k: [Float] = []
    private var pendingOffset = 0
    private var undelivered: [SegmentReference] = []
    private var undeliveredMicSpeechLevels: [MicLevelWindow] = []
    private var knownGaps: [AudioGapEvent] = []
    private var finished = false

    /// Seconds of source audio read from the timeline per VAD step.
    static let sourceReadSeconds = 1.0

    public init(engine: any VADChunkSegmenting) {
        precondition(engine.chunkSize > 0, "VADのチャンクサイズは1以上でなければなりません")
        self.engine = engine
        self.sourceFramesPerRead = Int64((CanonicalAudio.sampleRate * Self.sourceReadSeconds).rounded())
    }

    public func segmentAll(reader: any TimelineAudioReading) async throws -> [SegmentReference] {
        var emitted = try await processAvailable(reader: reader)
        emitted.append(contentsOf: try await finish(reader: reader))
        return emitted
    }

    /// Processes only frames that became durable since the previous call.
    public func processAvailable(
        reader: any TimelineAudioReading
    ) async throws -> [SegmentReference] {
        guard !finished else { return [] }
        let info = reader.info
        guard info.committedFrames >= sourceStartFrame else {
            throw VADTimelineProcessorError.checkpointMovedBackward
        }
        knownGaps = info.gapEvents
        try await drainFullVADChunks()

        while sourceStartFrame < info.committedFrames {
            let sourceEndFrame = min(
                info.committedFrames,
                sourceStartFrame + sourceFramesPerRead
            )
            pending16k.append(contentsOf: try reader.readSamples(
                frameRange: sourceStartFrame..<sourceEndFrame
            ))
            sourceStartFrame = sourceEndFrame
            try await drainFullVADChunks()
        }

        return takeUndelivered()
    }

    /// Consumes the final durable tail and closes any open VAD segment.
    public func finish(
        reader: any TimelineAudioReading
    ) async throws -> [SegmentReference] {
        guard !finished else { return [] }

        undelivered = try await processAvailable(reader: reader)

        if pendingOffset < pending16k.count {
            let finalChunk = Array(pending16k[pendingOffset...])
            accept(try await engine.process16kChunk(finalChunk))
        }

        pending16k.removeAll(keepingCapacity: false)
        pendingOffset = 0
        undelivered.append(
            contentsOf: await engine.finish(
                totalCanonicalFrames: reader.info.committedFrames
            )
        )
        finished = true
        return takeUndelivered()
    }

    private func drainFullVADChunks() async throws {
        while pending16k.count - pendingOffset >= engine.chunkSize {
            let end = pendingOffset + engine.chunkSize
            let chunk = Array(pending16k[pendingOffset..<end])
            accept(try await engine.process16kChunk(chunk))
            pendingOffset = end
        }

        if pendingOffset > 0,
           pendingOffset >= pending16k.count / 2 {
            pending16k.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    /// Speech level windows measured since the previous call, each returned once.
    public func takeMicSpeechLevels() -> [MicLevelWindow] {
        defer { undeliveredMicSpeechLevels.removeAll() }
        return undeliveredMicSpeechLevels
    }

    private func accept(_ output: VADChunkOutput) {
        undelivered.append(contentsOf: output.segments)
        guard let level = output.micLevel, level.speechSeconds > 0,
              !intersectsKnownGap(level) else { return }
        undeliveredMicSpeechLevels.append(level)
    }

    /// Replacement silence is not captured speech; a window touching it is dropped whole.
    private func intersectsKnownGap(_ level: MicLevelWindow) -> Bool {
        let sampleRate = CanonicalAudio.sampleRate
        return knownGaps.contains { gap in
            let gapStart = Double(gap.startFrame) / sampleRate
            let gapEnd = Double(gap.startFrame + gap.frameCount) / sampleRate
            return level.startSeconds < gapEnd && gapStart < level.endSeconds
        }
    }

    private func takeUndelivered() -> [SegmentReference] {
        defer { undelivered.removeAll() }
        return undelivered
    }
}
