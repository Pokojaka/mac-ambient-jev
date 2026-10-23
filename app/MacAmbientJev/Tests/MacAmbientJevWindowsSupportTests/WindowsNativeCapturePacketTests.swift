#if os(Windows)
import Foundation
import Testing
import CMiniaudio
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevWindowsSupport

private struct NativePacketSnapshot: Sendable, Equatable {
    let samples: [Float]?
    let frameCount: UInt32
    let channels: UInt32
    let sampleRate: UInt32
    let flags: UInt32
    let devicePosition: UInt64
    let qpc100ns: UInt64
    let packetOffset: UInt32
    let packetFrames: UInt32
}

/// Owns only copied callback values; native sample and packet pointers never escape the trampoline.
private final class NativePacketCollector: @unchecked Sendable {
    private(set) var packets: [NativePacketSnapshot] = []
    private let ingress: WindowsCaptureIngress?

    init(ingress: WindowsCaptureIngress? = nil) {
        self.ingress = ingress
    }

    func append(_ packet: mja_capture_packet) {
        let copiedSamples: [Float]?
        if let samples = packet.samples {
            let sampleCount = Int(packet.frame_count) * Int(packet.channels)
            copiedSamples = Array(UnsafeBufferPointer(start: samples, count: sampleCount))
        } else {
            copiedSamples = nil
        }
        packets.append(NativePacketSnapshot(
            samples: copiedSamples,
            frameCount: packet.frame_count,
            channels: packet.channels,
            sampleRate: packet.sample_rate,
            flags: packet.flags,
            devicePosition: packet.device_position,
            qpc100ns: packet.qpc_100ns,
            packetOffset: packet.packet_offset,
            packetFrames: packet.packet_frames
        ))

        ingress?.receive(WindowsCapturePacket(
            samples: packet.samples,
            frameCount: Int(packet.frame_count),
            channels: Int(packet.channels),
            sampleRate: Double(packet.sample_rate),
            flags: packet.flags,
            devicePosition: packet.device_position,
            qpc100ns: packet.qpc_100ns,
            packetOffset: Int(packet.packet_offset),
            packetFrames: Int(packet.packet_frames)
        ))
    }
}

private let nativePacketTrampoline: mja_capture_packet_fn = { user, packet in
    guard let user, let packet else {
        preconditionFailure("Native packet test callback omitted its context or packet")
    }
    Unmanaged<NativePacketCollector>.fromOpaque(user)
        .takeUnretainedValue()
        .append(packet.pointee)
}

private final class NativeDeviceCallbackProbe: @unchecked Sendable {
    private(set) var callbackCount = 0

    func recordCallback() {
        callbackCount += 1
    }
}

private let nativeDeviceTrampoline: mja_capture_device_fn = { user, _, _, _ in
    guard let user else {
        preconditionFailure("Native device test callback omitted its context")
    }
    Unmanaged<NativeDeviceCallbackProbe>.fromOpaque(user)
        .takeUnretainedValue()
        .recordCallback()
}

private let nativeHealthTrampoline: mja_capture_health_fn = { _, _, _, _ in }

private struct NativePacketTestClock: CaptureClock {
    func now() -> TimeInterval { 10 }
}

private struct NativeIngressHarness {
    let ingress: WindowsCaptureIngress
    let sink: TimestampedMonoSink
    let ring: AudioBlockRing

    init(sampleRate: Double, channels: Int) throws {
        let clock = NativePacketTestClock()
        let ring = AudioBlockRing(capacity: 8, blockFrameCapacity: 512, sampleRate: sampleRate)
        let sink = TimestampedMonoSink(ring: ring, frameCapacity: 512, clock: clock, meter: nil)
        let ingress = try WindowsCaptureIngress(
            sink: sink,
            sampleRate: sampleRate,
            channels: channels,
            epochQPC100ns: 10_000_000,
            clock: clock,
            loopback: false
        )
        self.ingress = ingress
        self.sink = sink
        self.ring = ring
    }
}

