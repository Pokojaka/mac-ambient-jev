import AudioToolbox
import CoreMedia
import Synchronization
import Testing
@testable import MacAmbientJevCapture
import MacAmbientJevAppleSupport
import MacAmbientJevCore

@Test
func formatChangeAfterInvalidAudioBufferNotifiesExactlyOnce() throws {
    let notificationCount = Atomic(0)
    let receiver = AudioCaptureReceiver(
        ring: AudioBlockRing(capacity: 2, blockFrameCapacity: 16),
        sampleRate: 48_000,
        channelCount: 1,
        onFormatChange: { _ = notificationCount.add(1, ordering: .relaxed) },
        clock: SystemCaptureClock(), frameCapacity: 16_384,
        meter: nil
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
        ring: ring, sampleRate: 1_000, channelCount: 1, onFormatChange: {}, clock: SystemCaptureClock(), frameCapacity: 16_384, meter: nil
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
        let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate)
        let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate))
        #expect(pushRingMono([1, 2], at: 0, into: ring))
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
        let result = cleanStopResult(checkpoint)
        #expect(ring.overflowCount == 0)
        #expect(checkpoint.gapEvents == expectedGap.map { [$0] } ?? [])
        #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint)
            .readSamples(frameRange: 0..<tailFrame) == expectedSamples)
        #expect(result.didOverflow == (expectedGap != nil))
    }
}

func pushRingMono(_ values: [Float], at frame: Int64, into ring: AudioBlockRing) -> Bool {
    var values = values
    let frameCount = values.count
    return values.withUnsafeMutableBufferPointer { samples in
        var channel = [samples.baseAddress!]
        return channel.withUnsafeMutableBufferPointer {
            ring.pushPlanarFloat32(channelData: $0.baseAddress!, channelCount: 1,
                                   frameCount: frameCount, startFrame: frame)
        }
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

@Test("disk capacity query errors reject recording startup")
func diskCapacityQueryFailureRejectsStart() {
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: UnavailableDiskSpace(), directory: FileManager.default.temporaryDirectory)
    } throws: { error in
        guard case AudioCaptureEngineError.diskSpaceUnavailable = error else { return false }
        return true
    }
}

@Test("unknown or insufficient capacity rejects startup; measured sufficient capacity starts")
func diskCapacityCheckPreservesMeasuredThreshold() throws {
    let required = CaptureDiskPolicy.requiredStartBytes
    let directory = FileManager.default.temporaryDirectory
    #expect {
        try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: nil), directory: directory)
    } throws: { error in
        guard case AudioCaptureEngineError.diskSpaceUnavailable = error else { return false }
        return true
    }
    try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: required), directory: directory)
    do {
        try CaptureDiskPolicy.checkStart(diskSpace: MeasuredDiskSpace(bytes: required - 1), directory: directory)
        Issue.record("Measured low capacity must reject recording startup")
    } catch AudioCaptureEngineError.insufficientDiskSpace(let requested) {
        #expect(requested == required)
    }
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

private final class ManualClock: CaptureClock {
    let millis: Atomic<Int64>
    init(seconds: Double) { millis = Atomic(Int64(seconds * 1_000)) }
    func now() -> TimeInterval { Double(millis.load(ordering: .relaxed)) / 1_000 }
}

private func push(_ sink: TimestampedMonoSink, _ channels: [[Float]], at startFrame: Int64) {
    let buffers = channels.map { channel -> UnsafeMutablePointer<Float> in
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
        buffer.initialize(from: channel, count: channel.count)
        return buffer
    }
    defer { buffers.forEach { $0.deallocate() } }
    let pointers = buffers.map { UnsafePointer($0) }
    let strides = Array(repeating: 1, count: channels.count)
    pointers.withUnsafeBufferPointer { channelPointers in
        strides.withUnsafeBufferPointer { stridePointers in
            sink.receive(channels: channelPointers.baseAddress!, strides: stridePointers.baseAddress!,
                         channelCount: channels.count, frameCount: channels[0].count,
                         startFrame: startFrame)
        }
    }
}

