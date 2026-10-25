import Foundation
import MacAmbientJevCore
import Synchronization

/// Per-channel 100-ms peak and clipping accumulator for the microphone callback.
/// The callback producer owns the accumulators; completed windows cross to one consumer
/// through fixed preallocated slots, so the callback never allocates, locks or blocks.
public final class RawInputMeter: @unchecked Sendable {
    public struct Window: Equatable {
        public let startFrame: Int64
        public let frameCount: Int
        public let peak: Float
        public let clippedFraction: Double

        public init(startFrame: Int64, frameCount: Int, peak: Float, clippedFraction: Double) {
            self.startFrame = startFrame
            self.frameCount = frameCount
            self.peak = peak
            self.clippedFraction = clippedFraction
        }
    }

    private struct Slot {
        var window: Window
        var generation: UInt64
    }

    public static let clipLevel: Float = 0.98
    public static let windowSeconds = 0.1
    public static let slotCapacity = 64

    public let sampleRate: Double
    public let windowFrames: Int
    private let channelCount: Int
    private let clippedCounts: UnsafeMutablePointer<Int>
    private let slots: UnsafeMutablePointer<Slot>
    private var peak: Float = 0
    private var framesInWindow = 0
    private var nextFrame = Int64.min
    private var producerGeneration: UInt64 = 0
    private let requestedGeneration = Atomic<UInt64>(0)
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    public init(channelCount: Int, sampleRate: Double) {
        precondition(channelCount > 0 && sampleRate > 0 && sampleRate.isFinite)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        windowFrames = max(1, Int((sampleRate * Self.windowSeconds).rounded()))
        clippedCounts = .allocate(capacity: channelCount)
        clippedCounts.initialize(repeating: 0, count: channelCount)
        slots = .allocate(capacity: Self.slotCapacity)
        slots.initialize(
            repeating: Slot(window: Window(startFrame: 0, frameCount: 0, peak: 0, clippedFraction: 0),
                            generation: 0),
            count: Self.slotCapacity
        )
    }

    deinit {
        clippedCounts.deinitialize(count: channelCount)
        clippedCounts.deallocate()
        slots.deinitialize(count: Self.slotCapacity)
        slots.deallocate()
    }

    /// Producer: a timestamp discontinuity or a consumer reset discards the partial window.
    public func begin(startFrame: Int64, channelCount: Int) {
        precondition(channelCount == self.channelCount, "Meter layout must match the capture format")
        let requested = requestedGeneration.load(ordering: .acquiring)
        if requested != producerGeneration {
            producerGeneration = requested
            discardPartial()
        }
        if startFrame != nextFrame { discardPartial() }
    }

    @inline(__always)
    public func accumulate(_ sample: Float, channel: Int) {
        let magnitude = abs(sample)
        if magnitude > peak { peak = magnitude }
        if magnitude >= Self.clipLevel { clippedCounts[channel] += 1 }
    }

    @inline(__always)
    public func finishFrame(_ frame: Int64) {
        framesInWindow += 1
        nextFrame = frame + 1
        guard framesInWindow == windowFrames else { return }
        var worst = 0
        for channel in 0..<channelCount { worst = max(worst, clippedCounts[channel]) }
        publish(Window(
            startFrame: frame + 1 - Int64(windowFrames), frameCount: windowFrames,
            peak: peak, clippedFraction: Double(worst) / Double(windowFrames)
        ))
        discardPartial()
    }

    /// Producer: invalid, missing and replacement-silence packets are not measurement evidence.
    public func discardPartial() {
        framesInWindow = 0
        peak = 0
        for channel in 0..<channelCount { clippedCounts[channel] = 0 }
        nextFrame = Int64.min
    }

    private func publish(_ window: Window) {
        let end = tail.load(ordering: .relaxed)
        // A consumer 6.4 s behind would only receive stale windows, which the policy rejects.
        guard end - head.load(ordering: .acquiring) < Self.slotCapacity else { return }
        slots[end % Self.slotCapacity] = Slot(window: window, generation: producerGeneration)
        tail.store(end + 1, ordering: .releasing)
    }

