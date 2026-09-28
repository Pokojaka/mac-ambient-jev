import AudioToolbox
import CoreMedia
import Synchronization
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@Test
func formatChangeAfterInvalidAudioBufferNotifiesExactlyOnce() throws {
    let notificationCount = Atomic(0)
    let receiver = AudioCaptureReceiver(
        ring: AudioBlockRing(capacity: 2, blockFrameCapacity: 16),
        sampleRate: 48_000,
        channelCount: 1,
        onFormatChange: { _ = notificationCount.add(1, ordering: .relaxed) }
    )

    receiver.process(try makeAudioSampleBuffer(sampleRate: 48_000))
    #expect(receiver.invalidBufferCount.load(ordering: .relaxed) == 1)
    #expect(notificationCount.load(ordering: .relaxed) == 0)

    receiver.process(try makeAudioSampleBuffer(sampleRate: 44_100))
    #expect(notificationCount.load(ordering: .relaxed) == 1)
    #expect(receiver.invalidBufferCount.load(ordering: .relaxed) == 2)

    receiver.process(try makeAudioSampleBuffer(sampleRate: 44_100))
    #expect(notificationCount.load(ordering: .relaxed) == 1)
    #expect(receiver.invalidBufferCount.load(ordering: .relaxed) == 3)
}

private func makeAudioSampleBuffer(sampleRate: Double) throws -> CMSampleBuffer {
    var audioFormat = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    var description: CMAudioFormatDescription?
    let descriptionStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &audioFormat,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &description
    )
    #expect(descriptionStatus == noErr)
    let formatDescription = try #require(description)

    var sampleBuffer: CMSampleBuffer?
    let timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    let sampleStatus = CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: [timing],
        sampleSizeEntryCount: 1,
        sampleSizeArray: [4],
        sampleBufferOut: &sampleBuffer
    )
    #expect(sampleStatus == noErr)
    return try #require(sampleBuffer)
}
