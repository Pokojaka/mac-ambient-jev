import AudioToolbox
import Foundation
import MacAmbientJevCore

/// Decodes every AAC packet of an M4A with AudioConverter and keeps the encoder priming and end padding.
/// ExtAudioFile would drop frames by its own rules; the shared `AACTrimWindow` decides what to keep.
final class M4APacketDecoder {
    private static let endOfPackets: OSStatus = 100
    private static let batchPacketCount = 32

    let sampleRate: Double
    let channelCount: Int

    private let source: DescriptorAudioFile
    private let converter: AudioConverterRef
    private let input: PacketInput
    private var finished = false

    /// Returns nil when the file's codec is not AAC family (for example ALAC); that file has no encoder priming.
    init?(url: URL, sessionURL: URL) throws {
        let source = try DescriptorAudioFile(reading: url, sessionURL: sessionURL)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try Self.check(AudioFileGetProperty(source.audioFile, kAudioFilePropertyDataFormat, &size, &format))
        guard format.mFormatID == kAudioFormatMPEG4AAC || format.mFormatID == kAudioFormatMPEG4AAC_HE
                || format.mFormatID == kAudioFormatMPEG4AAC_HE_V2 else { return nil }
        guard format.mSampleRate > 0, format.mSampleRate == format.mSampleRate.rounded(),
              format.mChannelsPerFrame > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedDataFormatError))
        }

        var count: UInt64 = 0
        size = UInt32(MemoryLayout.size(ofValue: count))
        try Self.check(AudioFileGetProperty(source.audioFile, kAudioFilePropertyAudioDataPacketCount, &size, &count))
        var maximumPacketSize: UInt32 = 0
        size = UInt32(MemoryLayout.size(ofValue: maximumPacketSize))
        try Self.check(AudioFileGetProperty(source.audioFile, kAudioFilePropertyPacketSizeUpperBound, &size, &maximumPacketSize))
        guard count <= UInt64(Int64.max), maximumPacketSize > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileInvalidFileError))
        }

        let channels = format.mChannelsPerFrame
        var output = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        var created: AudioConverterRef?
        try Self.check(AudioConverterNew(&format, &output, &created))
        guard let created else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioConverterErr_UnspecifiedError)) }

        var cookieSize: UInt32 = 0
        var writable: UInt32 = 0
        if AudioFileGetPropertyInfo(source.audioFile, kAudioFilePropertyMagicCookieData, &cookieSize, &writable) == noErr, cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            let status = AudioFileGetProperty(source.audioFile, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie)
            guard status == noErr,
                  AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie, cookieSize, cookie) == noErr else {
                AudioConverterDispose(created)
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == noErr ? kAudioConverterErr_UnspecifiedError : status))
            }
        }

        self.source = source
        self.converter = created
        self.sampleRate = format.mSampleRate
        self.channelCount = Int(channels)
        self.input = PacketInput(
            file: source.audioFile, packetCount: Int64(count),
            capacityPerBatch: Int(maximumPacketSize) * Self.batchPacketCount, batch: Self.batchPacketCount
        )
    }

    deinit { AudioConverterDispose(converter) }

    /// Up to `frameCount` interleaved float frames; empty once every packet is decoded.
    func read(frameCount: Int) throws -> [Float] {
        if finished { return [] }
        var samples = [Float](repeating: 0, count: frameCount * channelCount)
        var produced = UInt32(frameCount)
        let channels = UInt32(channelCount)
        let status: OSStatus = samples.withUnsafeMutableBytes { bytes in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            )
            return AudioConverterFillComplexBuffer(converter, { _, packets, buffers, descriptions, context in
                let input = Unmanaged<PacketInput>.fromOpaque(context!).takeUnretainedValue()
                return input.supplyNextPacket(packets, buffers, descriptions)
            }, Unmanaged.passUnretained(input).toOpaque(), &produced, &buffers, nil)
        }
        if let error = input.error { throw NSError(domain: NSOSStatusErrorDomain, code: Int(error)) }
        guard status == noErr || status == Self.endOfPackets else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        if produced == 0 { finished = true; return [] }
        return Array(samples[0..<Int(produced) * channelCount])
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Feeds packets to the converter one at a time from bounded batches.
    private final class PacketInput {
        let file: AudioFileID
        let packetCount: Int64
        let batch: Int
        let data: UnsafeMutableRawPointer
        let capacity: Int
        let descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>
        let current = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var nextPacket: Int64 = 0
        var batchCount = 0
        var indexInBatch = 0
        var error: OSStatus?

        init(file: AudioFileID, packetCount: Int64, capacityPerBatch: Int, batch: Int) {
            self.file = file
            self.packetCount = packetCount
            self.batch = batch
            self.capacity = capacityPerBatch
            data = UnsafeMutableRawPointer.allocate(byteCount: capacityPerBatch, alignment: 16)
            descriptions = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: batch)
        }

        deinit {
            data.deallocate()
            descriptions.deallocate()
            current.deallocate()
        }

        func supplyNextPacket(
            _ packets: UnsafeMutablePointer<UInt32>,
            _ buffers: UnsafeMutablePointer<AudioBufferList>,
            _ outDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
        ) -> OSStatus {
            if indexInBatch >= batchCount {
                guard nextPacket < packetCount else { packets.pointee = 0; return M4APacketDecoder.endOfPackets }
                var bytes = UInt32(capacity)
                var count = UInt32(min(Int64(batch), packetCount - nextPacket))
                let status = AudioFileReadPacketData(file, false, &bytes, descriptions, nextPacket, &count, data)
                guard status == noErr, count > 0 else {
                    error = status == noErr ? kAudioFileInvalidPacketOffsetError : status
                    packets.pointee = 0
                    return error!
                }
                batchCount = Int(count)
                indexInBatch = 0
                nextPacket += Int64(count)
            }
            let description = descriptions[indexInBatch]
            indexInBatch += 1
            buffers.pointee.mNumberBuffers = 1
            buffers.pointee.mBuffers.mNumberChannels = 0
            buffers.pointee.mBuffers.mDataByteSize = description.mDataByteSize
            buffers.pointee.mBuffers.mData = data + Int(description.mStartOffset)
            current.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: description.mVariableFramesInPacket,
                mDataByteSize: description.mDataByteSize
            )
            outDescriptions?.pointee = current
            packets.pointee = 1
            return noErr
        }
    }
}