    /// Consumer: windows accumulated before this call are discarded.
    public func requestReset() {
        _ = requestedGeneration.add(1, ordering: .releasing)
    }

    /// Consumer: returns completed windows accumulated since the latest reset.
    public func takeWindows() -> [Window] {
        let generation = requestedGeneration.load(ordering: .relaxed)
        var start = head.load(ordering: .relaxed)
        let end = tail.load(ordering: .acquiring)
        var windows: [Window] = []
        while start != end {
            let slot = slots[start % Self.slotCapacity]
            if slot.generation == generation { windows.append(slot.window) }
            start += 1
        }
        head.store(start, ordering: .releasing)
        return windows
    }
}

/// Shared platform-free realtime boundary. Exactly one serial callback producer may call receive.
public final class TimestampedMonoSink: @unchecked Sendable {
    public let lastBufferMillis = Atomic<Int64>(0)
    public let silentSinceMillis = Atomic<Int64>(0)
    public let invalidBufferCount = Atomic<UInt64>(0)
    public let everNonZero = Atomic(false)
    public let meter: RawInputMeter?
    private let ring: AudioBlockRing
    private let clock: any CaptureClock
    private let scratch: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var endFrame: Int64 = 0
    private let publishedEndFrame = Atomic<Int64>(0)

    public init(ring: AudioBlockRing, frameCapacity: Int, clock: any CaptureClock, meter: RawInputMeter?) {
        precondition(frameCapacity > 0)
        self.ring = ring
        self.clock = clock
        self.meter = meter
        capacity = frameCapacity
        scratch = .allocate(capacity: frameCapacity)
        scratch.initialize(repeating: 0, count: frameCapacity)
    }

    deinit {
        scratch.deinitialize(count: capacity)
        scratch.deallocate()
    }

    public var lastEndFrame: Int64 { publishedEndFrame.load(ordering: .acquiring) }

    public func missing(startFrame: Int64, frameCount: Int) {
        guard frameCount > 0 else { return }
        meter?.discardPartial()
        _ = invalidBufferCount.add(1, ordering: .relaxed)
        advance(startFrame: startFrame, count: frameCount)
        ring.noteMissing(startFrame: startFrame, frameCount: frameCount)
    }

    /// Records a known startup timeline extent before the producer starts; it is not audio evidence.
    public func timestampGap(frameCount: Int) {
        precondition(frameCount >= 0)
        precondition(endFrame == 0)
        if frameCount > 0 {
            ring.noteTimestampGap(startFrame: 0, frameCount: frameCount)
            advance(startFrame: 0, count: frameCount)
        }
        meter?.discardPartial()
        silentSinceMillis.store(0, ordering: .releasing)
    }

    private func advance(startFrame: Int64, count: Int) {
        let (end, overflow) = startFrame.addingReportingOverflow(Int64(count))
        if !overflow {
            endFrame = max(endFrame, end)
            publishedEndFrame.store(endFrame, ordering: .releasing)
        }
    }

    /// An explicitly silent packet is valid captured audio, not a dropout.
    /// A timestamp jump before it is still reconstructed by the ring.
    public func silence(startFrame: Int64, frameCount: Int) {
        guard frameCount > 0 else { return }
        meter?.discardPartial()
        advance(startFrame: startFrame, count: frameCount)
        var pointer = scratch
        var offset = 0
        while offset < frameCount {
            let count = min(capacity, frameCount - offset)
            for frame in 0..<count { scratch[frame] = 0 }
            _ = withUnsafePointer(to: &pointer) {
                ring.pushPlanarFloat32(channelData: $0, channelCount: 1,
                                      frameCount: count, startFrame: startFrame + Int64(offset))
            }
            offset += count
        }
        let millis = Int64(clock.now() * 1_000)
        lastBufferMillis.store(millis, ordering: .relaxed)
        if silentSinceMillis.load(ordering: .relaxed) == 0 {
            silentSinceMillis.store(millis, ordering: .relaxed)
        }
    }

