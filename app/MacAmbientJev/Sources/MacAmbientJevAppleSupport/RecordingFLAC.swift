import AudioToolbox
import Foundation
import MacAmbientJevCore

public enum RecordingFLACError: LocalizedError, Equatable {
    case nonFiniteSample(frame: Int64)
    case noncanonicalASRClipSampleRate(Int)
    case asrClipTooShort(sampleCount: Int, minimum: Int)
    case audioToolbox(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .nonFiniteSample(let frame):
            "フレーム \(frame) の音声サンプルが有限値ではないため 16-bit FLAC にできません"
        case .noncanonicalASRClipSampleRate(let sampleRate):
            "ASR クリップのサンプルレートは 16000 Hz である必要があります（入力: \(sampleRate) Hz）"
        case .asrClipTooShort(let sampleCount, let minimum):
            "ASR クリップは最低 \(minimum) サンプル必要です（入力: \(sampleCount) サンプル）"
        case .audioToolbox(let operation, let status):
            "FLAC の書き出しに失敗しました（\(operation)、OSStatus \(status)）"
        }
    }
}

/// The stored form of a finalized recording: 16-kHz mono 16-bit FLAC.
/// Apple's FLAC encoder emits no audio until it has written one full block, so a stream is never
/// shorter than `blockFrames`; frames at and after the recording's length are exactly zero.
public enum RecordingFLAC {
    public static let blockFrames: Int64 = 4_096
    public static let asrClipBitDepth = 16
    private static let framesPerWrite: Int64 = 48_000

    /// Frames in the FLAC stream for a recording of `committedFrames`: max(committedFrames, blockFrames).
    public static func storedFrames(committedFrames: Int64) -> Int64 {
        max(committedFrames, blockFrames)
    }

    /// Finite samples are clamped to [-1, 1], then scaled by 32768, rounded to nearest
    /// (ties away from zero) and clamped to Int16: -1 maps to -32768 and +1 to 32767.
    /// The decoder returns `value / 32768`, so FLAC is lossless only for these quantized values.
    public static func quantize16(_ sample: Float) -> Int16? {
        guard sample.isFinite else { return nil }
        let scaled = (min(1, max(-1, sample)) * 32768).rounded()
        return Int16(min(Float(Int16.max), scaled))
    }

    /// Writes the recording directly to `url` and closes the file. The caller validates `reader`
    /// when it opens it.
    public static func write(reader: any TimelineAudioReading, to url: URL, sessionURL: URL) throws {
        try write(
            reader: reader, to: url, directory: sessionURL,
            storedFrames: storedFrames(committedFrames: reader.info.committedFrames),
            blockFrames: blockFrames
        )
    }

    /// Writes an exact-length canonical ASR clip without the recording writer's minimum-block padding.
    /// The AudioToolbox FLAC encoder rejects blocks under 192 frames, so clips shorter than the ASR minimum are refused.
    public static func writeASRClip(_ input: ASRAudioInput, to url: URL, directory: URL) throws {
        guard input.sampleRate == Int(CanonicalAudio.sampleRate) else {
            throw RecordingFLACError.noncanonicalASRClipSampleRate(input.sampleRate)
        }
        guard !input.isShorterThanMinimumASRDuration else {
            throw RecordingFLACError.asrClipTooShort(
                sampleCount: input.samples.count,
                minimum: ASRAudioInput.minimumSampleCount(sampleRate: input.sampleRate)
            )
        }
        let reader = try ASRClipReader(samples: input.samples)
        try write(
            reader: reader, to: url, directory: directory,
            storedFrames: Int64(input.samples.count),
            blockFrames: min(blockFrames, Int64(input.samples.count))
        )
    }

