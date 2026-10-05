import AVFoundation
import AudioToolbox
import Foundation
import MacAmbientJevCore

public enum FLACTimelineReaderError: LocalizedError, Equatable {
    case unreadable(String)
    case notCanonicalFLAC16
    case lengthMismatch(expected: Int64, actual: Int64)
    case decodedFrameCountMismatch(expected: Int64, decoded: Int64)
    case decodeFailed(frame: Int64, reason: String)
    case sampleMismatch(frame: Int64)
    case paddingNotSilent(frame: Int64)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            "保存済み FLAC 音声を開けません: \(reason)"
        case .notCanonicalFLAC16:
            "保存済み FLAC 音声が 16,000 Hz・mono・16-bit FLAC ではありません"
        case .lengthMismatch(let expected, let actual):
            "保存済み FLAC 音声の長さ \(actual) フレームが保存状態の \(expected) フレームと一致しません"
        case .decodedFrameCountMismatch(let expected, let decoded):
            "保存済み FLAC 音声を最後まで復号すると \(decoded) フレームで、期待した \(expected) フレームと一致しません"
        case .decodeFailed(let frame, let reason):
            "保存済み FLAC 音声をフレーム \(frame) で復号できません: \(reason)"
        case .sampleMismatch(let frame):
            "FLAC 音声のフレーム \(frame) が元の PCM の 16-bit 量子化値と一致しません"
        case .paddingNotSilent(let frame):
            "FLAC 音声の録音末尾の埋めフレーム \(frame) が無音ではありません"
        }
    }
}

/// Bounded reads of `audio/recording.flac`. Opening checks the container format and length;
/// `validateAudio` decodes exactly that many stored frames, including silent padding.
public final class FLACTimelineReader: TimelineAudioReading, @unchecked Sendable {
    public let url: URL
    public let info: TimelineAudioInfo
    private static let framesPerRead: AVAudioFrameCount = 8_192
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()

    public init(url: URL, info: TimelineAudioInfo) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw FLACTimelineReaderError.unreadable(error.localizedDescription)
        }
        let stored = file.fileFormat.streamDescription.pointee
        guard stored.mFormatID == kAudioFormatFLAC,
              stored.mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData,
              stored.mSampleRate == CanonicalAudio.sampleRate,
              stored.mChannelsPerFrame == UInt32(CanonicalAudio.channelCount),
              file.processingFormat.sampleRate == CanonicalAudio.sampleRate,
              file.processingFormat.channelCount == AVAudioChannelCount(CanonicalAudio.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: Self.framesPerRead) else {
            throw FLACTimelineReaderError.notCanonicalFLAC16
        }
        let storedFrames = RecordingFLAC.storedFrames(committedFrames: info.committedFrames)
        guard file.length == storedFrames else {
            throw FLACTimelineReaderError.lengthMismatch(expected: storedFrames, actual: file.length)
        }
        self.url = url
        self.info = info
        self.file = file
        self.buffer = buffer
    }

    public func readSamples(frameRange: Range<Int64>) throws -> [Float] {
        guard frameRange.lowerBound >= 0, frameRange.upperBound <= info.committedFrames else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        lock.lock()
        defer { lock.unlock() }
        var output = [Float]()
        output.reserveCapacity(frameRange.count)
        file.framePosition = frameRange.lowerBound
        while output.count < frameRange.count {
            let requested = min(Int(Self.framesPerRead), frameRange.count - output.count)
            let read = try readBuffer(frameCount: AVAudioFrameCount(requested), at: frameRange.lowerBound + Int64(output.count))
            output.append(contentsOf: read)
        }
        return output
    }

    /// Decodes every stored frame within the validated container length, requiring each read
    /// to return exactly the requested frames without probing EOF.
    public func validateAudio() throws {
        try decodeAll(expected: nil)
    }

    /// Requires every decoded sample to equal the 16-bit quantization of `source` exactly.
    public func validateAudio(against source: any TimelineAudioReading) throws {
        try decodeAll(expected: source)
    }

    private func decodeAll(expected source: (any TimelineAudioReading)?) throws {
        lock.lock()
        defer { lock.unlock() }
        let committedFrames = info.committedFrames
        let storedFrames = RecordingFLAC.storedFrames(committedFrames: committedFrames)
        file.framePosition = 0
        var decoded: Int64 = 0
        while decoded < storedFrames {
            let requested = AVAudioFrameCount(min(Int64(Self.framesPerRead), storedFrames - decoded))
            let samples = try readBuffer(frameCount: requested, at: decoded)
            let recordedCount = Int(max(0, min(Int64(samples.count), committedFrames - decoded)))
            if let source, recordedCount > 0 {
                let reference = try source.readSamples(frameRange: decoded..<(decoded + Int64(recordedCount)))
                for offset in 0..<recordedCount {
                    guard let quantized = RecordingFLAC.quantize16(reference[offset]),
                          samples[offset] == Float(quantized) / 32768 else {
                        throw FLACTimelineReaderError.sampleMismatch(frame: decoded + Int64(offset))
                    }
                }
            }
            for offset in recordedCount..<samples.count where samples[offset] != 0 {
                throw FLACTimelineReaderError.paddingNotSilent(frame: decoded + Int64(offset))
            }
            decoded += Int64(samples.count)
        }
    }

    /// Every request is within the known stored length; short reads are corruption, not EOF.
    private func readBuffer(frameCount: AVAudioFrameCount, at frame: Int64) throws -> [Float] {
        buffer.frameLength = 0
        do {
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            throw FLACTimelineReaderError.decodeFailed(frame: frame, reason: error.localizedDescription)
        }
        guard buffer.frameLength == frameCount else {
            throw FLACTimelineReaderError.decodedFrameCountMismatch(
                expected: file.length, decoded: frame + Int64(buffer.frameLength)
            )
        }
        guard let channel = buffer.floatChannelData?[0] else {
            throw FLACTimelineReaderError.decodeFailed(frame: frame, reason: "no channel data")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