    /// Planar and packed Float32 share this channel-stride conversion. No callback allocation.
    public func receive(
        channels: UnsafePointer<UnsafePointer<Float>>, strides: UnsafePointer<Int>,
        channelCount: Int, frameCount: Int, startFrame: Int64
    ) {
        guard frameCount > 0, channelCount > 0,
              !startFrame.addingReportingOverflow(Int64(frameCount)).overflow else {
            missing(startFrame: startFrame, frameCount: frameCount)
            return
        }
        let meter = self.meter
        meter?.begin(startFrame: startFrame, channelCount: channelCount)
        var peak: Float = 0
        let divisor = Float(channelCount)
        var offset = 0
        var pointer = scratch
        while offset < frameCount {
            let count = min(capacity, frameCount - offset)
            for frame in 0..<count {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let input = channels[channel][(offset + frame) * strides[channel]]
                    if input != 0 { everNonZero.store(true, ordering: .releasing) }
                    meter?.accumulate(input, channel: channel)
                    sum += input
                }
                meter?.finishFrame(startFrame + Int64(offset + frame))
                let sample = sum / divisor
                scratch[frame] = sample
                peak = max(peak, abs(sample))
            }
            _ = withUnsafePointer(to: &pointer) { ring.pushPlanarFloat32(
                channelData: $0, channelCount: 1, frameCount: count,
                startFrame: startFrame + Int64(offset)
            ) }
            offset += count
        }
        advance(startFrame: startFrame, count: frameCount)
        let millis = Int64(clock.now() * 1_000)
        lastBufferMillis.store(millis, ordering: .relaxed)
        if peak < 0.00031622776 {
            if silentSinceMillis.load(ordering: .relaxed) == 0 {
                silentSinceMillis.store(millis, ordering: .relaxed)
            }
        } else {
            silentSinceMillis.store(0, ordering: .relaxed)
        }
    }
}

/// Platform-independent conversion from device timestamps into ring frame positions.
/// Used only by one serialized producer callback. A buffer without a usable
/// timestamp starts at `contiguousEndFrame`, right after the previous buffer.
public final class CaptureFrameTimestampMapper: @unchecked Sendable {
    private var sampleOrigin: Int64?
    private var hostOriginNanos: UInt64?
    private var hostBaseFrame: Int64 = 0

    public init() {}

    public func startFrame(sampleTime: Double?, hostTimeNanos: UInt64?,
                    sampleRate: Double, contiguousEndFrame: Int64) -> Int64 {
        precondition(sampleRate > 0 && sampleRate.isFinite, "The capture format has no valid sample rate")
        if let sampleTime, sampleTime.isFinite, abs(sampleTime) < 1_000_000_000_000 {
            let frame = Int64(sampleTime.rounded())
            if sampleOrigin == nil { sampleOrigin = frame }
            // Preserve elapsed host time across a device sample-clock restart.
            if frame - sampleOrigin! < contiguousEndFrame - 1 {
                let restartFrame = max(contiguousEndFrame, hostFrame(
                    hostTimeNanos: hostTimeNanos, sampleRate: sampleRate,
                    contiguousEndFrame: contiguousEndFrame
                ))
                sampleOrigin = frame - restartFrame
                hostOriginNanos = hostTimeNanos
                hostBaseFrame = restartFrame
            }
            if hostOriginNanos == nil, let hostTimeNanos {
                hostOriginNanos = hostTimeNanos
                hostBaseFrame = frame - sampleOrigin!
            }
            return frame - sampleOrigin!
        }
        return hostFrame(hostTimeNanos: hostTimeNanos, sampleRate: sampleRate,
                         contiguousEndFrame: contiguousEndFrame)
    }

    private func hostFrame(hostTimeNanos: UInt64?, sampleRate: Double,
                           contiguousEndFrame: Int64) -> Int64 {
        if let hostTimeNanos {
            if hostOriginNanos == nil {
                hostOriginNanos = hostTimeNanos
                hostBaseFrame = contiguousEndFrame
            }
            guard hostTimeNanos >= hostOriginNanos! else { return contiguousEndFrame }
            let frames = Double(hostTimeNanos - hostOriginNanos!) * sampleRate / 1_000_000_000
            if frames.isFinite, frames >= 0, frames < 1_000_000_000_000 {
                return hostBaseFrame + Int64(frames.rounded())
            }
        }
        return contiguousEndFrame
    }
}
