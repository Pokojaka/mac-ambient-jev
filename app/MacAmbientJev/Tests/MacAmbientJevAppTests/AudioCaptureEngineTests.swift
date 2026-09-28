import AudioToolbox
import CoreMedia
import Synchronization
import Testing
@testable import MacAmbientJevCapture
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
    #expect(receiver.invalidBufferCount == 1)
    #expect(receiver.lastBufferMillis == 0)
    #expect(notificationCount.load(ordering: .relaxed) == 0)

    receiver.process(try makeAudioSampleBuffer(sampleRate: 44_100))
    #expect(notificationCount.load(ordering: .relaxed) == 1)
    #expect(receiver.invalidBufferCount == 2)

    receiver.process(try makeAudioSampleBuffer(sampleRate: 44_100))
    #expect(notificationCount.load(ordering: .relaxed) == 1)
    #expect(receiver.invalidBufferCount == 3)
}

@Test
func receiverTracksInvalidBuffersAtTheirPresentationTimestamp() throws {
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 16)
    let receiver = AudioCaptureReceiver(
        ring: ring, sampleRate: 1_000, channelCount: 1, onFormatChange: {}
    )
    receiver.process(try makeAudioSampleBuffer(sampleRate: 1_000, pts: 0))
    receiver.process(try makeAudioSampleBuffer(sampleRate: 1_000, pts: 5))
    #expect(receiver.lastEndFrame == 5_001)
    #expect(receiver.invalidBufferCount == 2)
    #expect(receiver.lastBufferMillis == 0)
    ring.finish(tailFrame: receiver.lastEndFrame)
    let first = try #require(ring.pop())
    let second = try #require(ring.pop())
    #expect(first.gap == AudioGap(startFrame: 0, frameCount: 1, reason: .invalidBuffer))
    #expect(second.gap == AudioGap(startFrame: 5_000, frameCount: 1, reason: .invalidBuffer))
}

private func makeAudioSampleBuffer(sampleRate: Double, pts: Double = 0) throws -> CMSampleBuffer {
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
        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: CMTimeScale(sampleRate)),
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
