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
    isInitialCapture: Bool = true,
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
        epochQPC100ns: epoch, clock: clock, loopback: loopback,
        isInitialCapture: isInitialCapture
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
    @Test(arguments: [false, true], [false, true])
    func testStartupLatencyIsSilenceButLaterMissingCallbackIsAGap(
        loopback: Bool, laterGap: Bool
    ) async throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: loopback)
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        harness.clock.setMillis(10_125)
        receive(
            harness.ingress, samples: [0.25, 0.5], frameCount: 2,
            sampleRate: 16_000, devicePosition: 42_000, qpc100ns: 11_250_000
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 2_002)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ingress.firstBufferQPC100ns == 11_250_000)
        if laterGap {
            receive(
                harness.ingress, samples: [-0.25, -0.5], frameCount: 2,
                sampleRate: 16_000, devicePosition: 42_400, qpc100ns: 11_500_000
            )
        }
        let checkpoint = try await durable.drain.finish()
        let endFrame: Int64 = laterGap ? 2_402 : 2_002
        #expect(checkpoint.committedFrames == endFrame)
        #expect(checkpoint.gapEvents == (laterGap ? [
            AudioGapEvent(startFrame: 2_002, frameCount: 398, reason: .missingCallback)
        ] : []))
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<endFrame)
        #expect(samples[..<2_000].allSatisfy { $0 == 0 })
        #expect(Array(samples[2_000..<2_002]) == [0.25, 0.5])
        if laterGap {
            #expect(samples[2_002..<2_400].allSatisfy { $0 == 0 })
            #expect(Array(samples[2_400...]) == [-0.25, -0.5])
        }
    }

    @Test func testMicrophoneReconnectLeadingSpanRemainsMissing() async throws {
        let harness = try makeIngress(sampleRate: 16_000, isInitialCapture: false)
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        receive(
            harness.ingress, samples: [0.25, 0.5], frameCount: 2,
            sampleRate: 16_000, qpc100ns: 11_250_000
        )
        let checkpoint = try await durable.drain.finish()
        #expect(harness.ingress.failure == nil)
        #expect(checkpoint.committedFrames == 2_002)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 0, frameCount: 2_000, reason: .missingCallback)
        ])
    }

    @Test(arguments: [false, true])
    func testStartupPaddingCannotCreateReadinessAtOrBeyondDeadline(lateArrival: Bool) throws {
        let harness = try makeIngress(sampleRate: 16_000)
        harness.clock.setMillis(lateArrival ? 13_000 : 10_125)
        receive(
            harness.ingress, samples: [0.25], frameCount: 1,
            sampleRate: 16_000, qpc100ns: lateArrival ? 11_250_000 : 40_000_000
        )
        #expect(harness.ingress.failure == (lateArrival ? .workerStall : .timestamp))
        if !lateArrival { #expect(harness.ingress.timestampCheck == .startupExtent) }
        #expect(harness.sink.lastEndFrame == 0)
        #expect(!harness.ingress.isReady)
        #expect(drain(harness.ring).isEmpty)
    }

    @Test func testKnownMissingFirstPacketDoesNotBecomeReadyViaStartupPadding() throws {
        let harness = try makeIngress(sampleRate: 16_000)
        receive(
            harness.ingress, samples: nil, frameCount: 2, sampleRate: 16_000,
            flags: 8, qpc100ns: 11_250_000
        )
        #expect(harness.ingress.failure == nil)
        #expect(!harness.ingress.isReady)
        #expect(harness.ingress.firstBufferQPC100ns == nil)
        #expect(harness.sink.lastEndFrame == 2_002)
        #expect(drain(harness.ring).allSatisfy { $0.samples.isEmpty })
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

    @Test(arguments: [false, true], [800, 4_000])
    func testPlaybackStartingAfterIdleHealthPreservesEveryPacket(
        activeBeforePacket: Bool, overlapFrames: Int
    ) async throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        // Two seconds without native packets; health commits through 1.75 seconds.
        for tick in 1...4 {
            harness.clock.setMillis(10_000 + Int64(tick * 500))
            harness.ingress.health(
                watermarkQPC100ns: 10_000_000 + UInt64(tick * 5_000_000),
                outputState: 0, error: 0
            )
        }
        let idleEnd = harness.sink.lastEndFrame
        #expect(idleEnd == 28_000)
        try await durable.drain.drainAvailable()
        if activeBeforePacket {
            harness.ingress.health(watermarkQPC100ns: 30_000_000, outputState: 1, error: 0)
        }
        // The stream starts at a nonzero device position. Its first QPC is slightly
        // behind the published idle boundary; every 100-ms packet is split into fragments.
        let firstQPC = UInt64(10_000_000 + (Int(idleEnd) - overlapFrames) * 625)
        let firstPosition: UInt64 = 123_456
        var expectedPCM: [Float] = []
        for packetIndex in 0..<10 {
            harness.clock.setMillis(12_100 + Int64(packetIndex * 100))
            let value: Float = packetIndex.isMultiple(of: 2) ? 0 : 0.25
            let pcm = [Float](repeating: value, count: 1_600)
            expectedPCM.append(contentsOf: pcm)
            for offset in stride(from: 0, to: pcm.count, by: 512) {
                let count = min(512, pcm.count - offset)
                receive(
                    harness.ingress, samples: Array(pcm[offset..<(offset + count)]),
                    frameCount: count, sampleRate: 16_000, flags: packetIndex == 0 ? 1 : 0,
                    devicePosition: firstPosition + UInt64(packetIndex * 1_600),
                    qpc100ns: firstQPC + UInt64(packetIndex * 1_000_000),
                    packetOffset: offset, packetFrames: 1_600
                )
            }
            harness.ingress.health(
                watermarkQPC100ns: 31_000_000 + UInt64(packetIndex * 1_000_000),
                outputState: 1, error: 0
            )
        }
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == idleEnd + 16_000)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ingress.firstBufferQPC100ns == 15_000_000)
        let checkpoint = try await durable.drain.finish()
        #expect(checkpoint.committedFrames == 44_000)
        #expect(checkpoint.gapEvents.isEmpty)
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<44_000)
        #expect(samples[..<28_000].allSatisfy { $0 == 0 })
        #expect(Array(samples[28_000...]) == expectedPCM)
    }

    @Test func testFirstPacketBeyondIdleReanchorGraceFailsWithoutWriting() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        #expect(harness.sink.lastEndFrame == 8_000)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1,
            sampleRate: 16_000, qpc100ns: 12_499_375
        )
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == .idleAnchorOverlap)
        #expect(harness.sink.lastEndFrame == 8_000)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test(arguments: [UInt64(13_900_000), UInt64(13_999_999), UInt64(14_050_000)])
    func testIdleReanchorDoesNotHideSubsequentInvalidTimestamps(secondQPC: UInt64) throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 160), frameCount: 160,
            sampleRate: 16_000, devicePosition: 100, qpc100ns: 14_000_000
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 8_160)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1,
            sampleRate: 16_000, devicePosition: 260, qpc100ns: secondQPC
        )
        let expectedCheck: WindowsCaptureTimestampCheck = secondQPC < 14_000_000
            ? .qpcRegression : .clockMismatch
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == expectedCheck)
        let details = harness.ingress.timestampDetails
        let expectedDelta: Int64 = secondQPC == 13_900_000 ? -160
            : (secondQPC == 13_999_999 ? 0 : 80)
        #expect(details.qpcDeltaFrames == expectedDelta)
        #expect(details.deviceDeltaFrames == 160)
        #expect(details.packetFlags == 0)
        #expect(!details.idleObserved)
        // A later error must not replace the first check's diagnostic.
        receive(harness.ingress, samples: nil, frameCount: 1, sampleRate: 16_000, flags: 4)
        #expect(harness.ingress.timestampCheck == expectedCheck)
        #expect(harness.ingress.timestampDetails == details)
        #expect(harness.sink.lastEndFrame == 8_160)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test func testIdleReanchorCannotMoveAcrossAnEarlierMissingExtent() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 1, error: 0)
        harness.ingress.health(watermarkQPC100ns: 22_000_000, outputState: 0, error: 0)
        harness.ingress.health(watermarkQPC100ns: 24_000_000, outputState: 0, error: 0)
        #expect(harness.sink.lastEndFrame == 18_400)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1,
            sampleRate: 16_000, qpc100ns: 19_000_000
        )
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == .idleAnchorOverlap)
        #expect(harness.sink.lastEndFrame == 18_400)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test func testMicrophoneHealthNeverSynthesizesIdleSilence() throws {
        let harness = try makeIngress(loopback: false)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 0)
        #expect(!(harness.ingress.isReady))
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

    @Test(arguments: [0, 800, 4_000])
    func testPlaybackResumesAfterSixSecondIdleWithActiveHealthBeforePacket(
        overlapFrames: Int
    ) async throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        for packetIndex in 0..<2 {
            receive(
                harness.ingress, samples: [Float](repeating: 0.25, count: 160),
                frameCount: 160, sampleRate: 16_000,
                devicePosition: UInt64(packetIndex * 160),
                qpc100ns: 10_000_000 + UInt64(packetIndex * 100_000)
            )
        }
        harness.clock.setMillis(10_020)
        harness.ingress.health(watermarkQPC100ns: 10_200_000, outputState: 1, error: 0)
        harness.ingress.health(watermarkQPC100ns: 10_200_000, outputState: 0, error: 0)
        for tick in 1...12 {
            harness.clock.setMillis(10_020 + Int64(tick * 500))
            harness.ingress.health(
                watermarkQPC100ns: 10_200_000 + UInt64(tick * 5_000_000),
                outputState: 0, error: 0
            )
            try await durable.drain.drainAvailable()
        }
        let idleEnd = harness.sink.lastEndFrame
        #expect(idleEnd == 92_320)
        harness.ingress.health(watermarkQPC100ns: 70_200_000, outputState: 1, error: 0)
        #expect(harness.sink.lastEndFrame == idleEnd)
        #expect(harness.ingress.poll(now: 16.02) == nil)
        let firstFrame = overlapFrames == 0 ? 96_320 : idleEnd - Int64(overlapFrames)
        let firstQPC = UInt64(10_000_000 + firstFrame * 625)
        let resumedStart = max(idleEnd, firstFrame)
        // A split first packet and subsequent device-contiguous packets must all survive,
        // including when raw QPC overlaps the already published idle silence.
        for packetIndex in 0..<3 {
            harness.clock.setMillis(16_020 + Int64(packetIndex * 10))
            for offset in [0, 80] {
                receive(
                    harness.ingress, samples: [Float](repeating: 0.75, count: 80),
                    frameCount: 80, sampleRate: 16_000,
                    devicePosition: UInt64(320 + packetIndex * 160),
                    qpc100ns: firstQPC + UInt64(packetIndex * 100_000),
                    packetOffset: offset, packetFrames: 160
                )
            }
            harness.ingress.health(
                watermarkQPC100ns: 70_300_000 + UInt64(packetIndex * 100_000),
                outputState: 1, error: 0
            )
        }
        // Playback stops again; the transition must not duplicate the idle fill or gap.
        harness.ingress.health(watermarkQPC100ns: 70_500_000, outputState: 0, error: 0)
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == resumedStart + 480)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.sink.invalidBufferCount.load(ordering: .acquiring) == 0)
        let checkpoint = try await durable.drain.finish()
        #expect(checkpoint.committedFrames == resumedStart + 480)
        #expect(checkpoint.gapEvents.isEmpty)
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<(resumedStart + 480))
        #expect(samples.count == Int(resumedStart) + 480)
        #expect(samples[..<320].allSatisfy { $0 == 0.25 })
        #expect(samples[320..<Int(resumedStart)].allSatisfy { $0 == 0 })
        #expect(samples[Int(resumedStart)...].allSatisfy { $0 == 0.75 })
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

    @Test(arguments: [false, true], [UInt32(0), UInt32(1)])
    func testLoopbackForwardJumpWithoutIdleEvidenceCountsOneMissingGap(
        activeHealth: Bool, flags: UInt32
    ) async throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        let durable = try makeDurableIngressDrain(ring: harness.ring)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 160),
            frameCount: 160, sampleRate: 16_000
        )
        if activeHealth {
            harness.clock.setMillis(10_010)
            harness.ingress.health(watermarkQPC100ns: 10_100_000, outputState: 1, error: 0)
            for tick in 1...4 {
                harness.clock.setMillis(10_010 + Int64(tick * 200))
                harness.ingress.health(
                    watermarkQPC100ns: 10_100_000 + UInt64(tick * 2_000_000),
                    outputState: 1, error: 0
                )
                #expect(harness.ingress.failure == nil)
                #expect(harness.sink.lastEndFrame == 160)
            }
        }
        for packetIndex in 0..<2 {
            harness.clock.setMillis(11_000 + Int64(packetIndex * 10))
            receive(
                harness.ingress, samples: [Float](repeating: 0.75, count: 160),
                frameCount: 160, sampleRate: 16_000, flags: packetIndex == 0 ? flags : 0,
                devicePosition: UInt64(160 + packetIndex * 160),
                qpc100ns: 20_000_000 + UInt64(packetIndex * 100_000)
            )
        }
        harness.ingress.health(watermarkQPC100ns: 20_200_000, outputState: 1, error: 0)

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 16_320)
        #expect(harness.ring.dropoutCount == 1)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.sink.invalidBufferCount.load(ordering: .acquiring) == 1)
        let checkpoint = try await durable.drain.finish()
        #expect(checkpoint.committedFrames == 16_320)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: 160, frameCount: 15_840, reason: .invalidBuffer)
        ])
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<16_320)
        #expect(samples[..<160].allSatisfy { $0 == 0.25 })
        #expect(samples[160..<16_000].allSatisfy { $0 == 0 })
        #expect(samples[16_000...].allSatisfy { $0 == 0.75 })
    }

    @Test(arguments: [UInt64(13_000_000), UInt64(20_000_000)])
    func testContinuousPacketOverlappingIdleSilenceStillFails(watermark: UInt64) throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480)
        harness.ingress.health(watermarkQPC100ns: watermark, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
            devicePosition: 480, qpc100ns: 10_100_000
        )

        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == .pcmOverlap)
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

    @Test(arguments: [false, true], [false, true])
    func testIdleDeviceResetAndForwardReanchorRequireBoundedIdleOverlap(
        resetDevice: Bool, withinGrace: Bool
    ) throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [1, 1, 1, 1], frameCount: 4, devicePosition: 100)
        harness.ingress.health(watermarkQPC100ns: 18_333_333, outputState: 0, error: 0)
        let endAfterSilence = harness.sink.lastEndFrame
        receive(
            harness.ingress, samples: [2, 2, 2, 2], frameCount: 4,
            flags: resetDevice ? 1 : 0, devicePosition: resetDevice ? 0 : 104,
            qpc100ns: withinGrace ? 14_166_667 : 11_000_000
        )

        #expect(endAfterSilence == 24_004)
        let blocks = drain(harness.ring)
        if withinGrace {
            #expect(harness.ingress.failure == nil)
            #expect(harness.sink.lastEndFrame == endAfterSilence + 4)
            #expect(blocks.last?.startFrame == endAfterSilence)
            #expect(blocks.last?.samples == [2, 2, 2, 2])
            #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        } else {
            #expect(harness.ingress.failure == .timestamp)
            #expect(harness.ingress.timestampCheck == .idleAnchorOverlap)
            #expect(harness.sink.lastEndFrame == endAfterSilence)
            #expect(!blocks.flatMap(\.samples).contains(2))
        }
        #expect(harness.ring.dropoutCount == 0)
    }

    @Test(arguments: [false, true], [UInt32(0), UInt32(1)])
    func testLoopbackDeviceAheadOfClockStillFailsWithLatchedEvidence(
        observedIdle: Bool, flags: UInt32
    ) throws {
        let harness = try makeIngress(loopback: true)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 480), frameCount: 480
        )
        if observedIdle {
            harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        }
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1, flags: flags,
            devicePosition: 480, qpc100ns: 10_050_000
        )
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == .clockMismatch)
        let details = harness.ingress.timestampDetails
        #expect(details.qpcDeltaFrames == 240)
        #expect(details.deviceDeltaFrames == 480)
        #expect(details.packetFlags == flags)
        #expect(details.idleObserved == observedIdle)
        receive(harness.ingress, samples: nil, frameCount: 1, flags: 4)
        #expect(harness.ingress.timestampDetails == details)
        #expect(harness.sink.lastEndFrame == 480)
        #expect(harness.ring.dropoutCount == 0)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
    }

    @Test func testCompletedPacketConsumesIdleEvidenceBeforeNextActiveJump() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        receive(harness.ingress, samples: [0.25], frameCount: 1, sampleRate: 16_000)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 0, error: 0)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(
            harness.ingress, samples: [0.5], frameCount: 1, sampleRate: 16_000,
            devicePosition: 1, qpc100ns: 15_000_000
        )
        #expect(harness.ring.dropoutCount == 0)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1, sampleRate: 16_000,
            devicePosition: 2, qpc100ns: 20_000_000
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 16_001)
        #expect(harness.ring.dropoutCount == 1)
        let blocks = drain(harness.ring)
        let gaps = blocks.compactMap(\.gap)
        #expect(gaps.count == 1)
        #expect(gaps.first?.startFrame == 8_001)
        #expect(gaps.first?.frameCount == 7_999)
        #expect(gaps.first?.reason == .invalidBuffer)
        #expect(blocks.last?.samples == [0.75])
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