    private static func write(
        reader: any TimelineAudioReading, to url: URL, directory: URL,
        storedFrames: Int64, blockFrames: Int64
    ) throws {
        var client = AudioStreamBasicDescription(
            mSampleRate: CanonicalAudio.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: UInt32(CanonicalAudio.channelCount), mBitsPerChannel: 16, mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: CanonicalAudio.sampleRate, mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(blockFrames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(CanonicalAudio.channelCount), mBitsPerChannel: 0, mReserved: 0
        )
        var created: AudioConverterRef?
        try check(AudioConverterNew(&client, &destination, &created), "AudioConverterNew")
        guard let converter = created else {
            throw RecordingFLACError.audioToolbox(operation: "AudioConverterNew returned no converter", status: noErr)
        }
        defer { AudioConverterDispose(converter) }
        let descriptorFile = try DescriptorAudioFile(
            url: url, sessionURL: directory, type: kAudioFileFLACType, format: &destination
        )
        try writeCookie(converter, to: descriptorFile.audioFile)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var maximumPacketSize: UInt32 = 0
        try check(AudioConverterGetProperty(
            converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maximumPacketSize
        ), "AudioConverterGetProperty maximum packet size")
        guard maximumPacketSize > 0 else {
            throw RecordingFLACError.audioToolbox(operation: "empty maximum packet size", status: kAudio_ParamError)
        }
        let output = UnsafeMutableRawPointer.allocate(byteCount: Int(maximumPacketSize), alignment: MemoryLayout<Int16>.alignment)
        defer { output.deallocate() }
        let input = EncodingInput(reader: reader, capacity: Int(framesPerWrite), storedFrames: storedFrames)
        var packetIndex: Int64 = 0
        while true {
            var packets: UInt32 = 1
            var description = AudioStreamPacketDescription()
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(CanonicalAudio.channelCount), mDataByteSize: maximumPacketSize, mData: output
            ))
            let status = AudioConverterFillComplexBuffer(
                converter, supplyPCM, Unmanaged.passUnretained(input).toOpaque(),
                &packets, &buffer, &description
            )
            if let error = input.error { throw error }
            try check(status, "AudioConverterFillComplexBuffer")
            guard packets > 0 else { break }
            let produced = packets
            try check(AudioFileWritePackets(
                descriptorFile.audioFile, false, buffer.mBuffers.mDataByteSize,
                &description, packetIndex, &packets, output
            ), "AudioFileWritePackets")
            guard packets == produced else {
                throw RecordingFLACError.audioToolbox(operation: "incomplete packet write", status: kAudioFileUnspecifiedError)
            }
            packetIndex += Int64(packets)
        }
        guard input.position == input.storedFrames else {
            throw RecordingFLACError.audioToolbox(operation: "encoder ended before recorded frames", status: kAudioFileUnspecifiedError)
        }
        try writeCookie(converter, to: descriptorFile.audioFile)
        try descriptorFile.close()
    }

    /// FLAC stream-info is supplied by the codec, including its final frame count.
    private static func writeCookie(_ converter: AudioConverterRef, to file: AudioFileID) throws {
        var size: UInt32 = 0
        try check(AudioConverterGetPropertyInfo(
            converter, kAudioConverterCompressionMagicCookie, &size, nil
        ), "AudioConverterGetPropertyInfo magic cookie")
        guard size > 0 else {
            throw RecordingFLACError.audioToolbox(operation: "empty FLAC magic cookie", status: kAudioFileUnspecifiedError)
        }
        var cookie = Data(count: Int(size))
        try cookie.withUnsafeMutableBytes { bytes in
            try check(AudioConverterGetProperty(
                converter, kAudioConverterCompressionMagicCookie, &size, bytes.baseAddress!
            ), "AudioConverterGetProperty magic cookie")
            try check(AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, size, bytes.baseAddress!),
                      "AudioFileSetProperty magic cookie")
        }
    }

    private struct ASRClipReader: TimelineAudioReading {
        let samples: [Float]
        let info: TimelineAudioInfo

        init(samples: [Float]) throws {
            self.samples = samples
            self.info = try TimelineAudioInfo(committedFrames: Int64(samples.count), gapEvents: [])
        }

        func readSamples(frameRange: Range<Int64>) throws -> [Float] {
            guard frameRange.lowerBound >= 0, frameRange.upperBound >= frameRange.lowerBound,
                  frameRange.upperBound <= info.committedFrames else {
                throw ProcessingTimelineReaderError.invalidFrameRange
            }
            return Array(samples[Int(frameRange.lowerBound)..<Int(frameRange.upperBound)])
        }

        func validateAudio() throws {}
    }

    private final class EncodingInput {
        let reader: any TimelineAudioReading
        let capacity: Int
        let samples: UnsafeMutablePointer<Int16>
        let storedFrames: Int64
        var position: Int64 = 0
        var error: (any Error)?

        init(reader: any TimelineAudioReading, capacity: Int, storedFrames: Int64) {
            self.reader = reader
            self.capacity = capacity
            self.samples = .allocate(capacity: capacity)
            self.storedFrames = storedFrames
        }

        deinit { samples.deallocate() }

        func supply(_ requested: UInt32, to buffers: UnsafeMutablePointer<AudioBufferList>) throws -> UInt32 {
            let count = Int(min(Int64(min(Int(requested), capacity)), storedFrames - position))
            let end = position + Int64(count)
            let readEnd = min(end, reader.info.committedFrames)
            var sourceCount = 0
            if position < readEnd {
                let source = try reader.readSamples(frameRange: position..<readEnd)
                guard source.count == Int(readEnd - position) else {
                    throw RecordingFLACError.audioToolbox(operation: "unexpected PCM EOF", status: kAudioFileUnspecifiedError)
                }
                sourceCount = source.count
                for (index, sample) in source.enumerated() {
                    guard let quantized = RecordingFLAC.quantize16(sample) else {
                        throw RecordingFLACError.nonFiniteSample(frame: position + Int64(index))
                    }
                    samples[index] = quantized
                }
            }
            if sourceCount < count {
                samples.advanced(by: sourceCount).initialize(repeating: 0, count: count - sourceCount)
            }
            buffers.pointee.mNumberBuffers = 1
            buffers.pointee.mBuffers = AudioBuffer(
                mNumberChannels: UInt32(CanonicalAudio.channelCount),
                mDataByteSize: UInt32(count * MemoryLayout<Int16>.size), mData: samples
            )
            position = end
            return UInt32(count)
        }
    }

    private static let supplyPCM: AudioConverterComplexInputDataProc = { _, packets, buffers, descriptions, context in
        let input = Unmanaged<EncodingInput>.fromOpaque(context!).takeUnretainedValue()
        do {
            packets.pointee = try input.supply(packets.pointee, to: buffers)
            descriptions?.pointee = nil
            return noErr
        } catch {
            input.error = error
            packets.pointee = 0
            return kAudioFileUnspecifiedError
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RecordingFLACError.audioToolbox(operation: operation, status: status)
        }
    }
}
