import Foundation
import Synchronization
import Testing
@testable import MacAmbientJevWindowsSupport
import MacAmbientJevCore
import MacAmbientJevPipeline

private final class IngressTestClock: CaptureClock, @unchecked Sendable {
    private let millis: Atomic<Int64>

    init(millis: Int64 = 10_000) {
        self.millis = Atomic(millis)
    }

    func now() -> TimeInterval {
        Double(millis.load(ordering: .acquiring)) / 1_000
    }

    func setMillis(_ value: Int64) {
        millis.store(value, ordering: .releasing)
    }
}

private struct IngressHarness {
    let ingress: WindowsCaptureIngress
    let sink: TimestampedMonoSink
    let ring: AudioBlockRing
    let clock: IngressTestClock
}

// Helper defaults simplify fixture construction only; production capture configuration remains explicit.
private func makeIngress(
    sampleRate: Double = 48_000,
    channels: Int = 1,
    loopback: Bool = false,
    epoch: UInt64 = 10_000_000,
    startMillis: Int64 = 10_000,
    ringCapacity: Int = 64,
    blockFrameCapacity: Int = 512,
    sinkFrameCapacity: Int = 512
) throws -> IngressHarness {
    let clock = IngressTestClock(millis: startMillis)
    let ring = AudioBlockRing(
        capacity: ringCapacity, blockFrameCapacity: blockFrameCapacity,
        sampleRate: sampleRate
    )
    let sink = TimestampedMonoSink(
        ring: ring, frameCapacity: sinkFrameCapacity, clock: clock, meter: nil
    )
    let ingress = try WindowsCaptureIngress(
        sink: sink, sampleRate: sampleRate, channels: channels,
        epochQPC100ns: epoch, clock: clock, loopback: loopback
    )
    return IngressHarness(ingress: ingress, sink: sink, ring: ring, clock: clock)
}

private func receive(
    _ ingress: WindowsCaptureIngress,
    samples: [Float]?,
    frameCount: Int,
    channels: Int = 1,
    sampleRate: Double = 48_000,
    flags: UInt32 = 0,
    devicePosition: UInt64 = 0,
    qpc100ns: UInt64 = 10_000_000,
    packetOffset: Int = 0,
    packetFrames: Int? = nil
) {
    let packet = WindowsCapturePacket(
        samples: nil, frameCount: frameCount, channels: channels,
        sampleRate: sampleRate, flags: flags, devicePosition: devicePosition,
        qpc100ns: qpc100ns, packetOffset: packetOffset,
        packetFrames: packetFrames ?? frameCount
    )
    guard let samples else {
        ingress.receive(packet)
        return
    }
    samples.withUnsafeBufferPointer { buffer in
        let packetWithSamples = WindowsCapturePacket(
            samples: UnsafePointer(buffer.baseAddress!), frameCount: frameCount,
            channels: channels, sampleRate: sampleRate, flags: flags,
            devicePosition: devicePosition, qpc100ns: qpc100ns,
            packetOffset: packetOffset, packetFrames: packetFrames ?? frameCount
        )
        ingress.receive(packetWithSamples)
    }
}

private func drain(_ ring: AudioBlockRing) -> [AudioBlock] {
    var result: [AudioBlock] = []
    while let block = ring.pop() { result.append(block) }
    return result
}

