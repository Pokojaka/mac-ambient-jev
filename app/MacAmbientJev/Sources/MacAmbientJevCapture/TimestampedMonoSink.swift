import Foundation
import MacAmbientJevCore
import Synchronization

/// Shared platform-free realtime boundary. Exactly one serial callback producer may call receive.
final class TimestampedMonoSink: @unchecked Sendable {
    let lastBufferMillis = Atomic<Int64>(0)
    let silentSinceMillis = Atomic<Int64>(0)
    let invalidBufferCount = Atomic<UInt64>(0)
    let everNonZero = Atomic(false)
    private let ring: AudioBlockRing
    private let clock: any CaptureClock
    private let scratch: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var endFrame: Int64 = 0
    private let publishedEndFrame = Atomic<Int64>(0)

    init(ring: AudioBlockRing, frameCapacity: Int, clock: any CaptureClock) {
        precondition(frameCapacity > 0)
        self.ring = ring
        self.clock = clock
        capacity = frameCapacity
        scratch = .allocate(capacity: frameCapacity)
        scratch.initialize(repeating: 0, count: frameCapacity)
    }

    deinit {
        scratch.deinitialize(count: capacity)
        scratch.deallocate()
    }

    var lastEndFrame: Int64 { publishedEndFrame.load(ordering: .acquiring) }

    func missing(startFrame: Int64, frameCount: Int) {
        guard frameCount > 0 else { return }
        _ = invalidBufferCount.add(1, ordering: .relaxed)
        advance(startFrame: startFrame, count: frameCount)
        ring.noteMissing(startFrame: startFrame, frameCount: frameCount)
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
    func silence(startFrame: Int64, frameCount: Int) {
        guard frameCount > 0 else { return }
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
    func receive(
        channels: UnsafePointer<UnsafePointer<Float>>, strides: UnsafePointer<Int>,
        channelCount: Int, frameCount: Int, startFrame: Int64
    ) {
        guard frameCount > 0, channelCount > 0,
              !startFrame.addingReportingOverflow(Int64(frameCount)).overflow else {
            missing(startFrame: startFrame, frameCount: frameCount)
            return
        }
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
                    sum += input
                }
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
/// Used only by one serialized producer callback; absence of a timestamp is contiguous.
final class CaptureFrameTimestampMapper: @unchecked Sendable {
    private var sampleOrigin: Int64?
    private var hostOriginNanos: UInt64?
    private var hostBaseFrame: Int64 = 0

    func startFrame(sampleTime: Double?, hostTimeNanos: UInt64?,
                    sampleRate: Double, fallbackEndFrame: Int64) -> Int64 {
        guard sampleRate > 0, sampleRate.isFinite else { return fallbackEndFrame }
        if let sampleTime, sampleTime.isFinite, abs(sampleTime) < 1_000_000_000_000 {
            let frame = Int64(sampleTime.rounded())
            if sampleOrigin == nil { sampleOrigin = frame }
            // A device clock can restart (e.g. the tap follows a new output device);
            // continue after the last written frame rather than overwrite earlier audio.
            if frame - sampleOrigin! < fallbackEndFrame - 1 {
                sampleOrigin = frame - fallbackEndFrame
            }
            if hostOriginNanos == nil, let hostTimeNanos {
                hostOriginNanos = hostTimeNanos
                hostBaseFrame = frame - sampleOrigin!
            }
            return frame - sampleOrigin!
        }
        if let hostTimeNanos {
            if hostOriginNanos == nil {
                hostOriginNanos = hostTimeNanos
                hostBaseFrame = fallbackEndFrame
            }
            guard hostTimeNanos >= hostOriginNanos! else { return fallbackEndFrame }
            let frames = Double(hostTimeNanos - hostOriginNanos!) * sampleRate / 1_000_000_000
            if frames.isFinite, frames >= 0, frames < 1_000_000_000_000 {
                return hostBaseFrame + Int64(frames.rounded())
            }
        }
        return fallbackEndFrame
    }
}
