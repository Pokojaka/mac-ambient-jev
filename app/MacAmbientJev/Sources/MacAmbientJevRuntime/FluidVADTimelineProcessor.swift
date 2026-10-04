import Foundation
import FluidAudio
import MacAmbientJevCore

enum FluidVADTimelineProcessorError: LocalizedError {
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
/// The cursor advances only to `checkpoint.committedFrames`, so callers can poll
/// this actor while capture continues. Re-supplying the same checkpoint is a no-op.
actor FluidVADTimelineProcessor {
    private let directory: URL
    private let initialCheckpoint: AudioCheckpoint
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

    init(
        reader: ProcessingTimelineReader,
        engine: any VADChunkSegmenting
    ) {
        let checkpoint = reader.checkpoint
        self.directory = reader.directory
        self.initialCheckpoint = checkpoint
        self.engine = engine
        self.sourceFramesPerRead = Int64((CanonicalAudio.sampleRate * Self.sourceReadSeconds).rounded())
    }

    func segmentAll() async throws -> [SegmentReference] {
        var emitted = try await processAvailable(
            checkpoint: initialCheckpoint
        )
        emitted.append(contentsOf: try await finish(
            checkpoint: initialCheckpoint
        ))
        return emitted
    }

    /// Processes only frames that became durable since the previous call.
    func processAvailable(
        checkpoint: AudioCheckpoint
    ) async throws -> [SegmentReference] {
        guard !finished else { return [] }
        try CanonicalAudio.validate(sampleRate: checkpoint.sampleRate, channelCount: checkpoint.channelCount,
                                    sampleFormat: checkpoint.sampleFormat)
        guard checkpoint.committedFrames >= sourceStartFrame else {
            throw FluidVADTimelineProcessorError.checkpointMovedBackward
        }
        knownGaps = checkpoint.gapEvents
        try await drainFullVADChunks()

        let reader = ProcessingTimelineReader(
            directory: directory,
            checkpoint: checkpoint
        )

        while sourceStartFrame < checkpoint.committedFrames {
            let sourceEndFrame = min(
                checkpoint.committedFrames,
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
    func finish(
        checkpoint: AudioCheckpoint
    ) async throws -> [SegmentReference] {
        guard !finished else { return [] }

        undelivered = try await processAvailable(checkpoint: checkpoint)

        if pendingOffset < pending16k.count {
            let finalChunk = Array(pending16k[pendingOffset...])
            accept(try await engine.process16kChunk(finalChunk))
        }

        pending16k.removeAll(keepingCapacity: false)
        pendingOffset = 0
        undelivered.append(
            contentsOf: await engine.finish(
                totalCanonicalFrames: checkpoint.committedFrames
            )
        )
        finished = true
        return takeUndelivered()
    }

    private func drainFullVADChunks() async throws {
        while pending16k.count - pendingOffset >= VadManager.chunkSize {
            let end = pendingOffset + VadManager.chunkSize
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
    func takeMicSpeechLevels() -> [MicLevelWindow] {
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
        let sampleRate = initialCheckpoint.sampleRate
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