struct WindowsCaptureIngressTests {
    @Test func testMultichannelMeansAt44100And48000Hz() throws {
        for (rate, channelCount) in [(44_100.0, 3), (48_000.0, 4)] {
            let harness = try makeIngress(sampleRate: rate, channels: channelCount)
            let frameValues: [[Float]] = [
                [0.1, 0.3, 0.5, 0.7],
                [-0.4, 0.2, 0.6, 1.0]
            ]
            let packed = frameValues.flatMap { Array($0.prefix(channelCount)) }
            receive(
                harness.ingress, samples: packed, frameCount: 2, channels: channelCount,
                sampleRate: rate, devicePosition: 9_000
            )

            #expect(harness.ingress.failure == nil)
            #expect(harness.sink.lastEndFrame == 2)
            #expect(drain(harness.ring).flatMap(\.samples) == [
                frameValues[0].prefix(channelCount).reduce(0, +) / Float(channelCount),
                frameValues[1].prefix(channelCount).reduce(0, +) / Float(channelCount)
            ])
        }
    }

    @Test func testSplitFragmentsPreserveOriginalMetadataAndAdvanceByOffset() throws {
        let harness = try makeIngress(channels: 2)
        receive(
            harness.ingress, samples: [1, 3, 2, 4], frameCount: 2, channels: 2,
            devicePosition: 800, packetFrames: 4
        )
        receive(
            harness.ingress, samples: [3, 5, 4, 6], frameCount: 2, channels: 2,
            devicePosition: 800, packetOffset: 2, packetFrames: 4
        )

        let blocks = drain(harness.ring)
        #expect(harness.ingress.failure == nil)
        #expect(blocks.map(\.startFrame) == [0, 2])
        #expect(blocks.flatMap(\.samples) == [2, 3, 4, 5])
    }

    @Test func testFirstQPCPacketKeepsEpochRelativeLeadingGap() throws {
        let harness = try makeIngress()
        receive(
            harness.ingress, samples: [0.25, 0.5], frameCount: 2,
            devicePosition: 42_000, qpc100ns: 20_000_000
        )

        let block = try #require(harness.ring.pop())
        #expect(block.startFrame == 48_000)
        #expect(harness.sink.lastEndFrame == 48_002)
    }

    @Test func testTimestampErrorFlagIsTerminalEvenWithPosition() throws {
        let harness = try makeIngress()
        receive(
            harness.ingress, samples: [0.25], frameCount: 1, flags: 4,
            devicePosition: 5, qpc100ns: 10_000_001
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(!(harness.ingress.isReady))
    }

    @Test func testUnflaggedDeviceRestartIsFatal() throws {
        let harness = try makeIngress()
        receive(harness.ingress, samples: [1, 1, 1, 1], frameCount: 4, devicePosition: 100)
        receive(
            harness.ingress, samples: [1, 1, 1, 1], frameCount: 4,
            devicePosition: 0, qpc100ns: 10_010_000
        )

        #expect(harness.ingress.failure == .timestamp)
    }

    @Test func testFlaggedButUntrustworthyRestartIsFatal() throws {
        let harness = try makeIngress()
        receive(
            harness.ingress, samples: [1, 1, 1, 1], frameCount: 4,
            devicePosition: 100, qpc100ns: 10_010_000
        )
        receive(
            harness.ingress, samples: [1, 1, 1, 1], frameCount: 4,
            flags: 1, devicePosition: 0, qpc100ns: 10_010_001
        )

        #expect(harness.ingress.failure == .timestamp)
    }

    @Test func testFlaggedTrustworthyRestartRetainsHostTimelineGap() throws {
        let harness = try makeIngress()
        receive(harness.ingress, samples: [1, 1, 1, 1], frameCount: 4, devicePosition: 100)
        receive(
            harness.ingress, samples: [2, 2, 2, 2], frameCount: 4,
            flags: 1, devicePosition: 0, qpc100ns: 20_000_000
        )

        let blocks = drain(harness.ring)
        #expect(harness.ingress.failure == nil)
        #expect(blocks.map(\.startFrame) == [0, 48_000])
    }

    @Test func testIdleLoopbackWatermarkCreatesAtMostHalfSecondSilence() throws {
        let harness = try makeIngress(loopback: true)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 24_000)
        let blocks = drain(harness.ring)
        #expect(blocks.reduce(0) { $0 + $1.samples.count } == 24_000)
        #expect(blocks.flatMap(\.samples).allSatisfy { $0 == 0 })
        #expect(harness.ingress.isReady)
    }

    @Test func testMicrophoneHealthNeverSynthesizesIdleSilence() throws {
        let harness = try makeIngress(loopback: false)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(!(harness.ingress.isReady))
    }

    @Test func testUnknownOutputStateIsTerminal() throws {
        let harness = try makeIngress(loopback: true)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 2, error: 0)

        #expect(harness.ingress.failure == .unknownOutput)
    }

    @Test func testNativeHealthFailureRetainsHRESULT() throws {
        let harness = try makeIngress(loopback: true)
        let hresult = Int32(bitPattern: 0x88890004)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: hresult)

        #expect(harness.ingress.failure == .native)
        #expect(harness.ingress.nativeErrorCode == hresult)
    }

    @Test func testHeartbeatStallIsDetectedAtThreeSeconds() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.poll(now: 12.999) == nil)
        #expect(harness.ingress.poll(now: 13.0) == .workerStall)
    }

    @Test func testEarlierConsumerClockSnapshotDoesNotFailHeartbeatRace() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000)
        harness.clock.setMillis(12_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.poll(now: 11.5) == nil)
        #expect(harness.ingress.failure == nil)
    }

    @Test func testIdleTransitionAfterActiveIntervalWithoutPacketsRecordsShortGap() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        harness.clock.setMillis(11_000)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 48_000)
    }

    @Test func testActiveOutputWithoutPacketsFailsAfterThreeSeconds() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        harness.clock.setMillis(11_500)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        harness.clock.setMillis(13_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)

        #expect(harness.ingress.failure == .activeOutputStall)
    }

    @Test func testAllZeroPacketIsValidAndSustainedSilenceUsesCaptureHealth() throws {
        let harness = try makeIngress(startMillis: 10_000)
        receive(harness.ingress, samples: [0, 0, 0, 0], frameCount: 4)

        #expect(harness.ingress.failure == nil)
        #expect(harness.ingress.isReady)
        #expect(harness.sink.lastEndFrame == 4)
        let silentSince = harness.sink.silentSinceMillis.load(ordering: .acquiring)
        #expect(silentSince > 0)
        #expect(!(CaptureHealth.isSilent(silentSinceMillis: silentSince, now: 39.999)))
        #expect(CaptureHealth.isSilent(silentSinceMillis: silentSince, now: 40.0))
    }

    @Test func testKnownMissingExtentUsesSinkMissingPath() throws {
        let harness = try makeIngress()
        receive(
            harness.ingress, samples: nil, frameCount: 3, flags: 8,
            devicePosition: 200, qpc100ns: 10_000_000
        )

        let block = try #require(harness.ring.pop())
        #expect(block.gap?.startFrame == 0)
        #expect(block.gap?.frameCount == 3)
        #expect(harness.sink.invalidBufferCount.load(ordering: .relaxed) == 1)
    }

    @Test func testOverflowPreservesRingTail() throws {
        let harness = try makeIngress(
            ringCapacity: 1, blockFrameCapacity: 2, sinkFrameCapacity: 2
        )
        receive(harness.ingress, samples: [1, 2, 3, 4], frameCount: 4)
        harness.ring.finish(tailFrame: harness.sink.lastEndFrame)

        #expect(harness.sink.lastEndFrame == 4)
        #expect(harness.ring.tailFrame == 4)
        #expect(harness.ring.overflowCount == 1)
        #expect(harness.ring.trailingGap?.startFrame == 2)
        #expect(harness.ring.trailingGap?.frameCount == 2)
    }
}
