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

/// Streams a canonical timeline into a 16-kHz mono float32 CAF (the diarization input) in bounded buffers.
public struct ProcessingTimelineAudioExporter: Sendable {
    public let framesPerBuffer: Int64

    public init(framesPerBuffer: Int64) {
        precondition(framesPerBuffer > 0)
        self.framesPerBuffer = framesPerBuffer
    }

    /// Writes into a hidden sibling first, then moves it over `destinationURL`.
    public func export(
        reader: any TimelineAudioReading,
        to destinationURL: URL
    ) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appending(
            path: ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        do {
            try write(reader: reader, to: temporaryURL)
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

    private func write(reader: any TimelineAudioReading, to url: URL) throws {
        let committedFrames = reader.info.committedFrames
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: CanonicalAudio.sampleRate,
            channels: AVAudioChannelCount(CanonicalAudio.channelCount), interleaved: false
        ) else {
            throw ProcessingTimelineAudioExporterError.invalidFormat
        }
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        var startFrame: Int64 = 0
        while startFrame < committedFrames {
            let endFrame = min(committedFrames, startFrame + framesPerBuffer)
            let samples = try reader.readSamples(frameRange: startFrame..<endFrame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw ProcessingTimelineAudioExporterError.invalidFormat
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            guard let channel = buffer.floatChannelData?[0] else {
                throw ProcessingTimelineAudioExporterError.missingChannelData
            }
            channel.update(from: samples, count: samples.count)
            try file.write(from: buffer)
            startFrame = endFrame
        }
        file.close()
    }
}
