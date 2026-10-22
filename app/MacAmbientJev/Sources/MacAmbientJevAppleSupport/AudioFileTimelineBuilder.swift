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

public actor AudioFileTimelineBuilder: ImportedAudioTimelineBuilding {
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

        let converter = try CanonicalAudioResampler(sampleRate: format.sampleRate)
        let writer = try ImportedAudioTimelineWriter(
            directory: processingDirectory,
            sessionURL: sessionURL,
            converter: converter
        )

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

            let mono = try ImportedAudioPCM.downmix(
                frameCount: frameCount,
                channelCount: Int(format.channelCount),
                sample: { frame, channel in channels[channel][frame] }
            )
            try await writer.append(mono: mono)
        }

        return try await writer.finish()
    }
}