/// Invokes the actual native converter with caller-owned scratch storage.
private func convertNativePacket(
    format: mja_capture_pcm_format,
    sampleRate: UInt32,
    channels: UInt32,
    nativeSamples: UnsafeRawPointer?,
    packetFrames: UInt32,
    flags: UInt32,
    devicePosition: UInt64,
    qpc100ns: UInt64,
    scratchSampleCapacity: UInt32? = nil,
    collector: NativePacketCollector
) -> Int32 {
    let scratchCount = max(1, 512 * Int(channels))
    var scratch = [Float](repeating: 0, count: scratchCount)
    let callbackUser = Unmanaged.passUnretained(collector).toOpaque()
    let declaredCapacity = scratchSampleCapacity ?? UInt32(512 * Int(channels))
    return scratch.withUnsafeMutableBufferPointer { scratchBuffer in
        mja_capture_convert_packet(
            format,
            sampleRate,
            channels,
            nativeSamples,
            packetFrames,
            flags,
            devicePosition,
            qpc100ns,
            scratchBuffer.baseAddress,
            declaredCapacity,
            nativePacketTrampoline,
            callbackUser
        )
    }
}

private func convertBorrowedFloatPacket(
    _ samples: [Float],
    sampleRate: UInt32,
    channels: UInt32,
    packetFrames: UInt32,
    flags: UInt32,
    devicePosition: UInt64,
    qpc100ns: UInt64,
    collector: NativePacketCollector
) -> Int32 {
    samples.withUnsafeBufferPointer { buffer in
        convertNativePacket(
            format: MJA_CAPTURE_PCM_F32,
            sampleRate: sampleRate,
            channels: channels,
            nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
            packetFrames: packetFrames,
            flags: flags,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            collector: collector
        )
    }
}

private func convertBorrowedBytes(
    _ bytes: [UInt8],
    format: mja_capture_pcm_format,
    sampleRate: UInt32,
    channels: UInt32,
    packetFrames: UInt32,
    flags: UInt32,
    devicePosition: UInt64,
    qpc100ns: UInt64,
    collector: NativePacketCollector
) -> Int32 {
    bytes.withUnsafeBufferPointer { buffer in
        convertNativePacket(
            format: format,
            sampleRate: sampleRate,
            channels: channels,
            nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
            packetFrames: packetFrames,
            flags: flags,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            collector: collector
        )
    }
}

private func drain(_ ring: AudioBlockRing) -> [AudioBlock] {
    var blocks: [AudioBlock] = []
    while let block = ring.pop() { blocks.append(block) }
    return blocks
}

private func expectNormalizedPCM(_ actual: [Float]?, expected: [Float]) {
    guard let actual else {
        #expect(Bool(false))
        return
    }
    #expect(actual.count == expected.count)
    for (sample, reference) in zip(actual, expected) {
        #expect(abs(sample - reference) <= 0.000_001)
    }
    #expect(actual.allSatisfy { $0 >= -1.000_001 && $0 <= 1.000_001 })
}

private func expectInvalidNativeOpen(
    loopback: Int32,
    endpointID: String?,
    selectDefault: Int32
) {
    let collector = NativePacketCollector()
    let user = Unmanaged.passUnretained(collector).toOpaque()
    var capture: OpaquePointer?
    var sampleRate: UInt32 = 123
    var channels: UInt32 = 123
    var cleanupErrors = mja_capture_cleanup_errors(stop: 0, environment: 0, context: 0)

    let result: Int32
    if let endpointID {
        result = endpointID.withCString { endpointPointer in
            mja_capture_open(
                loopback,
                endpointPointer,
                selectDefault,
                nativePacketTrampoline,
                nativeHealthTrampoline,
                user,
                &capture,
                &sampleRate,
                &channels,
                &cleanupErrors
            )
        }
    } else {
        result = mja_capture_open(
            loopback,
            nil,
            selectDefault,
            nativePacketTrampoline,
            nativeHealthTrampoline,
            user,
            &capture,
            &sampleRate,
            &channels,
            &cleanupErrors
        )
    }

    #expect(result != 0)
    #expect(capture == nil)
    #expect(sampleRate == 0)
    #expect(channels == 0)
    #expect(cleanupErrors.stop == 0)
    #expect(cleanupErrors.environment == 0)
    #expect(cleanupErrors.context == 0)
    #expect(collector.packets.isEmpty)
}

