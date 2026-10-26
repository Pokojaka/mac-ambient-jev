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

private func makeDurableIngressDrain(
    ring: AudioBlockRing
) throws -> (directory: URL, drain: AudioCaptureDrain) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "WindowsCaptureIngress-\(UUID().uuidString)", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: directory, chunkDurationSeconds: 1, sessionURL: directory
    )
    let captureDrain = AudioCaptureDrain(
        ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: 16_000)
    )
    return (directory, captureDrain)
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

    @Test func testFirstBufferQPCIsLatchedOnceFromFirstValidPacket() throws {
        let harness = try makeIngress()
        receive(harness.ingress, samples: [0.25], frameCount: 1, qpc100ns: 10_000_000)
        #expect(harness.ingress.firstBufferQPC100ns == 10_000_000)
        #expect(harness.ingress.firstBufferTime == 10)

        harness.clock.setMillis(11_000)
        receive(
            harness.ingress, samples: [0.5], frameCount: 1,
            devicePosition: 1, qpc100ns: 10_000_208
        )

        #expect(harness.ingress.firstBufferQPC100ns == 10_000_000)
        #expect(harness.ingress.firstBufferTime == 10)
    }

    @Test func testInvalidPacketDoesNotLatchFirstBufferQPC() throws {
        let harness = try makeIngress()
        receive(harness.ingress, samples: [0.25], frameCount: 1, flags: 16)

        #expect(harness.ingress.failure == .invalidPacket)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
        #expect(harness.ingress.firstBufferTime == nil)
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
        #expect(harness.ingress.firstBufferQPC100ns == 20_000_000)
    }

    @Test func testMicrophoneHealthNeverSynthesizesIdleSilence() throws {
        let harness = try makeIngress(loopback: false)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(!(harness.ingress.isReady))
    }

    @Test func testReconnectPreparationRejectsMicrophoneWithoutWriting() throws {
        let harness = try makeIngress(loopback: false)

        #expect(throws: (any Error).self) {
            try harness.ingress.prepareReconnect(startQPC100ns: 10_000_000)
        }

        #expect(harness.sink.lastEndFrame == 0)
        #expect(drain(harness.ring).isEmpty)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
    }

    @Test func testReconnectPreparationRejectsDuplicateWithoutWriting() throws {
        let harness = try makeIngress(loopback: true)
        try harness.ingress.prepareReconnect(startQPC100ns: 10_000_000)

        #expect(throws: (any Error).self) {
            try harness.ingress.prepareReconnect(startQPC100ns: 10_000_000)
        }

        #expect(harness.sink.lastEndFrame == 0)
        #expect(harness.ring.dropoutCount == 0)
        #expect(drain(harness.ring).isEmpty)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
    }

    @Test func testReconnectPreparationRejectsHealthActivityWithoutWriting() throws {
        let harness = try makeIngress(loopback: true)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)

        #expect(throws: (any Error).self) {
            try harness.ingress.prepareReconnect(startQPC100ns: 10_000_000)
        }

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(harness.ring.dropoutCount == 0)
        #expect(drain(harness.ring).isEmpty)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
    }

    @Test func testReconnectPreparationRejectsPacketActivityAfterDeliveredPacket() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [0.25, -0.5], frameCount: 2)
        let deliveredBlocks = drain(harness.ring)
        #expect(deliveredBlocks.map(\.startFrame) == [0])
        #expect(deliveredBlocks.flatMap(\.samples) == [0.25, -0.5])
        let endAfterPacket = harness.sink.lastEndFrame

        #expect(throws: (any Error).self) {
            try harness.ingress.prepareReconnect(startQPC100ns: 10_000_000)
        }

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == endAfterPacket)
        #expect(drain(harness.ring).isEmpty)
        #expect(harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == 10_000_000)
    }

    @Test func testReconnectPreparationRejectsQPCBeforeEpochWithoutWriting() throws {
        let harness = try makeIngress(loopback: true)

        #expect(throws: (any Error).self) {
            try harness.ingress.prepareReconnect(startQPC100ns: 9_999_999)
        }

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(harness.ring.dropoutCount == 0)
        #expect(drain(harness.ring).isEmpty)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
    }

    @Test func testPreparedLoopbackDefersTimelineGapUntilFirstPacket() throws {
        let harness = try makeIngress(
            sampleRate: 16_000, channels: 1, loopback: true,
            epoch: 1_000_000_000, startMillis: 105_000
        )
        try harness.ingress.prepareReconnect(startQPC100ns: 1_050_000_000)

        #expect(harness.sink.lastEndFrame == 0)
        #expect(harness.ring.dropoutCount == 0)
        #expect(drain(harness.ring).isEmpty)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)

        receive(
            harness.ingress, samples: [0.25, -0.5], frameCount: 2,
            sampleRate: 16_000, qpc100ns: 1_051_250_000
        )
        let blocks = drain(harness.ring)

        #expect(blocks.count == 1)
        #expect(blocks.map(\.startFrame) == [82_000])
        #expect(blocks.flatMap(\.samples) == [0.25, -0.5])
        #expect(harness.ring.dropoutCount == 1)
        #expect(harness.sink.lastEndFrame == 82_002)
        #expect(harness.ingress.firstBufferQPC100ns == 1_051_250_000)
        #expect(harness.ingress.isReady)
    }

    @Test func testFirstPacketAfterFreshIdleHealthFillsDeliveryGraceWithoutGap() async throws {
        let harness = try makeIngress(
            sampleRate: 16_000, channels: 1, loopback: true, epoch: 10_000_000,
            ringCapacity: 64
        )
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }

        harness.ingress.health(watermarkQPC100ns: 15_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [0.25, -0.5], frameCount: 2,
            sampleRate: 16_000, qpc100ns: 15_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 8_002)
        #expect(harness.ring.dropoutCount == 0)
        let checkpoint = try await durable.drain.finish()
        #expect(checkpoint.committedFrames == 8_002)
        #expect(checkpoint.gapEvents.isEmpty)
        #expect(harness.ring.dropoutCount == 0)
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<8_002)
        #expect(samples.count == 8_002)
        #expect(samples[..<8_000].allSatisfy { $0 == 0 })
        #expect(Array(samples[8_000...]) == [0.25, -0.5])
    }

    @Test func testFirstPacketAfterPreparedReconnectHealthFillsDeliveryGrace() async throws {
        let harness = try makeIngress(
            sampleRate: 16_000, channels: 1, loopback: true, epoch: 10_000_000,
            ringCapacity: 64
        )
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        try harness.ingress.prepareReconnect(startQPC100ns: 60_000_000)

        harness.ingress.health(watermarkQPC100ns: 65_000_000, outputState: 0, error: 0)
        #expect(harness.sink.lastEndFrame == 84_000)
        receive(
            harness.ingress, samples: [0.25, -0.5], frameCount: 2,
            sampleRate: 16_000, qpc100ns: 65_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 88_002)
        #expect(harness.ring.dropoutCount == 1)
        let checkpoint = try await durable.drain.finish()
        #expect(checkpoint.committedFrames == 88_002)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 0, frameCount: 80_000, reason: .missingCallback)
        ])
        #expect(harness.ring.dropoutCount == 1)
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<88_002)
        #expect(samples.count == 88_002)
        #expect(samples[..<88_000].allSatisfy { $0 == 0 })
        #expect(Array(samples[88_000...]) == [0.25, -0.5])
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

    @Test func testHeartbeatsWithoutFirstBufferTimeOutForBothSources() throws {
        for loopback in [false, true] {
            let harness = try makeIngress(loopback: loopback, startMillis: 10_000)
            harness.ingress.health(
                watermarkQPC100ns: 10_000_000, outputState: 0, error: 0
            )
            harness.clock.setMillis(12_999)
            harness.ingress.health(
                watermarkQPC100ns: 10_000_000, outputState: 0, error: 0
            )
            #expect(harness.ingress.poll(now: 12.999) == nil)

            harness.clock.setMillis(13_000)
            harness.ingress.health(
                watermarkQPC100ns: 10_000_000, outputState: 0, error: 0
            )
            #expect(!(harness.ingress.isReady))
            #expect(harness.ingress.poll(now: 13.0) == .workerStall)
        }
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
        // The watermark minus the 250 ms delivery grace: 48,000 - 12,000 frames.
        #expect(harness.sink.lastEndFrame == 36_000)
    }

    @Test func testBurstTailArrivingAfterIdleObservationIsNotMarkedMissing() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000, ringCapacity: 128)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        let head = [Float](repeating: 0.5, count: 40_000)
        receive(harness.ingress, samples: head, frameCount: 512, packetFrames: 512)
        for index in 1..<78 {
            receive(
                harness.ingress, samples: Array(head.prefix(512)), frameCount: 512,
                devicePosition: UInt64(index * 512),
                qpc100ns: 10_000_000 + UInt64(index * 512 * 10_000_000 / 48_000)
            )
        }
        let endOfDeliveredAudio = harness.sink.lastEndFrame
        #expect(endOfDeliveredAudio == 39_936)
        harness.clock.setMillis(11_000)
        // Idle is observed at 1 s; the packets for the last 0.2 s of the burst are still in flight.
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        #expect(harness.ingress.failure == nil)
        for index in 78..<90 {
            receive(
                harness.ingress, samples: Array(head.prefix(512)), frameCount: 512,
                devicePosition: UInt64(index * 512),
                qpc100ns: 10_000_000 + UInt64(index * 512 * 10_000_000 / 48_000)
            )
        }

        #expect(harness.ingress.failure == nil)
        let blocks = drain(harness.ring)
        #expect(blocks.allSatisfy { $0.gap == nil })
        let lastBlock = try #require(blocks.last)
        #expect(lastBlock.startFrame + Int64(lastBlock.samples.count) == Int64(90 * 512))
        #expect(blocks.flatMap(\.samples).allSatisfy { $0 == 0.5 })
    }

    @Test func testTailThatNeverArrivesBecomesOneGapAfterTheGrace() throws {
        let harness = try makeIngress(loopback: true, startMillis: 10_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(harness.ingress, samples: [Float](repeating: 0.5, count: 24_000), frameCount: 512, packetFrames: 512)
        harness.clock.setMillis(11_000)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 36_000)
        let gaps = drain(harness.ring).compactMap(\.gap)
        #expect(gaps.count == 1)
        #expect(gaps.first?.startFrame == 512)
        #expect(gaps.first?.endFrame == 36_000)
    }

    @Test func testLoopbackResumesAfterIdleWithoutDiscontinuityFlag() throws {
        let harness = try makeIngress(loopback: true, ringCapacity: 256)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480, devicePosition: 0)
        harness.clock.setMillis(11_000)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        // Two seconds of idle: QPC advanced, the device position advanced only by delivered frames.
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 96_480)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.sink.invalidBufferCount.load(ordering: .relaxed) == 0)
        let blocks = drain(harness.ring)
        #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        let samples = blocks.flatMap(\.samples)
        #expect(samples.count == 96_480)
        #expect(samples[..<480].allSatisfy { $0 == 0.25 })
        #expect(samples[480..<96_000].allSatisfy { $0 == 0 })
        #expect(samples[96_000..<96_480].allSatisfy { $0 == 0.75 })
    }

    @Test func testFlaggedIdleLoopbackForwardMismatchFillsSilenceWithoutGap() throws {
        let harness = try makeIngress(loopback: true, ringCapacity: 256)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            flags: 1, devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 96_480)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ring.dropoutCount == 0)
        let blocks = drain(harness.ring)
        #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        let samples = blocks.flatMap(\.samples)
        #expect(samples.count == 96_480)
        #expect(samples[..<480].allSatisfy { $0 == 0.25 })
        #expect(samples[480..<96_000].allSatisfy { $0 == 0 })
        #expect(samples[96_000..<96_480].allSatisfy { $0 == 0.75 })
    }

    @Test func testFlaggedIdleLoopbackDeviceResetFillsSilenceWithoutGap() throws {
        let harness = try makeIngress(loopback: true, ringCapacity: 256)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480,
            devicePosition: 100
        )
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            flags: 1, devicePosition: 0, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 96_480)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ring.dropoutCount == 0)
        let blocks = drain(harness.ring)
        #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        let samples = blocks.flatMap(\.samples)
        #expect(samples.count == 96_480)
        #expect(samples[..<480].allSatisfy { $0 == 0.25 })
        #expect(samples[480..<96_000].allSatisfy { $0 == 0 })
        #expect(samples[96_000..<96_480].allSatisfy { $0 == 0.75 })
    }

    @Test func testIdleLoopbackForwardReanchorAtThreeSecondsFailsSuspended() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 40_100_000
        )

        #expect(harness.ingress.failure == .suspended)
        #expect(harness.sink.lastEndFrame == 480)
    }

    @Test func testActiveLoopbackUnflaggedForwardJumpFails() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == 480)
    }

    @Test func testLoopbackUnflaggedForwardJumpWithoutHealthFails() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == 480)
    }

    @Test func testFlaggedActiveLoopbackForwardJumpRemainsAccepted() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            flags: 1, devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 96_480)
        let blocks = drain(harness.ring)
        #expect(blocks.map(\.startFrame) == [0, 96_000])
    }

    @Test func testRealPacketOverlappingSynthesizedSilenceFailsBeforeWrite() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 10_100_000
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == endAfterSilence)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test func testRealPacketOverlappingSynthesizedMissingFailsBeforeWrite() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [0.25], frameCount: 1)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        harness.clock.setMillis(11_000)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        let endAfterMissing = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [0.75], frameCount: 1,
            devicePosition: 1, qpc100ns: 10_000_208
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == endAfterMissing)
        #expect(harness.sink.invalidBufferCount.load(ordering: .relaxed) == 1)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test func testZeroValuedRealPacketOverlappingSynthesizedSilenceFails() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [0.25], frameCount: 1)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(harness.ingress, samples: [0], frameCount: 1, devicePosition: 1)

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == endAfterSilence)
        #expect(harness.sink.invalidBufferCount.load(ordering: .relaxed) == 0)
    }

    @Test func testDeviceResetGuardUsesSinkEndBeyondPreviousPacketEnd() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [1, 1, 1, 1], frameCount: 4, devicePosition: 100)
        harness.ingress.health(watermarkQPC100ns: 18_333_333, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [2, 2, 2, 2], frameCount: 4,
            flags: 1, devicePosition: 0, qpc100ns: 14_166_667
        )

        #expect(endAfterSilence > 20_000)
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == endAfterSilence)
    }

    @Test func testForwardReanchorGuardUsesSinkEndBeyondPreviousPacketEnd() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [1, 1, 1, 1], frameCount: 4, devicePosition: 100)
        harness.ingress.health(watermarkQPC100ns: 18_333_333, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [2, 2, 2, 2], frameCount: 4,
            devicePosition: 104, qpc100ns: 14_166_667
        )

        #expect(endAfterSilence > 20_000)
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.sink.lastEndFrame == endAfterSilence)
    }

    @Test func testMicrophoneForwardQPCJumpWithoutFlagStillFails() throws {
        let harness = try makeIngress(loopback: false)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480, devicePosition: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 30_000_000
        )

        #expect(harness.ingress.failure == .timestamp)
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
