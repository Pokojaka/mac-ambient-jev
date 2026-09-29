import Foundation
import FluidAudio
import MacAmbientJevCore
import MacAmbientJevPlatformAudio

enum FluidVADTimelineProcessorError: LocalizedError {
    case invalidSourceFormat
    case missingChannelData
    case incompatibleCheckpoint
    case checkpointMovedBackward

    var errorDescription: String? {
        switch self {
        case .invalidSourceFormat:
            "VAD用の音声形式を作成できません"
        case .missingChannelData:
            "VAD用のPCMバッファを作成できません"
        case .incompatibleCheckpoint:
            "録音中に音声形式が変更されたため、ライブVADを継続できません"
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
    private let resampler: VADResampler?

    private var sourceStartFrame: Int64 = 0
    private var pending16k: [Float] = []
    private var pendingOffset = 0
    private var undelivered: [SegmentReference] = []
    private var finished = false

    init(
        reader: ProcessingTimelineReader,
        engine: any VADChunkSegmenting,
        sourceReadSeconds: Double = 1.0
    ) {
        precondition(sourceReadSeconds > 0)

        let checkpoint = reader.checkpoint
        self.directory = reader.directory
        self.initialCheckpoint = checkpoint
        self.engine = engine
        self.sourceFramesPerRead = max(
            1,
            Int64((checkpoint.sampleRate * sourceReadSeconds).rounded())
        )
        self.resampler = VADResampler(
            sampleRate: checkpoint.sampleRate,
            channelCount: checkpoint.channelCount
        )
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
        guard checkpoint.sampleRate == initialCheckpoint.sampleRate,
              checkpoint.channelCount == initialCheckpoint.channelCount else {
            throw FluidVADTimelineProcessorError.incompatibleCheckpoint
        }
        guard checkpoint.committedFrames >= sourceStartFrame else {
            throw FluidVADTimelineProcessorError.checkpointMovedBackward
        }
        guard let resampler else {
            throw FluidVADTimelineProcessorError.invalidSourceFormat
        }
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
            let interleaved = try reader.readSamples(
                frameRange: sourceStartFrame..<sourceEndFrame
            )
            do {
                pending16k.append(
                    contentsOf: try resampler.resample(
                        interleaved: interleaved,
                        frameCount: Int(sourceEndFrame - sourceStartFrame)
                    )
                )
            } catch VADResamplerError.invalidSourceFormat {
                throw FluidVADTimelineProcessorError.invalidSourceFormat
            } catch VADResamplerError.missingChannelData {
                throw FluidVADTimelineProcessorError.missingChannelData
            }
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
            undelivered.append(
                contentsOf: try await engine.process16kChunk(finalChunk)
            )
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

    func openSpeechRange(upToFrame durableFrame: Int64) async -> OpenSpeechRange? {
        guard !finished else { return nil }
        return await engine.openSpeechRange(upToFrame: durableFrame)
    }

    private func drainFullVADChunks() async throws {
        while pending16k.count - pendingOffset >= VadManager.chunkSize {
            let end = pendingOffset + VadManager.chunkSize
            let chunk = Array(pending16k[pendingOffset..<end])
            undelivered.append(
                contentsOf: try await engine.process16kChunk(chunk)
            )
            pendingOffset = end
        }

        if pendingOffset > 0,
           pendingOffset >= pending16k.count / 2 {
            pending16k.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private func takeUndelivered() -> [SegmentReference] {
        defer { undelivered.removeAll() }
        return undelivered
    }
}
