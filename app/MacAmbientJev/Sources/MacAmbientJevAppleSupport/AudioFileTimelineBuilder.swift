import AVFoundation
import Foundation
import MacAmbientJevCore

public enum AudioFileTimelineBuilderError: LocalizedError {
    case unsupportedPCMFormat
    case missingChannelData
    case unexpectedEOF

    public var errorDescription: String? {
        switch self {
        case .unsupportedPCMFormat:
            "音声ファイルを32-bit float PCMとして読み込めません"
        case .missingChannelData:
            "音声ファイルからPCMデータを取得できません"
        case .unexpectedEOF:
            "音声ファイルが宣言されたフレーム数より前に終了しました"
        }
    }
}

public actor AudioFileTimelineBuilder {
    /// Imported audio is written in one pass, so chunks only bound the size of each file.
    static let chunkDurationSeconds: Double = 5

    public let readFrameCount: AVAudioFrameCount

    public init(readFrameCount: AVAudioFrameCount = 8_192) {
        precondition(readFrameCount > 0)
        self.readFrameCount = readFrameCount
    }

    public func build(
        from sourceURL: URL,
        into processingDirectory: URL,
        sessionURL: URL
    ) async throws -> AudioCheckpoint {
        let file = try DescriptorAudioReader(url: sourceURL, sessionURL: sessionURL)
        let format = file.processingFormat

        guard format.commonFormat == .pcmFormatFloat32,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            throw AudioFileTimelineBuilderError.unsupportedPCMFormat
        }

        try SessionFileAccess.removeIfPresent(processingDirectory, relativeTo: sessionURL)
        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            chunkDurationSeconds: Self.chunkDurationSeconds, sessionURL: sessionURL
        )
        let converter = try CanonicalAudioResampler(sampleRate: format.sampleRate)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: readFrameCount
        ) else {
            throw AudioFileTimelineBuilderError.unsupportedPCMFormat
        }

        while file.framePosition < file.length {
            let remainingFrames = file.length - file.framePosition
            let requestedFrames = AVAudioFrameCount(
                min(Int64(readFrameCount), remainingFrames)
            )

            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: requestedFrames)

            let frameCount = Int(buffer.frameLength)
            guard frameCount == Int(requestedFrames) else { throw AudioFileTimelineBuilderError.unexpectedEOF }

            guard let channels = buffer.floatChannelData else {
                throw AudioFileTimelineBuilderError.missingChannelData
            }

            let channelCount = Int(format.channelCount)
            var mono = Array(repeating: Float.zero, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let sample = channels[channel][frame]
                    guard sample.isFinite else { throw CanonicalAudioError.invalidSamples }
                    sum += sample
                }
                mono[frame] = sum / Float(channelCount)
            }
            try await writer.append(samples: converter.convert(mono: mono))
        }
        try await writer.append(samples: converter.finish())

        return try await writer.finish()
    }
}