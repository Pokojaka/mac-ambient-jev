import AVFoundation
import Foundation

public enum AudioFileTimelineBuilderError: LocalizedError {
    case unsupportedPCMFormat
    case missingChannelData

    public var errorDescription: String? {
        switch self {
        case .unsupportedPCMFormat:
            "音声ファイルを32-bit float PCMとして読み込めません"
        case .missingChannelData:
            "音声ファイルからPCMデータを取得できません"
        }
    }
}

public actor AudioFileTimelineBuilder {
    public let readFrameCount: AVAudioFrameCount

    public init(readFrameCount: AVAudioFrameCount = 8_192) {
        precondition(readFrameCount > 0)
        self.readFrameCount = readFrameCount
    }

    public func build(
        from sourceURL: URL,
        into processingDirectory: URL
    ) async throws -> AudioCheckpoint {
        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.processingFormat

        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            throw AudioFileTimelineBuilderError.unsupportedPCMFormat
        }

        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: readFrameCount
        ) else {
            throw AudioFileTimelineBuilderError.unsupportedPCMFormat
        }

        while true {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: readFrameCount)

            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }

            guard let channels = buffer.floatChannelData else {
                throw AudioFileTimelineBuilderError.missingChannelData
            }

            let channelCount = Int(format.channelCount)
            var interleaved = Array(
                repeating: Float.zero,
                count: frameCount * channelCount
            )

            for frame in 0..<frameCount {
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    interleaved[base + channel] = channels[channel][frame]
                }
            }

            try await writer.append(samples: interleaved)
        }

        return try await writer.finish()
    }
}
