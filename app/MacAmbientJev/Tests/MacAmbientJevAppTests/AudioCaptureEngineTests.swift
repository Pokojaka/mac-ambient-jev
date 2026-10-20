import AudioToolbox
import CoreMedia
import Synchronization
import Testing
@testable import MacAmbientJevCapture
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline

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
        let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 10.0 / CanonicalAudio.sampleRate, sessionURL: directory)
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
        #expect(try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint, sessionURL: directory)
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
        let writer = try DurableAudioWriter(directory: directory, chunkDurationSeconds: 1, sessionURL: root)
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
        #expect(try ProcessingTimelineReader(directory: directory, checkpoint: result.checkpoint, sessionURL: root)
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
        let writer = try DurableAudioWriter(directory: root.appending(path: "capture"), chunkDurationSeconds: 1, sessionURL: root)
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