struct WindowsNativeCapturePacketTests {
    @Test("native f32 packets split at 512 frames and preserve coordinates and samples")
    func nativePacketFragmentsPreserveOriginalMetadataAndFeedIngress() throws {
        for (sampleRate, channels) in [(44_100.0, 3), (48_000.0, 2)] {
            let harness = try NativeIngressHarness(sampleRate: sampleRate, channels: channels)
            let channelCount = Int(channels)
            let samples = (0..<(1_025 * channelCount)).map { index in
                Float((index % 31) - 15) / 32
            }
            let collector = NativePacketCollector(ingress: harness.ingress)
            let flags: UInt32 = 1
            let devicePosition: UInt64 = 3_000
            let qpc100ns: UInt64 = 10_000_000

            let result = convertBorrowedFloatPacket(
                samples,
                sampleRate: UInt32(sampleRate),
                channels: UInt32(channels),
                packetFrames: 1_025,
                flags: flags,
                devicePosition: devicePosition,
                qpc100ns: qpc100ns,
                collector: collector
            )

            #expect(result == 0)
            #expect(collector.packets.map(\.frameCount) == [512, 512, 1])
            #expect(collector.packets.map(\.packetOffset) == [0, 512, 1_024])
            #expect(collector.packets.map(\.packetFrames) == [1_025, 1_025, 1_025])
            #expect(collector.packets.map(\.channels) == Array(repeating: UInt32(channels), count: 3))
            #expect(collector.packets.map(\.sampleRate) == Array(repeating: UInt32(sampleRate), count: 3))
            #expect(collector.packets.map(\.flags) == Array(repeating: flags, count: 3))
            #expect(collector.packets.map(\.devicePosition) == Array(repeating: devicePosition, count: 3))
            #expect(collector.packets.map(\.qpc100ns) == Array(repeating: qpc100ns, count: 3))
            #expect(collector.packets.compactMap(\.samples).flatMap { $0 } == samples)

            let blocks = drain(harness.ring)
            let expectedMeans = (0..<1_025).map { frame in
                (0..<channelCount).reduce(Float.zero) { sum, channel in
                    sum + samples[frame * channelCount + channel]
                } / Float(channelCount)
            }
            #expect(harness.ingress.failure == nil)
            #expect(harness.sink.lastEndFrame == 1_025)
            #expect(blocks.map(\.startFrame) == [0, 512, 1_024])
            #expect(blocks.map(\.frameCount) == [512, 512, 1])
            #expect(blocks.flatMap(\.samples) == expectedMeans)
            #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        }
    }

    @Test("native PCM conversion normalizes all supported formats")
    func nativePCMFormatsConvertToNormalizedFloatSamples() {
        let cases: [(mja_capture_pcm_format, [UInt8], UInt32, [Float])] = [
            (MJA_CAPTURE_PCM_U8, [0, 128, 255], 3, [-1, 0, Float(127) / 128]),
            (MJA_CAPTURE_PCM_S16, [0x00, 0x80, 0x00, 0x00, 0xff, 0x7f], 3,
             [-1, 0, Float(32_767) / 32_768]),
            (MJA_CAPTURE_PCM_S24,
             [0x00, 0x00, 0x80, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0xff, 0xff, 0x7f],
             4, [-1, -Float(1) / 8_388_608, 0, Float(8_388_607) / 8_388_608]),
            (MJA_CAPTURE_PCM_S32,
             [0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x7f],
             3, [-1, 0, 1])
        ]

        for (format, bytes, frameCount, expected) in cases {
            let collector = NativePacketCollector()
            let result = convertBorrowedBytes(
                bytes,
                format: format,
                sampleRate: 48_000,
                channels: 1,
                packetFrames: frameCount,
                flags: 0,
                devicePosition: 71,
                qpc100ns: 10_000_000,
                collector: collector
            )
            #expect(result == 0)
            #expect(collector.packets.count == 1)
            expectNormalizedPCM(collector.packets[0].samples, expected: expected)
        }

        let floatValues: [Float] = [-1, -0.5, 0, 0.125, 1]
        let floatCollector = NativePacketCollector()
        let floatResult = convertBorrowedFloatPacket(
            floatValues,
            sampleRate: 48_000,
            channels: 1,
            packetFrames: UInt32(floatValues.count),
            flags: 0,
            devicePosition: 72,
            qpc100ns: 10_000_000,
            collector: floatCollector
        )
        #expect(floatResult == 0)
        #expect(floatCollector.packets.count == 1)
        #expect(floatCollector.packets[0].samples == floatValues)
        #expect(floatCollector.packets[0].samples?.allSatisfy { (-1...1).contains($0) } == true)
    }

    @Test("silent native packets use nil samples and become valid ring silence")
    func silentNativePacketPreservesMetadataWithoutCreatingGaps() throws {
        let harness = try NativeIngressHarness(sampleRate: 48_000, channels: 2)
        let collector = NativePacketCollector(ingress: harness.ingress)
        let flags: UInt32 = 2
        let devicePosition: UInt64 = 9_000
        let qpc100ns: UInt64 = 10_000_000
        let result = convertNativePacket(
            format: MJA_CAPTURE_PCM_F32,
            sampleRate: 48_000,
            channels: 2,
            nativeSamples: nil,
            packetFrames: 1_025,
            flags: flags,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            collector: collector
        )

        #expect(result == 0)
        #expect(collector.packets.map(\.samples) == [nil, nil, nil])
        #expect(collector.packets.map(\.frameCount) == [512, 512, 1])
        #expect(collector.packets.map(\.packetOffset) == [0, 512, 1_024])
        #expect(collector.packets.map(\.packetFrames) == [1_025, 1_025, 1_025])
        #expect(collector.packets.map(\.flags) == [flags, flags, flags])
        #expect(collector.packets.map(\.devicePosition) == [devicePosition, devicePosition, devicePosition])
        #expect(collector.packets.map(\.qpc100ns) == [qpc100ns, qpc100ns, qpc100ns])

        let blocks = drain(harness.ring)
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 1_025)
        #expect(harness.sink.invalidBufferCount.load(ordering: .relaxed) == 0)
        #expect(blocks.map(\.startFrame) == [0, 512, 1_024])
        #expect(blocks.flatMap(\.samples) == Array(repeating: 0, count: 1_025))
        #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
    }

