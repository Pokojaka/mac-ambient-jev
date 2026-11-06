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
    readQPC100ns: UInt64? = nil,
    packetOffset: Int = 0,
    packetFrames: Int? = nil
) {
    let packet = WindowsCapturePacket(
        samples: nil, frameCount: frameCount, channels: channels,
        sampleRate: sampleRate, flags: flags, devicePosition: devicePosition,
        qpc100ns: qpc100ns, readQPC100ns: readQPC100ns ?? qpc100ns, packetOffset: packetOffset,
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
            readQPC100ns: readQPC100ns ?? qpc100ns,
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

// Six seconds of observed idle, then a fresh stream whose second native packet
// has a late QPC but a contiguous device position. Keep the delivery grace and PCM.
private func makeLoopbackStartupJitterIngress(
    packetFrames: Int, jitterFrames: Int
) throws -> IngressHarness {
    let harness = try makeIngress(loopback: true)
    for tick in 1...12 {
        harness.clock.setMillis(10_000 + Int64(tick * 500))
        harness.ingress.health(
            watermarkQPC100ns: 10_000_000 + UInt64(tick * 5_000_000),
            outputState: 0, error: 0
        )
        _ = drain(harness.ring)
    }
    harness.ingress.health(watermarkQPC100ns: 70_000_000, outputState: 1, error: 0)
    for index in 0..<2 {
        let hostOffset = index * (packetFrames + jitterFrames)
        for offset in stride(from: 0, to: packetFrames, by: 512) {
            let count = min(512, packetFrames - offset)
            receive(
                harness.ingress, samples: [Float](repeating: index == 0 ? 0.25 : 0.75, count: count),
                frameCount: count, devicePosition: 123_456 + UInt64(index * packetFrames),
                qpc100ns: 70_000_000 + UInt64((Double(hostOffset) * 10_000_000 / 48_000).rounded()),
                packetOffset: offset, packetFrames: packetFrames
            )
        }
    }
    return harness
}

private func makeDurableIngressDrain(
    ring: AudioBlockRing, sampleRate: Double = 16_000
) throws -> (directory: URL, drain: AudioCaptureDrain) {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "WindowsCaptureIngress-\(UUID().uuidString)", directoryHint: .isDirectory)
    let writer = try DurableAudioWriter(
        directory: directory, chunkDurationSeconds: 1, sessionURL: directory
    )
    let captureDrain = AudioCaptureDrain(
        ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: sampleRate)
    )
    return (directory, captureDrain)
}

