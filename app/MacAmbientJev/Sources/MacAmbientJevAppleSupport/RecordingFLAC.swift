import AudioToolbox
import Foundation
import MacAmbientJevCore

public enum RecordingFLACError: LocalizedError, Equatable {
    case nonFiniteSample(frame: Int64)
    case audioToolbox(operation: String, status: OSStatus)
    case disposeAfterFailure(failure: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .nonFiniteSample(let frame):
            "フレーム \(frame) の音声サンプルが有限値ではないため 16-bit FLAC にできません"
        case .audioToolbox(let operation, let status):
            "FLAC の書き出しに失敗しました（\(operation)、OSStatus \(status)）"
        case .disposeAfterFailure(let failure, let status):
            "FLAC の書き出しに失敗しました: \(failure)。ファイルも閉じられませんでした（OSStatus \(status)）"
        }
    }
}

/// The stored form of a finalized recording: 16-kHz mono 16-bit FLAC.
/// Apple's FLAC encoder emits no audio until it has written one full block, so a stream is never
/// shorter than `blockFrames`; frames at and after the recording's length are exactly zero.
public enum RecordingFLAC {
    public static let blockFrames: Int64 = 4_096
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
    public static func write(reader: any TimelineAudioReading, to url: URL) throws {
        let committedFrames = reader.info.committedFrames
        let storedFrames = storedFrames(committedFrames: committedFrames)
        var file: ExtAudioFileRef?
        var destination = AudioStreamBasicDescription(
            mSampleRate: CanonicalAudio.sampleRate, mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(blockFrames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(CanonicalAudio.channelCount), mBitsPerChannel: 0, mReserved: 0
        )
        try check(
            ExtAudioFileCreateWithURL(
                url as CFURL, kAudioFileFLACType, &destination, nil, AudioFileFlags.eraseFile.rawValue, &file
            ),
            "ExtAudioFileCreateWithURL"
        )
        guard let file else {
            throw RecordingFLACError.audioToolbox(operation: "ExtAudioFileCreateWithURL returned no file", status: noErr)
        }
        do {
            var client = AudioStreamBasicDescription(
                mSampleRate: CanonicalAudio.sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: UInt32(CanonicalAudio.channelCount), mBitsPerChannel: 16, mReserved: 0
            )
            try check(
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout.size(ofValue: client)), &client
                ),
                "ExtAudioFileSetProperty"
            )
            var startFrame: Int64 = 0
            while startFrame < storedFrames {
                let endFrame = min(storedFrames, startFrame + framesPerWrite)
                var samples = [Int16](repeating: 0, count: Int(endFrame - startFrame))
                let readEnd = min(endFrame, committedFrames)
                if startFrame < readEnd {
                    let source = try reader.readSamples(frameRange: startFrame..<readEnd)
                    for (index, sample) in source.enumerated() {
                        guard let quantized = quantize16(sample) else {
                            throw RecordingFLACError.nonFiniteSample(frame: startFrame + Int64(index))
                        }
                        samples[index] = quantized
                    }
                }
                try write(samples, to: file)
                startFrame = endFrame
            }
        } catch {
            let disposeStatus = ExtAudioFileDispose(file)
            guard disposeStatus == noErr else {
                throw RecordingFLACError.disposeAfterFailure(
                    failure: error.localizedDescription, status: disposeStatus
                )
            }
            throw error
        }
        try check(ExtAudioFileDispose(file), "ExtAudioFileDispose")
    }

    private static func write(_ samples: [Int16], to file: ExtAudioFileRef) throws {
        var samples = samples
        let frameCount = samples.count
        let byteCount = frameCount * MemoryLayout<Int16>.size
        try samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(CanonicalAudio.channelCount),
                    mDataByteSize: UInt32(byteCount), mData: raw.baseAddress
                )
            )
            try check(ExtAudioFileWrite(file, UInt32(frameCount), &list), "ExtAudioFileWrite")
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw RecordingFLACError.audioToolbox(operation: operation, status: status)
        }
    }
}
