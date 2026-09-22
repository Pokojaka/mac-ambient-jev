import AVFoundation
import FluidAudio
import MacAmbientJevCore

enum FluidVADTimelineProcessorError: LocalizedError {
    case invalidSourceFormat
    case missingChannelData

    var errorDescription: String? {
        switch self {
        case .invalidSourceFormat:
            "VAD用の音声形式を作成できません"
        case .missingChannelData:
            "VAD用のPCMバッファを作成できません"
        }
    }
}

actor FluidVADTimelineProcessor {
    private let reader: ProcessingTimelineReader
    private let engine: FluidVADSegmentationEngine
    private let sourceFramesPerRead: Int64

    init(
        reader: ProcessingTimelineReader,
        engine: FluidVADSegmentationEngine,
        sourceReadSeconds: Double = 1.0
    ) {
        precondition(sourceReadSeconds > 0)
        self.reader = reader
        self.engine = engine
        self.sourceFramesPerRead = max(
            1,
            Int64((reader.checkpoint.sampleRate * sourceReadSeconds).rounded())
        )
    }

    func segmentAll() async throws -> [SegmentReference] {
        let checkpoint = reader.checkpoint
        let channelCount = checkpoint.channelCount

        guard
            let sourceFormat = AVAudioFormat(
                standardFormatWithSampleRate: checkpoint.sampleRate,
                channels: AVAudioChannelCount(channelCount)
            )
        else {
            throw FluidVADTimelineProcessorError.invalidSourceFormat
        }

        let converter = FluidAudio.AudioConverter()
        var emitted: [SegmentReference] = []
        var pending16k: [Float] = []
        var pendingOffset = 0
        var sourceStartFrame: Int64 = 0

        while sourceStartFrame < checkpoint.committedFrames {
            let sourceEndFrame = min(
                checkpoint.committedFrames,
                sourceStartFrame + sourceFramesPerRead
            )
            let interleaved = try reader.readSamples(
                frameRange: sourceStartFrame..<sourceEndFrame
            )
            let frameCount = Int(sourceEndFrame - sourceStartFrame)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw FluidVADTimelineProcessorError.invalidSourceFormat
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            guard let channels = buffer.floatChannelData else {
                throw FluidVADTimelineProcessorError.missingChannelData
            }

            for frame in 0..<frameCount {
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    channels[channel][frame] = interleaved[base + channel]
                }
            }

            let resampled = try converter.resampleBuffer(buffer)
            pending16k.append(contentsOf: resampled)

            while pending16k.count - pendingOffset >= VadManager.chunkSize {
                let end = pendingOffset + VadManager.chunkSize
                let chunk = Array(pending16k[pendingOffset..<end])
                emitted.append(contentsOf: try await engine.process16kChunk(chunk))
                pendingOffset = end
            }

            if pendingOffset > 0,
               pendingOffset >= pending16k.count / 2 {
                pending16k.removeFirst(pendingOffset)
                pendingOffset = 0
            }

            sourceStartFrame = sourceEndFrame
        }

        if pendingOffset < pending16k.count {
            let finalChunk = Array(pending16k[pendingOffset...])
            emitted.append(contentsOf: try await engine.process16kChunk(finalChunk))
        }

        emitted.append(contentsOf: await engine.finish(
            totalCanonicalFrames: checkpoint.committedFrames
        ))

        return emitted
    }
}
