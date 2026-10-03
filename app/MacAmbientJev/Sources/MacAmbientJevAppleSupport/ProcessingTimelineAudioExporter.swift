import AVFoundation
import Foundation
import MacAmbientJevCore

public enum ProcessingTimelineAudioExporterError: LocalizedError {
    case invalidFormat
    case missingChannelData
    case temporaryFileNotRemoved(path: String, writeFailure: String, cleanupFailure: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "処理用音声の書き出し形式を作成できません"
        case .missingChannelData:
            "処理用音声のPCMバッファを作成できません"
        case .temporaryFileNotRemoved(let path, let writeFailure, let cleanupFailure):
            "処理用音声を書き出せませんでした: \(writeFailure)。一時ファイル \(path) も削除できませんでした: \(cleanupFailure)"
        }
    }
}

public struct ProcessingTimelineAudioExporter: Sendable {
    public enum Encoding: Sendable {
        case float32
        case flac24
    }

    public let framesPerBuffer: Int64

    public init(framesPerBuffer: Int64) {
        precondition(framesPerBuffer > 0)
        self.framesPerBuffer = framesPerBuffer
    }

    public func export(
        reader: ProcessingTimelineReader,
        to destinationURL: URL,
        encoding: Encoding
    ) throws {
        try reader.validateChunkFiles()
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

        let temporaryURL = parent.appending(
            path: ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        do {
            try write(reader: reader, format: format, encoding: encoding, to: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                do {
                    try FileManager.default.removeItem(at: temporaryURL)
                } catch let cleanupError {
                    throw ProcessingTimelineAudioExporterError.temporaryFileNotRemoved(
                        path: temporaryURL.path,
                        writeFailure: error.localizedDescription,
                        cleanupFailure: cleanupError.localizedDescription
                    )
                }
            }
            throw error
        }
    }

    private func write(
        reader: ProcessingTimelineReader,
        format: AVAudioFormat,
        encoding: Encoding,
        to url: URL
    ) throws {
        let checkpoint = reader.checkpoint
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings(for: format, encoding: encoding),
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
        file.close()
    }

    private func fileSettings(
        for format: AVAudioFormat,
        encoding: Encoding
    ) -> [String: Any] {
        switch encoding {
        case .float32:
            format.settings
        case .flac24:
            [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 24,
            ]
        }
    }
}
