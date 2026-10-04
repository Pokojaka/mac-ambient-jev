import AVFoundation
import Foundation
import MacAmbientJevCore

public enum ProcessingTimelineAudioExporterError: LocalizedError {
    case invalidFormat
    case missingChannelData
    case nonFiniteSample(frame: Int64)
    case temporaryFileNotRemoved(path: String, writeFailure: String, cleanupFailure: String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "処理用音声の書き出し形式を作成できません"
        case .missingChannelData:
            "処理用音声のPCMバッファを作成できません"
        case .nonFiniteSample(let frame):
            "フレーム \(frame) の音声サンプルが有限値ではないため 16-bit FLAC にできません"
        case .temporaryFileNotRemoved(let path, let writeFailure, let cleanupFailure):
            "処理用音声を書き出せませんでした: \(writeFailure)。一時ファイル \(path) も削除できませんでした: \(cleanupFailure)"
        }
    }
}

/// Streams a canonical timeline into an audio file in bounded buffers.
public struct ProcessingTimelineAudioExporter: Sendable {
    public enum Encoding: Sendable {
        /// 16-kHz mono float32 CAF, the diarization input.
        case float32CAF
        /// 16-kHz mono 16-bit FLAC, the stored form of a finalized recording.
        case flac16
    }

    public let framesPerBuffer: Int64

    public init(framesPerBuffer: Int64) {
        precondition(framesPerBuffer > 0)
        self.framesPerBuffer = framesPerBuffer
    }

    /// Finite samples are clamped to [-1, 1], then scaled by 32768, rounded to nearest
    /// (ties away from zero) and clamped to Int16: -1 maps to -32768 and +1 to 32767.
    /// The decoder returns `value / 32768`, so FLAC is lossless only for these quantized values.
    public static func quantize16(_ sample: Float) -> Int16? {
        guard sample.isFinite else { return nil }
        let scaled = (min(1, max(-1, sample)) * 32768).rounded()
        return Int16(min(Float(Int16.max), scaled))
    }

    /// Writes into a hidden sibling first, then moves it over `destinationURL`.
    public func export(
        reader: any TimelineAudioReading,
        to destinationURL: URL,
        encoding: Encoding
    ) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appending(
            path: ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        do {
            try write(reader: reader, to: temporaryURL, encoding: encoding)
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

    /// Writes directly to `url` and closes the file. The caller validates `reader` when it opens it.
    public func write(
        reader: any TimelineAudioReading,
        to url: URL,
        encoding: Encoding
    ) throws {
        let committedFrames = reader.info.committedFrames
        let commonFormat: AVAudioCommonFormat = encoding == .flac16 ? .pcmFormatInt16 : .pcmFormatFloat32
        guard let format = AVAudioFormat(
            commonFormat: commonFormat, sampleRate: CanonicalAudio.sampleRate,
            channels: AVAudioChannelCount(CanonicalAudio.channelCount), interleaved: false
        ) else {
            throw ProcessingTimelineAudioExporterError.invalidFormat
        }
        let file = try AVAudioFile(
            forWriting: url, settings: encoding == .flac16 ? Self.flac16Settings : format.settings,
            commonFormat: commonFormat, interleaved: false
        )
        var startFrame: Int64 = 0
        while startFrame < committedFrames {
            let endFrame = min(committedFrames, startFrame + framesPerBuffer)
            let samples = try reader.readSamples(frameRange: startFrame..<endFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw ProcessingTimelineAudioExporterError.invalidFormat
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            switch encoding {
            case .float32CAF:
                guard let channel = buffer.floatChannelData?[0] else {
                    throw ProcessingTimelineAudioExporterError.missingChannelData
                }
                channel.update(from: samples, count: samples.count)
            case .flac16:
                guard let channel = buffer.int16ChannelData?[0] else {
                    throw ProcessingTimelineAudioExporterError.missingChannelData
                }
                for (index, sample) in samples.enumerated() {
                    guard let quantized = Self.quantize16(sample) else {
                        throw ProcessingTimelineAudioExporterError.nonFiniteSample(frame: startFrame + Int64(index))
                    }
                    channel[index] = quantized
                }
            }
            try file.write(from: buffer)
            startFrame = endFrame
        }
        file.close()
    }

    /// The FLAC source bit depth follows the int16 client format; AVLinearPCMBitDepthKey and
    /// AVEncoderBitDepthHintKey are ignored by the FLAC encoder, which then stores 24-bit data.
    private static var flac16Settings: [String: Any] { [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: CanonicalAudio.sampleRate,
        AVNumberOfChannelsKey: CanonicalAudio.channelCount,
    ] }
}
