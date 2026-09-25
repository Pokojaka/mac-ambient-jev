import AVFoundation
import Foundation
import MacAmbientJevCore

public enum ProcessingTimelineAudioExporterError: LocalizedError {
    case invalidFormat
    case missingChannelData

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "処理用音声の書き出し形式を作成できません"
        case .missingChannelData:
            "処理用音声のPCMバッファを作成できません"
        }
    }
}

public struct ProcessingTimelineAudioExporter: Sendable {
    public let framesPerBuffer: Int64

    public init(framesPerBuffer: Int64 = 48_000) {
        precondition(framesPerBuffer > 0)
        self.framesPerBuffer = framesPerBuffer
    }

    public func export(
        reader: ProcessingTimelineReader,
        to destinationURL: URL
    ) throws {
        let checkpoint = reader.checkpoint
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: checkpoint.sampleRate,
            channels: AVAudioChannelCount(checkpoint.channelCount)
        ) else {
            throw ProcessingTimelineAudioExporterError.invalidFormat
        }

        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let file = try AVAudioFile(
            forWriting: destinationURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var startFrame: Int64 = 0
        while startFrame < checkpoint.committedFrames {
            let endFrame = min(
                checkpoint.committedFrames,
                startFrame + framesPerBuffer
            )
            let interleaved = try reader.readSamples(
                frameRange: startFrame..<endFrame
            )
            let frameCount = Int(endFrame - startFrame)

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ) else {
                throw ProcessingTimelineAudioExporterError.invalidFormat
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            guard let channels = buffer.floatChannelData else {
                throw ProcessingTimelineAudioExporterError.missingChannelData
            }

            for frame in 0..<frameCount {
                let sourceBase = frame * checkpoint.channelCount
                for channel in 0..<checkpoint.channelCount {
                    channels[channel][frame] = interleaved[sourceBase + channel]
                }
            }

            try file.write(from: buffer)
            startFrame = endFrame
        }
    }
}