private func meteredSink(channels: Int, sampleRate: Double) -> (TimestampedMonoSink, AudioBlockRing) {
    let ring = AudioBlockRing(capacity: 256, blockFrameCapacity: 512, sampleRate: sampleRate)
    let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: ManualClock(seconds: 10),
                                   meter: RawInputMeter(channelCount: channels, sampleRate: sampleRate))
    return (sink, ring)
}

private func drainRing(_ ring: AudioBlockRing, tail: Int64) -> [AudioBlock] {
    ring.finish(tailFrame: tail)
    var blocks: [AudioBlock] = []
    while let block = ring.pop() { blocks.append(block) }
    return blocks
}

@MainActor
private final class RecordingMicVolume: MicInputVolumeControlling {
    var values: [UInt32: Float] = [0: 0.5]
    var failWrites = false
    private(set) var writes: [[MicInputVolumeElement]] = []
    private(set) var unbinds = 0

    private var current: MicInputVolumeSnapshot {
        MicInputVolumeSnapshot(deviceUID: "mic", elements: values.keys.sorted().map {
            MicInputVolumeElement(element: $0, scalar: values[$0]!)
        }, isSettable: true)
    }

    func bind(captureDeviceUID: String,
              onChange: @escaping @MainActor @Sendable (MicInputVolumeChange) -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot { current }
    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot { current }
    func setVolumes(_ requested: [MicInputVolumeElement], expected: MicInputVolumeSnapshot)
        async throws(MicInputVolumeWriteFailure) -> MicInputVolumeSnapshot {
        writes.append(requested)
        if failWrites {
            throw MicInputVolumeWriteFailure(reason: .writeRejected, effective: current.elements, unresolved: [])
        }
        for value in requested { values[value.element] = value.scalar }
        return current
    }
    func unbind() throws(MicInputVolumeFailure) { unbinds += 1 }
}

@MainActor
private final class StatusLog {
    var statuses: [MicInputStatus] = []
}

@MainActor
private func drainMainActor() async {
    for _ in 0..<20 { await Task.yield() }
}

/// Input-free microphone runs: synthetic sink input, no AVCapture device, no HAL.
@Suite struct MicInputVolumeTests {
    @Test("One clipping channel is counted even when the mono downmix hides it")
    func meterSeesClippingHiddenByDownmix() {
        let (sink, ring) = meteredSink(channels: 2, sampleRate: 16_000)
        var left = [Float](repeating: 0.3, count: 1_600)
        var right = [Float](repeating: -0.3, count: 1_600)
        left[10] = 1; left[11] = 1
        right[10] = -0.96; right[11] = -0.96
        push(sink, [left, right], at: 0)
        let windows = sink.meter!.takeWindows()
        #expect(windows == [RawInputMeter.Window(startFrame: 0, frameCount: 1_600, peak: 1,
                                                  clippedFraction: 2.0 / 1_600)])
        let mono = drainRing(ring, tail: sink.lastEndFrame).flatMap(\.samples)
        #expect(mono.count == 1_600)
        #expect(mono.allSatisfy { abs($0) < 0.03 })
    }

    @Test("Split callbacks produce exact 100-ms windows at 16 kHz and 96 kHz")
    func meterWindowsSpanCallbacks() {
        let (sink16, _) = meteredSink(channels: 1, sampleRate: 16_000)
        for index in 0..<5 {
            var samples = [Float](repeating: 0.1, count: 700)
            if index == 0 { samples[699] = 0.99 }
            if index == 1 { samples[0] = -0.99 }
            push(sink16, [samples], at: Int64(index * 700))
        }
        #expect(sink16.meter!.takeWindows() == [
            RawInputMeter.Window(startFrame: 0, frameCount: 1_600, peak: 0.99, clippedFraction: 2.0 / 1_600),
            RawInputMeter.Window(startFrame: 1_600, frameCount: 1_600, peak: 0.1, clippedFraction: 0)
        ])
        let (sink96, _) = meteredSink(channels: 1, sampleRate: 96_000)
        for index in 0..<20 {
            push(sink96, [[Float](repeating: 0.2, count: 1_000)], at: Int64(index * 1_000))
        }
        #expect(sink96.meter!.takeWindows().map(\.startFrame) == [0, 9_600])
        #expect(sink96.meter!.windowFrames == 9_600)
    }

    @Test("Timestamp gaps, invalid packets and replacement silence never complete a window")
    func meterExcludesGaps() {
        let (sink, _) = meteredSink(channels: 1, sampleRate: 16_000)
        let block = [Float](repeating: 0.2, count: 1_000)
        push(sink, [block], at: 0)
        push(sink, [block], at: 1_500)
        push(sink, [block], at: 2_500)
        sink.missing(startFrame: 3_500, frameCount: 100)
        push(sink, [[Float](repeating: 0.2, count: 1_500)], at: 3_600)
        sink.silence(startFrame: 5_100, frameCount: 100)
        push(sink, [[Float](repeating: 0.2, count: 1_600)], at: 5_200)
        #expect(sink.meter!.takeWindows().map(\.startFrame) == [1_500, 5_200])
    }

    @Test("Metering leaves durable samples, timestamps and frame counts unchanged")
    func meterDoesNotChangeDurableAudio() {
        let ringA = AudioBlockRing(capacity: 256, blockFrameCapacity: 512, sampleRate: 16_000)
        let ringB = AudioBlockRing(capacity: 256, blockFrameCapacity: 512, sampleRate: 16_000)
        let metered = TimestampedMonoSink(ring: ringA, frameCapacity: 512, clock: ManualClock(seconds: 1),
                                          meter: RawInputMeter(channelCount: 2, sampleRate: 16_000))
        let plain = TimestampedMonoSink(ring: ringB, frameCapacity: 512, clock: ManualClock(seconds: 1),
                                        meter: nil)
        let left = (0..<2_000).map { Float(sin(Double($0) / 7)) }
        let right = (0..<2_000).map { Float(cos(Double($0) / 5)) * 0.99 }
        for sink in [metered, plain] {
            push(sink, [Array(left[0..<900]), Array(right[0..<900])], at: 0)
            push(sink, [Array(left[900...]), Array(right[900...])], at: 1_000)
        }
        #expect(metered.lastEndFrame == plain.lastEndFrame)
        #expect(drainRing(ringA, tail: metered.lastEndFrame) == drainRing(ringB, tail: plain.lastEndFrame))
    }

    @Test("A reset discards the producer's partial window and windows queued before it")
    func meterResetDiscardsOldEvidence() {
        let (sink, _) = meteredSink(channels: 1, sampleRate: 16_000)
        let meter = sink.meter!
        push(sink, [[Float](repeating: 1, count: 1_600)], at: 0)
        push(sink, [[Float](repeating: 1, count: 1_000)], at: 1_600)
        meter.requestReset()
        #expect(meter.takeWindows().isEmpty)
        push(sink, [[Float](repeating: 0.1, count: 1_000)], at: 2_600)
        push(sink, [[Float](repeating: 0.1, count: 600)], at: 3_600)
        #expect(meter.takeWindows() == [
            RawInputMeter.Window(startFrame: 2_600, frameCount: 1_600, peak: 0.1, clippedFraction: 0)
        ])
    }

    @MainActor
    @Test("An input-free mic run lowers on clipping, ignores other sessions and keeps durable audio when restore fails")
    func engineMicRunLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
        let volume = RecordingMicVolume()
        var factoryCalls = 0
        let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 512,
                                        clock: ManualClock(seconds: 10),
                                        micInputVolumeFactory: { factoryCalls += 1; return volume })
        let directory = root.appending(path: "capture", directoryHint: .isDirectory)
        let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 1)
        let ring = AudioBlockRing(capacity: 16, blockFrameCapacity: 512, sampleRate: 16_000)
        let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: ManualClock(seconds: 10),
                                       meter: RawInputMeter(channelCount: 1, sampleRate: 16_000))
        let sessionID = UUID()
        engine.installCapture(
            session: nil, output: nil, receiver: nil, callbackQueue: nil, tap: nil, sink: sink,
            ring: ring, drain: AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate)), drainTask: nil,
            sessionID: sessionID,
            timeline: ProcessingTimeline(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE)
        )
        var samples = [Float](repeating: 0.25, count: 1_600)
        samples[100] = 1; samples[101] = -1
        push(sink, [samples], at: 0)
        let log = StatusLog()
        engine.beginMicInputVolume(captureDeviceUID: "mic", sessionID: sessionID,
                                   automaticAdjustmentEnabled: true) { id, status in
            #expect(id == sessionID)
            log.statuses.append(status)
        }
        #expect(factoryCalls == 1 && volume.writes.isEmpty)
        engine.pollMicMeter()
        await drainMainActor()
        #expect(volume.writes.count == 1 && abs(volume.values[0]! - 0.4) < 1e-6)

        engine.micSpeechMonitoringUnavailable(sessionID: UUID())
        #expect(log.statuses.allSatisfy { !$0.speechMonitoringUnavailable })
        engine.micSpeechMonitoringUnavailable(sessionID: sessionID)
        #expect(log.statuses.last?.speechMonitoringUnavailable == true)

        volume.failWrites = true
        let result = try await engine.stop()
        #expect(volume.writes.count == 2 && volume.unbinds == 1)
        #expect(log.statuses.last?.adjustment == .restoreFailed(.writeRejected))
        #expect(result.checkpoint.committedFrames == 1_600)
        #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint)
            .readSamples(frameRange: 0..<1_600) == samples)
    }

    @MainActor
    @Test("With automatic adjustment off, a mic run warns about clipping without constructing a volume control")
    func engineDisabledNeverConstructsVolume() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
        var factoryCalls = 0
        let engine = AudioCaptureEngine(paths: paths, bufferFrameCount: 512,
                                        clock: ManualClock(seconds: 10),
                                        micInputVolumeFactory: { factoryCalls += 1; return RecordingMicVolume() })
        let writer = try DurableAudioWriter(directory: root.appending(path: "capture"), chunkDurationSeconds: 1)
        let ring = AudioBlockRing(capacity: 16, blockFrameCapacity: 512, sampleRate: 16_000)
        let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: ManualClock(seconds: 10),
                                       meter: RawInputMeter(channelCount: 1, sampleRate: 16_000))
        let sessionID = UUID()
        engine.installCapture(
            session: nil, output: nil, receiver: nil, callbackQueue: nil, tap: nil, sink: sink,
            ring: ring, drain: AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate)), drainTask: nil,
            sessionID: sessionID,
            timeline: ProcessingTimeline(sampleRate: 16_000, channelCount: 1, sampleFormat: .float32LE)
        )
        push(sink, [[Float](repeating: 1, count: 1_600)], at: 0)
        let log = StatusLog()
        engine.beginMicInputVolume(captureDeviceUID: "mic", sessionID: sessionID,
                                   automaticAdjustmentEnabled: false) { _, status in log.statuses.append(status) }
        engine.pollMicMeter()
        #expect(log.statuses.last == MicInputStatus(warning: .clipping, speechMonitoringUnavailable: false, adjustment: .disabledBySetting))
        _ = try await engine.stop()
        #expect(factoryCalls == 0)
    }

    @MainActor
    @Test("A microphone start without an input-volume configuration fails before any device access")
    func micStartRequiresConfiguration() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let paths = AppPaths(applicationSupportURL: root, cacheURL: root, sessionsRootOverride: root)
        let engine = AudioCaptureEngine(paths: paths, micInputVolumeFactory: {
            preconditionFailure("An unconfigured start never reaches volume binding")
        })
        do {
            try await engine.start(sessionID: UUID(), source: .microphone, onFailure: { _ in }, onWarning: { _ in },
        onPermissionWaiting: {}, onDropouts: { _ in }, onSilenceChanged: { _ in })
            Issue.record("An unconfigured microphone start must fail")
        } catch AudioCaptureEngineError.micInputVolumeNotConfigured {
            #expect(!engine.isRecording)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}
