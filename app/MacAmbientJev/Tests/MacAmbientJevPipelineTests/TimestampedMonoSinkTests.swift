import Foundation
import Synchronization
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline

@Suite struct TimestampedMonoSinkTests {
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