struct WindowsCaptureIngressTests {
    @Test func testOneFrameDeviceHoleRecordsPacketTimelineReadLag() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [0.25], frameCount: 1)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1, devicePosition: 2,
            qpc100ns: 10_000_417, readQPC100ns: 10_123_873
        )
        #expect(harness.ingress.failure == nil)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.check == .packetTimeline)
        #expect(diagnostics.first?.startFrame == 1)
        #expect(diagnostics.first?.endFrame == 2)
        #expect(diagnostics.first.map { $0.endFrame - $0.startFrame } == 1)
        #expect(diagnostics.first?.readLagMilliseconds == 12)
        if let details = diagnostics.first {
            #expect(WindowsCaptureSource.describeGapDiagnostic(details, sampleRate: 48_000)
                .contains("readLagMs: 12"))
        }
    }

    @Test func testReadQPCBeforePacketQPCIsAcceptedAndReportsNegativeGapLag() throws {
        let harness = try makeIngress(loopback: true)
        receive(harness.ingress, samples: [0.25], frameCount: 1)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1, devicePosition: 2,
            qpc100ns: 10_000_417, readQPC100ns: 9_980_416
        )

        #expect(harness.ingress.failure == nil)
        let diagnostic = harness.ingress.takeGapDiagnostics().first
        #expect(diagnostic?.check == .packetTimeline)
        #expect(diagnostic?.startFrame == 1)
        #expect(diagnostic?.endFrame == 2)
        #expect(diagnostic?.readLagMilliseconds == -2)
        let details = try #require(diagnostic)
        #expect(WindowsCaptureSource.describeGapDiagnostic(details, sampleRate: 48_000)
            .contains("readLagMs: -2"))
    }

    @Test func testFragmentReadQPCMustMatchFirstFragment() throws {
        let harness = try makeIngress()
        receive(
            harness.ingress, samples: [0.25], frameCount: 1,
            readQPC100ns: 10_100_000, packetFrames: 2
        )
        receive(
            harness.ingress, samples: [0.75], frameCount: 1,
            readQPC100ns: 10_100_001, packetOffset: 1, packetFrames: 2
        )
        #expect(harness.ingress.failure == .invalidPacket)
        #expect(harness.sink.lastEndFrame == 1)
    }

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

    @Test(arguments: [false, true], [false, true])
    func testLoopbackPauseShorterThanAccumulatedLeadPreservesEveryPCMFrame(
        observedIdle: Bool, deviceDrift: Bool
    ) throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        var expectedSamples: [Float] = []
        var recordedSamples: [Float] = []
        let previousHostFrame: Int
        let nextDevicePosition: UInt64
        if deviceDrift {
            // Accelerate long-running drift using deltas within the existing 32-frame
            // tolerance. The device timeline gains exactly 200 ms over raw QPC.
            for index in 0...100 {
                let pcm = [Float](repeating: index.isMultiple(of: 2) ? 0 : 0.25, count: 512)
                receive(
                    harness.ingress, samples: pcm, frameCount: 512, sampleRate: 16_000,
                    devicePosition: UInt64(index * 512),
                    qpc100ns: 10_000_000 + UInt64(index * 480 * 625)
                )
                expectedSamples.append(contentsOf: pcm)
                recordedSamples.append(contentsOf: drain(harness.ring).flatMap(\.samples))
            }
            previousHostFrame = 48_000
            nextDevicePosition = 51_712
        } else {
            harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
            // Health has committed 500 ms; the packet starts at 300 ms, creating
            // the same 200-ms lead without dropping its PCM into the idle silence.
            receive(
                harness.ingress, samples: [Float](repeating: 0.25, count: 512),
                frameCount: 512, sampleRate: 16_000, qpc100ns: 13_000_000
            )
            expectedSamples = [Float](repeating: 0, count: 8_000)
                + [Float](repeating: 0.25, count: 512)
            recordedSamples = drain(harness.ring).flatMap(\.samples)
            previousHostFrame = 4_800
            nextDevicePosition = 512
        }
        #expect(harness.ingress.failure == nil)
        let beforePause = harness.sink.lastEndFrame
        let resumedHostFrame = previousHostFrame + 512 + 2_400 // 150-ms pause
        #expect(beforePause - Int64(resumedHostFrame) == 800)
        harness.clock.setMillis(10_250 + Int64(resumedHostFrame / 16))
        harness.ingress.health(
            watermarkQPC100ns: 10_000_000 + UInt64(resumedHostFrame * 625),
            outputState: observedIdle ? 0 : 1, error: 0
        )
        #expect(harness.sink.lastEndFrame == beforePause)
        for index in 0..<3 {
            let value: Float = index == 0 ? 0.75 : (index == 1 ? 0 : -0.5)
            let pcm = [Float](repeating: value, count: 1_024)
            expectedSamples.append(contentsOf: pcm)
            for offset in [0, 512] {
                receive(
                    harness.ingress, samples: Array(pcm[offset..<(offset + 512)]),
                    frameCount: 512, sampleRate: 16_000,
                    devicePosition: nextDevicePosition + UInt64(index * 1_024),
                    qpc100ns: 10_000_000 + UInt64((resumedHostFrame + index * 1_024) * 625),
                    packetOffset: offset, packetFrames: 1_024
                )
                recordedSamples.append(contentsOf: drain(harness.ring).flatMap(\.samples))
            }
        }
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == beforePause + 3_072)
        #expect(recordedSamples == expectedSamples)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.sink.invalidBufferCount.load(ordering: .acquiring) == 0)
    }

    @Test func testLoopbackForwardJumpCannotReuseConsumedLeadToOverlapMissingTail() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 512),
            frameCount: 512, sampleRate: 16_000, qpc100ns: 13_000_000
        )
        // Consume 150 ms of the 200-ms anchor lead, leaving only 50 ms (800 frames).
        receive(
            harness.ingress, samples: [Float](repeating: 0.5, count: 512),
            frameCount: 512, sampleRate: 16_000, devicePosition: 512, qpc100ns: 14_820_000
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 9_024)
        #expect(drain(harness.ring).flatMap(\.samples).suffix(512).allSatisfy { $0 == 0.5 })
        harness.ingress.health(watermarkQPC100ns: 14_820_000, outputState: 1, error: 0)
        // Publish a missing tail, not idle silence. It cannot authorize another anchor shift.
        harness.ingress.health(watermarkQPC100ns: 18_765_000, outputState: 0, error: 0)
        #expect(harness.sink.lastEndFrame == 10_024)
        receive(
            harness.ingress, samples: [0.75], frameCount: 1, sampleRate: 16_000,
            devicePosition: 1_024, qpc100ns: 15_390_000
        )
        // Device mapping would start 400 frames ahead of QPC, so this is not jitter.
        // The reanchor cannot overlap the published missing tail.
        #expect(harness.ingress.failure == .timestamp)
        #expect(harness.ingress.timestampCheck == .idleAnchorOverlap)
        #expect(harness.sink.lastEndFrame == 10_024)
        #expect(!drain(harness.ring).flatMap(\.samples).contains(0.75))
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

    @MainActor
    @Test func testHealthTimestampFailureTextDoesNotDescribeThePreviousPacket() async throws {
        let root = try makeWindowsCaptureTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appending(path: "health-timestamp.f32le")
        try writeScriptedFloatFixture([Float](repeating: 0.25, count: 512), to: fixture)
        let events = scriptedPacketFragments(
            file: fixture, sourceFrames: 512, devicePosition: 0, qpc100ns: 10_000_000
        ) + scriptedPacketFragments(
            file: fixture, sourceFrames: 512, devicePosition: 512,
            qpc100ns: 10_106_667, flags: 1
        ) + [
            ScriptedFileCaptureEvent.heartbeat(
                watermarkQPC100ns: 10_213_333, outputState: 1, error: 0
            ),
            .heartbeat(watermarkQPC100ns: 9_000_000, outputState: 0, error: 0)
        ]
        let harness = try makeWindowsCaptureTestSource(
            root: root, source: .systemAudio, sampleRate: 48_000,
            channels: 1, events: events, probe: ScriptedCaptureProbe()
        )
        try await harness.source.start()
        let device = try #require(harness.factory.openedDevice)
        for _ in 1..<events.count { try await device.step() }
        await waitForWindowsCaptureTestCondition { harness.source.lastStopResult != nil }
        let result = await harness.source.stop()
        let message = try #require(result.errors.first { $0.contains("activeTailWatermark") })
        #expect(message.contains("invalid health timestamp"))
        #expect(message.contains("origin: health"))
        #expect(!message.contains("qpcDeltaFrames"))
        #expect(!message.contains("deviceDeltaFrames"))
        #expect(!message.contains("packetFlags"))
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

    @Test(arguments: [240, 480, 960], [169, 197])
    func testLoopbackStartupQPCJitterPreservesContiguousPCM(
        packetFrames: Int, jitterFrames: Int
    ) throws {
        let harness = try makeLoopbackStartupJitterIngress(
            packetFrames: packetFrames, jitterFrames: jitterFrames
        )
        var blocks = drain(harness.ring)
        // At 48 kHz with 480-frame packets, the second QPC delta is exactly
        // 649 (or 677) frames while the device delta remains 480 frames.
        // Later QPC deltas agree with the device; retain the device anchor.
        for index in 2..<10 {
            let hostOffset = index * packetFrames + jitterFrames
            for offset in stride(from: 0, to: packetFrames, by: 512) {
                let count = min(512, packetFrames - offset)
                receive(
                    harness.ingress, samples: [Float](repeating: 0.75, count: count),
                    frameCount: count, devicePosition: 123_456 + UInt64(index * packetFrames),
                    qpc100ns: 70_000_000 + UInt64((Double(hostOffset) * 10_000_000 / 48_000).rounded()),
                    packetOffset: offset, packetFrames: packetFrames
                )
            }
            blocks.append(contentsOf: drain(harness.ring))
        }
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 288_000 + Int64(10 * packetFrames))
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ingress.takeGapDiagnostics().isEmpty)
        #expect(blocks.allSatisfy { $0.gap == nil && $0.gapBefore == nil })
        let samples = blocks.flatMap(\.samples)
        #expect(samples == [Float](repeating: 0, count: 12_000)
            + [Float](repeating: 0.25, count: packetFrames)
            + [Float](repeating: 0.75, count: 9 * packetFrames))
    }

    @Test func testLoopbackSlowClockDriftAcceptsLateQPCAndSnapBackAfterEightMinutes() throws {
        let harness = try makeIngress(loopback: true)
        let packetFrames = 480
        let steadyPacketCount = 52_001 // 520 seconds, beyond 8.5 minutes.
        let samples = [Float](repeating: 0.25, count: packetFrames)
        var keptFrames = 0
        var intactPCM = true
        var previousHostFrame = 0
        var lateDelta = 0
        var snapBackDelta = 0
        for index in 0..<(steadyPacketCount + 2) {
            let deviceFrame = index * packetFrames
            // A device clock 20 ppm slower than QPC; ordinary deltas are 480 or 481.
            let steadyHostFrame = Int((Double(deviceFrame) / 0.99998).rounded())
            let hostFrame = steadyHostFrame + (index == steadyPacketCount ? 169 : 0)
            if index == steadyPacketCount { lateDelta = hostFrame - previousHostFrame }
            if index == steadyPacketCount + 1 { snapBackDelta = hostFrame - previousHostFrame }
            receive(
                harness.ingress, samples: samples, frameCount: packetFrames,
                devicePosition: UInt64(deviceFrame),
                qpc100ns: 10_000_000 + UInt64((Double(hostFrame) * 10_000_000 / 48_000).rounded())
            )
            for block in drain(harness.ring) {
                keptFrames += block.samples.count
                intactPCM = intactPCM && block.gap == nil && block.gapBefore == nil
                    && block.samples.allSatisfy { $0 == 0.25 }
            }
            previousHostFrame = hostFrame
        }
        #expect(lateDelta == 649)
        #expect(snapBackDelta == 311)
        #expect(harness.ingress.failure == nil)
        #expect(harness.ingress.takeGapDiagnostics().isEmpty)
        #expect(harness.sink.lastEndFrame == Int64((steadyPacketCount + 2) * packetFrames))
        #expect(keptFrames == (steadyPacketCount + 2) * packetFrames)
        #expect(intactPCM)
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ring.overflowCount == 0)
    }

    @Test func testLoopbackStartupLateQPCSnapBackKeepsAllPCM() throws {
        let harness = try makeIngress(loopback: true)
        for (index, hostFrame) in [0, 649, 960].enumerated() {
            receive(
                harness.ingress, samples: [Float](repeating: 0.75, count: 480), frameCount: 480,
                devicePosition: UInt64(index * 480),
                qpc100ns: 10_000_000 + UInt64((Double(hostFrame) * 10_000_000 / 48_000).rounded())
            )
        }
        #expect(harness.ingress.failure == nil)
        #expect(harness.ingress.takeGapDiagnostics().isEmpty)
        #expect(harness.sink.lastEndFrame == 1_440)
        #expect(drain(harness.ring).flatMap(\.samples) == [Float](repeating: 0.75, count: 1_440))
        #expect(harness.ring.dropoutCount == 0)
    }

    @Test func testLoopbackForwardReanchorExcludesTrackedClockLag() throws {
        let harness = try makeIngress(loopback: true)
        let packetFrames = 480
        for index in 0..<100 {
            let deviceFrame = index * packetFrames
            let hostFrame = Int((Double(deviceFrame) / 0.9999).rounded())
            receive(
                harness.ingress, samples: [Float](repeating: 0.25, count: packetFrames),
                frameCount: packetFrames, devicePosition: UInt64(deviceFrame),
                qpc100ns: 10_000_000 + UInt64(
                    (Double(hostFrame) * 10_000_000 / 48_000).rounded()
                )
            )
            _ = drain(harness.ring)
        }
        let lastHostFrame = Int((Double(99 * packetFrames) / 0.9999).rounded())
        let rawReanchorFrame = lastHostFrame + 960
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: packetFrames),
            frameCount: packetFrames, flags: 1, devicePosition: 48_000,
            qpc100ns: 10_000_000 + UInt64(
                (Double(rawReanchorFrame) * 10_000_000 / 48_000).rounded()
            )
        )
        #expect(harness.ingress.failure == nil)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.check == .qpcForward)
        #expect(diagnostics.first?.endFrame == 48_480)
        #expect(diagnostics.first?.endFrame != Int64(rawReanchorFrame))
        #expect(diagnostics.first?.startFrame == 48_000)
        #expect(diagnostics.first?.idleObserved == false)
        #expect(drain(harness.ring).flatMap(\.samples) == [Float](repeating: 0.75, count: packetFrames))
    }

    @Test func testIdleForwardReanchorTargetsRawQPCAndResetsClockLagBaseline() throws {
        let harness = try makeIngress(loopback: true, ringCapacity: 128)
        let packetFrames = 480
        func qpc(_ frame: Int) -> UInt64 {
            10_000_000 + UInt64((Double(frame) * 10_000_000 / 48_000).rounded())
        }

        var lastHostFrame = 0
        for index in 0..<2_000 {
            let deviceFrame = index * packetFrames
            lastHostFrame = Int((Double(deviceFrame) / 0.9999).rounded())
            receive(
                harness.ingress, samples: [Float](repeating: 0.25, count: packetFrames),
                frameCount: packetFrames, devicePosition: UInt64(deviceFrame),
                qpc100ns: qpc(lastHostFrame)
            )
            _ = drain(harness.ring)
        }
        let endBeforeIdle = harness.sink.lastEndFrame
        #expect(endBeforeIdle == 2_000 * packetFrames)
        harness.ingress.health(watermarkQPC100ns: qpc(lastHostFrame), outputState: 0, error: 0)

        let rawReanchorFrame = lastHostFrame + packetFrames + 1_200
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: packetFrames),
            frameCount: packetFrames, devicePosition: UInt64(2_000 * packetFrames),
            qpc100ns: qpc(rawReanchorFrame)
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == Int64(rawReanchorFrame + packetFrames))
        #expect(harness.ring.dropoutCount == 0)
        #expect(harness.ingress.takeGapDiagnostics().isEmpty)
        let resumedBlocks = drain(harness.ring)
        let silenceFrames = rawReanchorFrame - Int(endBeforeIdle)
        let resumedSamples = resumedBlocks.flatMap(\.samples)
        #expect(resumedSamples.count == silenceFrames + packetFrames)
        #expect(resumedSamples[..<silenceFrames].allSatisfy { $0 == 0 })
        #expect(resumedSamples[silenceFrames...].allSatisfy { $0 == 0.75 })

        // At baseline zero, a 485-frame late start exceeds the 480-frame jitter window.
        let secondRawFrame = rawReanchorFrame + packetFrames + 485
        receive(
            harness.ingress, samples: [Float](repeating: -0.5, count: packetFrames),
            frameCount: packetFrames, devicePosition: UInt64(2_000 * packetFrames + packetFrames),
            qpc100ns: qpc(secondRawFrame)
        )
        #expect(harness.ingress.failure == nil)
        let diagnostic = harness.ingress.takeGapDiagnostics().first
        #expect(diagnostic?.check == .qpcForward)
        #expect(diagnostic?.startFrame == Int64(rawReanchorFrame + packetFrames))
        #expect(diagnostic?.endFrame == Int64(secondRawFrame))
    }

    @Test func testSpacedUnflaggedQPCStepsCannotStayWithinJitterAllowance() throws {
        let harness = try makeIngress(loopback: true, ringCapacity: 128)
        let packetFrames = 480
        func qpc(_ frame: Int) -> UInt64 {
            10_000_000 + UInt64((Double(frame) * 10_000_000 / 48_000).rounded())
        }

        for index in 0...1_000 {
            let deviceFrame = index * packetFrames
            let qpcStepCount = index / 500
            let hostFrame = deviceFrame + qpcStepCount * 400
            receive(
                harness.ingress, samples: [Float](repeating: 0.25, count: packetFrames),
                frameCount: packetFrames, devicePosition: UInt64(deviceFrame),
                qpc100ns: qpc(hostFrame)
            )
            if index == 500 {
                #expect(harness.ingress.failure == nil)
                #expect(harness.ingress.takeGapDiagnostics().isEmpty)
                #expect(harness.ring.dropoutCount == 0)
            }
            if index < 1_000 { _ = drain(harness.ring) }
        }

        #expect(harness.ingress.failure == nil)
        #expect(harness.ring.dropoutCount == 1)
        let diagnostic = harness.ingress.takeGapDiagnostics().first
        #expect(diagnostic?.check == .qpcForward)
        #expect(diagnostic?.startFrame == 1_000 * packetFrames)
        #expect(diagnostic.map { $0.endFrame > $0.startFrame } == true)
    }

    @Test(arguments: [480, 481])
    func testLoopbackActiveJumpOfAtLeastOnePeriodAfterStartupJitterIsCounted(
        jumpFrames: Int
    ) throws {
        try checkLoopbackGapAfterStartupJitter(jumpFrames: jumpFrames, flags: 0)
    }

    @Test func testLoopbackFlaggedSubperiodJumpAfterStartupJitterIsCounted() throws {
        try checkLoopbackGapAfterStartupJitter(jumpFrames: 169, flags: 1)
    }

    private func checkLoopbackGapAfterStartupJitter(jumpFrames: Int, flags: UInt32) throws {
        let harness = try makeLoopbackStartupJitterIngress(packetFrames: 480, jitterFrames: 169)
        _ = drain(harness.ring)
        #expect(harness.ring.dropoutCount == 0)
        let hostOffset = 960 + 169 + jumpFrames
        receive(
            harness.ingress, samples: [Float](repeating: -0.5, count: 480), frameCount: 480,
            flags: flags, devicePosition: 124_416,
            qpc100ns: 70_000_000 + UInt64((Double(hostOffset) * 10_000_000 / 48_000).rounded())
        )
        #expect(harness.ingress.failure == nil)
        #expect(harness.ring.dropoutCount == 1)
        #expect(harness.ring.overflowCount == 0)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.check == .qpcForward)
        #expect(diagnostics.first?.startFrame == 288_960)
        #expect(diagnostics.first?.endFrame == 288_960 + Int64(169 + jumpFrames))
        #expect(diagnostics.first?.qpcDeltaFrames == Int64(480 + jumpFrames))
        #expect(diagnostics.first?.deviceDeltaFrames == 480)
        #expect(diagnostics.first?.packetFlags == flags)
        #expect(diagnostics.first?.idleObserved == false)
        #expect(drain(harness.ring).flatMap(\.samples) == [Float](repeating: -0.5, count: 480))
    }

    @Test func testRepeatedLoopbackJitterCannotAccumulatePastBaselineRelativePeriod() throws {
        let harness = try makeLoopbackStartupJitterIngress(packetFrames: 480, jitterFrames: 169)
        _ = drain(harness.ring)
        for index in 2...3 {
            receive(
                harness.ingress, samples: [Float](repeating: 0.5, count: 480), frameCount: 480,
                devicePosition: 123_456 + UInt64(index * 480),
                qpc100ns: 70_000_000 + UInt64((Double(index * 649) * 10_000_000 / 48_000).rounded())
            )
            #expect(harness.ring.dropoutCount == (index == 2 ? 0 : 1))
        }
        #expect(harness.ingress.failure == nil)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.startFrame == 289_440)
        #expect(diagnostics.first?.endFrame == 289_947)
        #expect(drain(harness.ring).flatMap(\.samples) == [Float](repeating: 0.5, count: 960))
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

    @Test(arguments: [44_100.0, 48_000.0], [UInt32(0), UInt32(1), UInt32(2), UInt32(3)])
    func testElapsedDevicePositionResumeFillsSmallIdleSuffixWithoutHidingActiveLoss(
        sampleRate: Double, resumeFlags: UInt32
    ) async throws {
        let harness = try makeIngress(sampleRate: sampleRate, loopback: true)
        let durable = try makeDurableIngressDrain(ring: harness.ring, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: durable.directory) }
        let rate = Int64(sampleRate)
        let packetFrames = Int(rate / 100)
        let epoch: UInt64 = 10_000_000
        var millis: Int64 = 10_000
        var nextFrame: Int64 = 0
        var devicePosition: UInt64 = 0
        let originFrame = rate * 3
        let pcm = [Float](repeating: 0.75, count: packetFrames)
        var resumedPCMStarts: [Int64] = []

        func qpc(_ frame: Int64) -> UInt64 {
            epoch + UInt64((Double(frame) * 10_000_000 / sampleRate).rounded())
        }

        func idle(seconds: Int) async throws {
            harness.ingress.health(watermarkQPC100ns: qpc(nextFrame), outputState: 0, error: 0)
            try await durable.drain.drainAvailable()
            let start = nextFrame
            for tick in 1...(seconds * 2) {
                millis += 500
                harness.clock.setMillis(millis)
                harness.ingress.health(
                    watermarkQPC100ns: qpc(start + Int64(tick) * rate / 2),
                    outputState: 0, error: 0
                )
                try await durable.drain.drainAvailable()
            }
            nextFrame += Int64(seconds) * rate
        }

        func playback(seconds: Int, firstFlags: UInt32) async throws {
            harness.ingress.health(watermarkQPC100ns: qpc(nextFrame), outputState: 1, error: 0)
            for index in 0..<(seconds * 100) {
                let flags = index == 0 ? firstFlags : 0
                receive(
                    harness.ingress,
                    samples: flags & 2 == 0 ? pcm : nil,
                    frameCount: packetFrames, sampleRate: sampleRate, flags: flags,
                    devicePosition: devicePosition, qpc100ns: qpc(nextFrame)
                )
                nextFrame += Int64(packetFrames)
                devicePosition += UInt64(packetFrames)
                millis += 10
                harness.clock.setMillis(millis)
                harness.ingress.health(
                    watermarkQPC100ns: qpc(nextFrame), outputState: 1, error: 0
                )
                if index % 10 == 9 { try await durable.drain.drainAvailable() }
            }
        }

        try await idle(seconds: 3)
        #expect(nextFrame == originFrame)
        try await playback(seconds: 58, firstFlags: 0)
        #expect(harness.ring.dropoutCount == 0)
        for (seconds, canonicalSuffix, playbackSeconds) in [(6, 55, 15), (8, 66, 20)] {
            try await idle(seconds: seconds)
            let idleEnd = harness.sink.lastEndFrame
            let suffix = Int64((Double(canonicalSuffix) * sampleRate / 16_000).rounded())
            nextFrame = idleEnd + suffix
            // Some devices advance their position across idle. QPC and device deltas
            // agree, so this resume uses the ordinary anchor mapping, not a reanchor.
            devicePosition = UInt64(nextFrame - originFrame)
            resumedPCMStarts.append(try CanonicalAudio.boundary(nextFrame, sampleRate: sampleRate))
            try await playback(seconds: playbackSeconds, firstFlags: resumeFlags)
            #expect(harness.ingress.failure == nil)
            #expect(harness.ring.dropoutCount == 0)
            #expect(harness.sink.invalidBufferCount.load(ordering: .acquiring) == 0)
        }

        // A later active QPC jump with a device-contiguous packet is still real loss.
        let activeLossStart = nextFrame
        nextFrame += rate / 100
        receive(
            harness.ingress, samples: [Float](repeating: 0.5, count: packetFrames),
            frameCount: packetFrames, sampleRate: sampleRate,
            devicePosition: devicePosition, qpc100ns: qpc(nextFrame)
        )
        nextFrame += Int64(packetFrames)
        #expect(harness.ingress.failure == nil)
        #expect(harness.ring.overflowCount == 0)
        #expect(harness.ring.dropoutCount == 1)
        #expect(harness.sink.invalidBufferCount.load(ordering: .acquiring) == 1)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.check == .qpcForward)
        #expect(diagnostics.first?.idleObserved == false)
        let checkpoint = try await durable.drain.finish()
        let canonicalLossStart = try CanonicalAudio.boundary(activeLossStart, sampleRate: sampleRate)
        #expect(checkpoint.gapEvents == [
            AudioGapEvent(startFrame: canonicalLossStart, frameCount: 160, reason: .invalidBuffer)
        ])
        #expect(checkpoint.committedFrames == (try CanonicalAudio.boundary(nextFrame, sampleRate: sampleRate)))
        let samples = try ProcessingTimelineReader(
            directory: durable.directory, checkpoint: checkpoint, sessionURL: durable.directory
        ).readSamples(frameRange: 0..<checkpoint.committedFrames)
        #expect(samples.count == Int(checkpoint.committedFrames))
        // Interior windows avoid the stateful SRC transition at silence/PCM boundaries.
        #expect(samples[16_000..<32_000].allSatisfy { $0 == 0 })
        #expect(samples[64_000..<80_000].allSatisfy { abs($0 - 0.75) < 0.001 })
        for start in resumedPCMStarts {
            #expect(samples[Int(start + 1_600)..<Int(start + 17_600)].allSatisfy {
                abs($0 - 0.75) < 0.001
            })
        }
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

    @Test func testCountedGapEvidenceIsCompleteAndConsumedOnlyOnControlLane() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        receive(
            harness.ingress, samples: [Float](repeating: 0.25, count: 160),
            frameCount: 160, sampleRate: 16_000
        )
        receive(
            harness.ingress, samples: [Float](repeating: 0.75, count: 160),
            frameCount: 160, sampleRate: 16_000, flags: 1,
            devicePosition: 160, qpc100ns: 10_200_000, readQPC100ns: 10_450_999
        )
        let details = try #require(harness.ingress.takeGapDiagnostics().first)
        #expect(details.check == .qpcForward)
        #expect(details.startFrame == 160)
        #expect(details.endFrame == 320)
        #expect(details.qpcDeltaFrames == 320)
        #expect(details.deviceDeltaFrames == 160)
        #expect(details.packetFlags == 1)
        #expect(!details.idleObserved)
        #expect(!details.fromHealth)
        #expect(details.readLagMilliseconds == 25)
        #expect(harness.ingress.takeGapDiagnostics().isEmpty)
        let message = WindowsCaptureSource.describeGapDiagnostic(details, sampleRate: 16_000)
        #expect(message.contains("check: qpcForward"))
        #expect(message.contains("startFrame: 160, endFrame: 320, frameCount: 160"))
        #expect(message.contains("qpcDeltaFrames: 320, deviceDeltaFrames: 160"))
        #expect(message.contains("readLagMs: 25"))
        #expect(!message.contains("\n"))
        #expect(harness.ring.dropoutCount == 1)
    }

    @Test func testHealthGapEvidenceDoesNotReusePreviousPacketFlagsOrDeltas() throws {
        let harness = try makeIngress(sampleRate: 16_000, loopback: true)
        harness.ingress.health(watermarkQPC100ns: 10_000_000, outputState: 1, error: 0)
        receive(
            harness.ingress, samples: nil, frameCount: 160, sampleRate: 16_000, flags: 3
        )
        harness.clock.setMillis(11_000)
        harness.ingress.health(watermarkQPC100ns: 20_000_000, outputState: 0, error: 0)
        let diagnostics = harness.ingress.takeGapDiagnostics()
        let details = try #require(diagnostics.first)
        #expect(diagnostics.count == 1)
        #expect(details.check == .activeTail)
        #expect(details.startFrame == 160)
        #expect(details.endFrame == 12_000)
        #expect(details.qpcDeltaFrames == nil)
        #expect(details.deviceDeltaFrames == nil)
        #expect(details.packetFlags == 0)
        #expect(details.fromHealth)
        #expect(details.readLagMilliseconds == nil)
        let message = WindowsCaptureSource.describeGapDiagnostic(details, sampleRate: 16_000)
        #expect(message.contains("qpcDeltaFrames: unavailable, deviceDeltaFrames: unavailable"))
        #expect(message.contains("packetFlags: unavailable"))
        #expect(message.contains("readLagMs: unavailable"))
        #expect(message.contains("origin: health"))
        #expect(harness.ring.dropoutCount == 1)
    }

    @Test func testGapDiagnosticsOverflowDoesNotStopCaptureAndReportsDropsOnce() throws {
        let harness = try makeIngress(sampleRate: 16_000, ringCapacity: 256)
        for index in 0..<65 {
            receive(
                harness.ingress, samples: nil, frameCount: 1, sampleRate: 16_000,
                flags: 8, devicePosition: UInt64(index),
                qpc100ns: 10_000_000 + UInt64(index * 625)
            )
        }

        #expect(harness.ingress.failure == nil)
        #expect(harness.sink.lastEndFrame == 65)
        #expect(harness.ring.dropoutCount == 65)
        #expect(harness.ingress.takeGapDiagnostics().count == 64)
        #expect(harness.ingress.takeDroppedGapDiagnosticCount() == 1)
        #expect(harness.ingress.takeDroppedGapDiagnosticCount() == 0)
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
