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

@Test("saved PTS discontinuities and stop tails report loss without overflow")
func stopResultReportsTimelineLoss() async throws {
    let cases: [(Int64, Int64, AudioGapEvent?, [Float])] = [
        (2, 3, nil, [1, 2, 5]),
        (4, 5, AudioGapEvent(startFrame: 2, frameCount: 2, reason: .missingCallback),
         [1, 2, 0, 0, 5]),
        (2, 5, AudioGapEvent(startFrame: 3, frameCount: 2, reason: .stopTail),
         [1, 2, 5, 0, 0])
    ]
    for (nextFrame, tailFrame, expectedGap, expectedSamples) in cases {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 2)
        let writer = try DurableAudioWriter(
            directory: directory, sampleRate: 10, channelCount: 1, chunkDurationSeconds: 1
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer)
        #expect(ring.push(samples: [1, 2]))
        var sample: Float = 5
        withUnsafeMutablePointer(to: &sample) { pointer in
            var channel = pointer
            withUnsafePointer(to: &channel) { channels in
                #expect(ring.pushPlanarFloat32(
                    channelData: channels, channelCount: 1, frameCount: 1, startFrame: nextFrame
                ))
            }
        }
        ring.finish(tailFrame: tailFrame)
        let checkpoint = try await drain.finish()
        let result = AudioCaptureStopResult(checkpoint: checkpoint, didOverflow: false)
        #expect(ring.overflowCount == 0)
        #expect(checkpoint.gapEvents == expectedGap.map { [$0] } ?? [])
        #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint)
            .readSamples(frameRange: 0..<tailFrame) == expectedSamples)
        #expect(result.didOverflow == (expectedGap != nil))
    }
}

private struct UnavailableDiskSpace: CaptureDiskSpaceProviding {
    struct QueryError: Error {}
    func availableBytes(at url: URL) throws -> Int64? { throw QueryError() }
}

private struct MeasuredDiskSpace: CaptureDiskSpaceProviding {
    let bytes: Int64?
    func availableBytes(at url: URL) throws -> Int64? { bytes }
}

@Test("disk capacity query errors warn but permit recording startup")
func diskCapacityQueryFailureDoesNotBlockStart() throws {
    var warnings: [String] = []
    try CaptureDiskPolicy.checkStart(
        diskSpace: UnavailableDiskSpace(), directory: FileManager.default.temporaryDirectory,
        sampleRate: 48_000, channelCount: 1,
        onWarning: { warnings.append($0) }
    )
    #expect(warnings == ["録音開始前の空き容量を確認できませんでした"])
}

@Test("unknown capacity warns, but measured insufficient capacity rejects startup")
func diskCapacityCheckPreservesMeasuredThreshold() throws {
    let required = CaptureDiskPolicy.requiredStartBytes(sampleRate: 48_000, channelCount: 1)
    var warnings: [String] = []
    let directory = FileManager.default.temporaryDirectory
    try CaptureDiskPolicy.checkStart(
        diskSpace: MeasuredDiskSpace(bytes: nil), directory: directory,
        sampleRate: 48_000, channelCount: 1,
        onWarning: { warnings.append($0) }
    )
    #expect(warnings == ["録音開始前の空き容量を確認できませんでした"])
    warnings.removeAll()
    try CaptureDiskPolicy.checkStart(
        diskSpace: MeasuredDiskSpace(bytes: required), directory: directory,
        sampleRate: 48_000, channelCount: 1,
        onWarning: { warnings.append($0) }
    )
    #expect(warnings.isEmpty)
    do {
        try CaptureDiskPolicy.checkStart(
            diskSpace: MeasuredDiskSpace(bytes: required - 1), directory: directory,
            sampleRate: 48_000, channelCount: 1,
            onWarning: { warnings.append($0) }
        )
        Issue.record("Measured low capacity must reject recording startup")
    } catch AudioCaptureEngineError.insufficientDiskSpace(let requested) {
        #expect(requested == required)
    }
    #expect(warnings.isEmpty)
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