    @Test("timestamp errors preserve native metadata and never fall back to contiguous frames")
    func timestampErrorIsForwardedAndFatalToIngress() throws {
        let harness = try NativeIngressHarness(sampleRate: 48_000, channels: 1)
        let collector = NativePacketCollector(ingress: harness.ingress)
        let samples: [Float] = [0.25, -0.5]
        let flags: UInt32 = 4
        let devicePosition: UInt64 = 77
        let qpc100ns: UInt64 = 9_999_999
        let result = convertBorrowedFloatPacket(
            samples,
            sampleRate: 48_000,
            channels: 1,
            packetFrames: 2,
            flags: flags,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            collector: collector
        )

        #expect(result == 0)
        #expect(collector.packets == [NativePacketSnapshot(
            samples: samples,
            frameCount: 2,
            channels: 1,
            sampleRate: 48_000,
            flags: flags,
            devicePosition: devicePosition,
            qpc100ns: qpc100ns,
            packetOffset: 0,
            packetFrames: 2
        )])
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(drain(harness.ring).isEmpty)
    }

    @Test("trustworthy discontinuity restart preserves the QPC gap in the ring")
    func trustworthyDeviceRestartKeepsHostTimelineGap() throws {
        let harness = try NativeIngressHarness(sampleRate: 48_000, channels: 1)
        let collector = NativePacketCollector(ingress: harness.ingress)
        let firstResult = convertBorrowedFloatPacket(
            [0.25, 0.25, 0.25, 0.25],
            sampleRate: 48_000,
            channels: 1,
            packetFrames: 4,
            flags: 0,
            devicePosition: 100,
            qpc100ns: 10_000_000,
            collector: collector
        )
        let restartResult = convertBorrowedFloatPacket(
            [0.5, 0.5, 0.5, 0.5],
            sampleRate: 48_000,
            channels: 1,
            packetFrames: 4,
            flags: 1,
            devicePosition: 0,
            qpc100ns: 20_000_000,
            collector: collector
        )

        let blocks = drain(harness.ring)
        #expect(firstResult == 0)
        #expect(restartResult == 0)
        #expect(collector.packets.map(\.devicePosition) == [100, 0])
        #expect(collector.packets.map(\.qpc100ns) == [10_000_000, 20_000_000])
        #expect(collector.packets.map(\.flags) == [0, 1])
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 48_004)
        #expect(blocks.map(\.startFrame) == [0, 48_000])
        #expect(blocks.map(\.samples) == [[0.25, 0.25, 0.25, 0.25], [0.5, 0.5, 0.5, 0.5]])
        #expect(harness.ring.dropoutCount > 0)
    }

    @Test("unflagged and untrustworthy device restarts fail without fallback")
    func unflaggedOrUntrustworthyDeviceRestartIsFatal() throws {
        for (restartFlags, restartQPC) in [(UInt32(0), UInt64(20_000_000)), (UInt32(1), UInt64(10_000_001))] {
            let harness = try NativeIngressHarness(sampleRate: 48_000, channels: 1)
            let collector = NativePacketCollector(ingress: harness.ingress)
            let firstResult = convertBorrowedFloatPacket(
                [0.25, 0.25, 0.25, 0.25],
                sampleRate: 48_000,
                channels: 1,
                packetFrames: 4,
                flags: 0,
                devicePosition: 100,
                qpc100ns: 10_000_000,
                collector: collector
            )
            let restartResult = convertBorrowedFloatPacket(
                [0.5, 0.5, 0.5, 0.5],
                sampleRate: 48_000,
                channels: 1,
                packetFrames: 4,
                flags: restartFlags,
                devicePosition: 0,
                qpc100ns: restartQPC,
                collector: collector
            )

            #expect(firstResult == 0)
            #expect(restartResult == 0)
            #expect(collector.packets.count == 2)
            #expect(harness.ingress.failure == .timestamp)
            #expect(harness.sink.lastEndFrame == 4)
            let blocks = drain(harness.ring)
            #expect(blocks.map(\.startFrame) == [0])
            #expect(blocks.flatMap(\.samples) == [0.25, 0.25, 0.25, 0.25])
        }
    }

    @Test("invalid native format arguments fail without packet callbacks")
    func invalidNativeConverterArgumentsDoNotCallBack() {
        let samples: [Float] = [0.25]

        let zeroChannels = NativePacketCollector()
        let zeroChannelsResult = samples.withUnsafeBufferPointer { buffer in
            convertNativePacket(
                format: MJA_CAPTURE_PCM_F32,
                sampleRate: 48_000,
                channels: 0,
                nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
                packetFrames: 1,
                flags: 0,
                devicePosition: 0,
                qpc100ns: 10_000_000,
                collector: zeroChannels
            )
        }
        #expect(zeroChannelsResult != 0)
        #expect(zeroChannels.packets.isEmpty)

        let tooManyChannels = NativePacketCollector()
        let tooManyChannelsResult = samples.withUnsafeBufferPointer { buffer in
            convertNativePacket(
                format: MJA_CAPTURE_PCM_F32,
                sampleRate: 48_000,
                channels: 255,
                nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
                packetFrames: 1,
                flags: 0,
                devicePosition: 0,
                qpc100ns: 10_000_000,
                collector: tooManyChannels
            )
        }
        #expect(tooManyChannelsResult != 0)
        #expect(tooManyChannels.packets.isEmpty)

        let zeroRate = NativePacketCollector()
        let zeroRateResult = samples.withUnsafeBufferPointer { buffer in
            convertNativePacket(
                format: MJA_CAPTURE_PCM_F32,
                sampleRate: 0,
                channels: 1,
                nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
                packetFrames: 1,
                flags: 0,
                devicePosition: 0,
                qpc100ns: 10_000_000,
                collector: zeroRate
            )
        }
        #expect(zeroRateResult != 0)
        #expect(zeroRate.packets.isEmpty)

        let shortScratch = NativePacketCollector()
        let shortScratchResult = samples.withUnsafeBufferPointer { buffer in
            convertNativePacket(
                format: MJA_CAPTURE_PCM_F32,
                sampleRate: 48_000,
                channels: 2,
                nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
                packetFrames: 1,
                flags: 0,
                devicePosition: 0,
                qpc100ns: 10_000_000,
                scratchSampleCapacity: 1_023,
                collector: shortScratch
            )
        }
        #expect(shortScratchResult != 0)
        #expect(shortScratch.packets.isEmpty)

        let unknownFlags = NativePacketCollector()
        let unknownFlagsResult = samples.withUnsafeBufferPointer { buffer in
            convertNativePacket(
                format: MJA_CAPTURE_PCM_F32,
                sampleRate: 48_000,
                channels: 1,
                nativeSamples: UnsafeRawPointer(buffer.baseAddress!),
                packetFrames: 1,
                flags: 16,
                devicePosition: 0,
                qpc100ns: 10_000_000,
                collector: unknownFlags
            )
        }
        #expect(unknownFlagsResult != 0)
        #expect(unknownFlags.packets.isEmpty)
    }

    @Test("nonfinite float input fails before any split fragment callback")
    func nonfiniteFirstFloatRejectsPacketBeforeCallback() {
        let samples = [Float.nan] + Array(repeating: Float(0.25), count: 512)
        let collector = NativePacketCollector()
        let result = convertBorrowedFloatPacket(
            samples,
            sampleRate: 48_000,
            channels: 1,
            packetFrames: 513,
            flags: 0,
            devicePosition: 10,
            qpc100ns: 10_000_000,
            collector: collector
        )

        #expect(result != 0)
        #expect(collector.packets.isEmpty)
    }

    @Test("invalid native enumeration and open selections fail before hardware access")
    func invalidNativeSelectionArgumentsAreRejectedBeforeHardware() {
        let deviceProbe = NativeDeviceCallbackProbe()
        let deviceUser = Unmanaged.passUnretained(deviceProbe).toOpaque()
        let enumerateResult = mja_capture_enumerate(2, nativeDeviceTrampoline, deviceUser)
        #expect(enumerateResult != 0)
        #expect(deviceProbe.callbackCount == 0)

        // These are all rejected by argument validation before context creation or endpoint lookup.
        expectInvalidNativeOpen(loopback: 2, endpointID: nil, selectDefault: 1)
        expectInvalidNativeOpen(loopback: 0, endpointID: "unexpected", selectDefault: 1)
        expectInvalidNativeOpen(loopback: 0, endpointID: nil, selectDefault: 0)
        expectInvalidNativeOpen(loopback: 0, endpointID: "", selectDefault: 0)
        expectInvalidNativeOpen(loopback: 0, endpointID: nil, selectDefault: 2)
    }

    @Test("capture open rejects null cleanup diagnostics before hardware")
    func captureOpenRejectsMissingCleanupDiagnosticsBeforeHardware() {
        let collector = NativePacketCollector()
        let user = Unmanaged.passUnretained(collector).toOpaque()
        var capture: OpaquePointer?
        var sampleRate: UInt32 = 123
        var channels: UInt32 = 123

        let result = mja_capture_open(
            0,
            nil,
            1,
            nativePacketTrampoline,
            nativeHealthTrampoline,
            user,
            &capture,
            &sampleRate,
            &channels,
            nil
        )

        #expect(result != 0)
        #expect(capture == nil)
        #expect(sampleRate == 0)
        #expect(channels == 0)
        #expect(collector.packets.isEmpty)
    }

    @Test("power APIs reject invalid output, owner, and diagnostics without an owner thread")
    func invalidPowerArgumentsRejectBeforeOwnerThreadCreation() {
        var acquireErrors = mja_power_errors(startup: 0, wait: 0, clear: 0, cleanup: 0)
        let acquireWithoutOutput = mja_power_acquire(nil, &acquireErrors)
        #expect(acquireWithoutOutput != 0)
        #expect(acquireErrors.startup == 0)
        #expect(acquireErrors.wait == 0)
        #expect(acquireErrors.clear == 0)
        #expect(acquireErrors.cleanup == 0)

        var ownerWithoutDiagnostics: OpaquePointer?
        let acquireWithoutDiagnostics = mja_power_acquire(&ownerWithoutDiagnostics, nil)
        #expect(acquireWithoutDiagnostics != 0)
        #expect(ownerWithoutDiagnostics == nil)

        var releaseErrors = mja_power_errors(startup: 0, wait: 0, clear: 0, cleanup: 0)
        let releaseWithoutOwner = mja_power_release(nil, &releaseErrors)
        #expect(releaseWithoutOwner != 0)
        #expect(releaseErrors.startup == 0)
        #expect(releaseErrors.wait == 0)
        #expect(releaseErrors.clear == 0)
        #expect(releaseErrors.cleanup == 0)

        let releaseWithoutDiagnostics = mja_power_release(nil, nil)
        #expect(releaseWithoutDiagnostics != 0)
    }
}
#endif
