import AVFoundation
import AudioToolbox
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
        to destinationURL: URL,
        sessionURL: URL
    ) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try SessionFileAccess.createDirectory(parent, relativeTo: sessionURL)
        let temporaryURL = parent.appending(
            path: ".\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        do {
            try write(reader: reader, to: temporaryURL, sessionURL: sessionURL)
            try SessionFileAccess.rename(temporaryURL, to: destinationURL, relativeTo: sessionURL)
        } catch {
            do {
                try SessionFileAccess.removeIfPresent(temporaryURL, relativeTo: sessionURL)
            } catch let cleanupError {
                throw ProcessingTimelineAudioExporterError.temporaryFileNotRemoved(
                    path: temporaryURL.path,
                    writeFailure: error.localizedDescription,
                    cleanupFailure: cleanupError.localizedDescription
                )
            }
            throw error
        }
    }

    private func write(reader: any TimelineAudioReading, to url: URL, sessionURL: URL) throws {
        let committedFrames = reader.info.committedFrames
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: CanonicalAudio.sampleRate,
            channels: AVAudioChannelCount(CanonicalAudio.channelCount), interleaved: false
        ) else {
            throw ProcessingTimelineAudioExporterError.invalidFormat
        }
        var destination = format.streamDescription.pointee
        let descriptorFile = try DescriptorAudioFile(
            url: url, sessionURL: sessionURL, format: &destination
        )
        var wrapped: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(descriptorFile.audioFile, true, &wrapped)
        guard wrapStatus == noErr, let file = wrapped else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(wrapStatus))
        }
        do {
            let clientStatus = ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout.size(ofValue: destination)), &destination
            )
            guard clientStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(clientStatus)) }
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
                let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
                startFrame = endFrame
            }
        } catch {
            let status = ExtAudioFileDispose(file)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSUnderlyingErrorKey: error])
            }
            throw error
        }
        let status = ExtAudioFileDispose(file)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        try descriptorFile.close()
    }
}
