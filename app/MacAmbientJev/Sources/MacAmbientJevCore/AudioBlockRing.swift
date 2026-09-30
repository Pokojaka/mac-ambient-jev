import Foundation
import Synchronization

public enum AudioGapReason: String, Codable, Sendable, Equatable {
    case missingCallback
    case overflow
    case invalidBuffer
    case stopTail
}

public struct AudioGap: Sendable, Equatable {
    public let startFrame: Int64
    public let frameCount: Int64
    public let reason: AudioGapReason

    public init(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) {
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.reason = reason
    }

    public var endFrame: Int64 { startFrame + frameCount }
}

public struct AudioBlock: Sendable, Equatable {
    public let startFrame: Int64
    public let frameCount: Int64
    public let samples: [Float]
    /// An explicit loss that could not be queued while the ring was full.
    public let gapBefore: AudioGap?
    /// A zero-sample block representing an invalid capture buffer.
    public let gap: AudioGap?
}

/// Single-producer / single-consumer ring. Only the capture callback writes producer state.
/// The callback never allocates; the consumer constructs sample arrays outside realtime.
public final class AudioBlockRing: @unchecked Sendable {
    private let capacity: Int
    private let blockSampleCapacity: Int
    private let timestampToleranceFrames: Int64
    private let storage: UnsafeMutablePointer<Float>
    private let lengths: UnsafeMutablePointer<Int>
    private let starts: UnsafeMutablePointer<Int64>
    private let frames: UnsafeMutablePointer<Int64>
    private let gaps: UnsafeMutablePointer<AudioGap?>
    private let gapsBefore: UnsafeMutablePointer<AudioGap?>

    private var producerEndFrame: Int64 = 0
    private var producerRawEndFrame: Int64 = 0
    private var suppressedSmallGapFrames: Int64 = 0
    private var repeatedSmallGapLoss = false
    private var pendingGap: AudioGap?
    private let finishedTail = Atomic<Int64>(-1)
    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let recordedOverflowCount = Atomic<UInt64>(0)
    private let recordedDropoutCount = Atomic<UInt64>(0)

    /// Minimum slot count for the duration when callbacks can be as small as
    /// 512 device frames. A slot stores interleaved samples, so dividing its
    /// sample capacity by channel count gives its usable frame capacity.
    /// Callers should use similarly small slots to avoid excessive allocation.
    public static func capacityForDuration(
        sampleRate: Double,
        blockFrameCapacity: Int,
        channelCount: Int,
        minimumDurationSeconds: Double = 10
    ) -> Int {
        precondition(sampleRate > 0 && sampleRate.isFinite)
        precondition(minimumDurationSeconds > 0 && minimumDurationSeconds.isFinite)
        precondition(channelCount > 0 && blockFrameCapacity >= channelCount)
        let framesPerCallback = min(blockFrameCapacity / channelCount, 512)
        precondition(framesPerCallback > 0)
        let requiredFrames = (sampleRate * minimumDurationSeconds).rounded(.up)
        precondition(requiredFrames < Double(Int.max))
        return max(1, Int(requiredFrames) / framesPerCallback
            + (Int(requiredFrames) % framesPerCallback == 0 ? 0 : 1))
    }

    public init(capacity: Int, blockFrameCapacity: Int, sampleRate: Double? = nil) {
        precondition(capacity > 0 && blockFrameCapacity > 0)
        if let sampleRate {
            precondition(sampleRate > 0 && sampleRate.isFinite && sampleRate < Double(Int64.max))
        }
        let (total, overflow) = capacity.multipliedReportingOverflow(by: blockFrameCapacity)
        precondition(!overflow)
        self.capacity = capacity
        self.blockSampleCapacity = blockFrameCapacity
        // Frame rounding can account for one frame; a millisecond at 48 kHz
        // spans 48 real frames and must not move audio off its captured PTS.
        self.timestampToleranceFrames = sampleRate == nil ? 0 : 1
        storage = .allocate(capacity: total)
        lengths = .allocate(capacity: capacity)
        starts = .allocate(capacity: capacity)
        frames = .allocate(capacity: capacity)
        gaps = .allocate(capacity: capacity)
        gapsBefore = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
        starts.initialize(repeating: 0, count: capacity)
        frames.initialize(repeating: 0, count: capacity)
        gaps.initialize(repeating: nil, count: capacity)
        gapsBefore.initialize(repeating: nil, count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deinitialize(count: capacity)
        lengths.deallocate()
        starts.deinitialize(count: capacity)
        starts.deallocate()
        frames.deinitialize(count: capacity)
        frames.deallocate()
        gaps.deinitialize(count: capacity)
        gaps.deallocate()
        gapsBefore.deinitialize(count: capacity)
        gapsBefore.deallocate()
    }

    /// Legacy contiguous, mono-style push for non-realtime callers.
    @discardableResult
    public func push(samples: [Float]) -> Bool {
        let start = producerEndFrame
        let (end, overflow) = start.addingReportingOverflow(Int64(samples.count))
        let (rawEnd, rawOverflow) = producerRawEndFrame.addingReportingOverflow(Int64(samples.count))
        guard !overflow && !rawOverflow else { recordOverflow(); return false }
        producerEndFrame = end
        producerRawEndFrame = rawEnd
        guard samples.count <= blockSampleCapacity,
              let slot = reserveProducerSlot() else {
            recordOverflow(startFrame: start, frameCount: Int64(samples.count))
            return false
        }
        let destination = storage.advanced(by: slot * blockSampleCapacity)
        for index in samples.indices { destination[index] = samples[index] }
        publish(slot: slot, startFrame: start, frameCount: Int64(samples.count), sampleCount: samples.count)
        return true
    }

    /// PTS-relative input, in device-rate frames. A callback larger than one slot is split
    /// without allocating an intermediate interleaved buffer.
    @discardableResult
    public func pushPlanarFloat32(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        startFrame: Int64
    ) -> Bool {
        guard channelCount > 0, frameCount >= 0,
              channelCount <= blockSampleCapacity,
              !channelCount.multipliedReportingOverflow(by: frameCount).overflow,
              !startFrame.addingReportingOverflow(Int64(frameCount)).overflow else {
            recordOverflow()
            return false
        }
        guard frameCount > 0 else { return true }
        guard let normalizedStart = normalized(startFrame) else { recordOverflow(); return false }
        let (end, endOverflow) = normalizedStart.addingReportingOverflow(Int64(frameCount))
        guard !endOverflow else { recordOverflow(); return false }
        if normalizedStart > producerEndFrame {
            _ = recordedDropoutCount.add(1, ordering: .relaxed)
        }
        let first = max(0, max(normalizedStart, producerEndFrame))
        producerRawEndFrame = max(producerRawEndFrame, startFrame + Int64(frameCount))
        producerEndFrame = max(producerEndFrame, end)
        guard first < end else { return true }
        let framesPerBlock = blockSampleCapacity / channelCount
        var offset = Int(first - normalizedStart)
        while offset < frameCount {
            guard let slot = reserveProducerSlot() else {
                recordOverflow(startFrame: normalizedStart + Int64(offset), frameCount: Int64(frameCount - offset))
                return false
            }
            let count = min(framesPerBlock, frameCount - offset)
            let destination = storage.advanced(by: slot * blockSampleCapacity)
            for frame in 0..<count {
                let base = frame * channelCount
                for channel in 0..<channelCount {
                    destination[base + channel] = channelData[channel][offset + frame]
                }
            }
            publish(slot: slot, startFrame: normalizedStart + Int64(offset), frameCount: Int64(count), sampleCount: count * channelCount)
            offset += count
        }
        return true
    }

    /// Records an invalid callback's known frame extent even if there is no sample data.
    public func noteMissing(startFrame: Int64, frameCount: Int) {
        guard frameCount >= 0,
              !startFrame.addingReportingOverflow(Int64(frameCount)).overflow else {
            recordOverflow()
            return
        }
        guard frameCount > 0 else { return }
        guard let normalizedStart = normalized(startFrame) else { recordOverflow(); return }
        let (end, endOverflow) = normalizedStart.addingReportingOverflow(Int64(frameCount))
        guard !endOverflow else { recordOverflow(); return }
        if normalizedStart > producerEndFrame {
            _ = recordedDropoutCount.add(1, ordering: .relaxed)
        }
        let first = max(0, max(normalizedStart, producerEndFrame))
        producerRawEndFrame = max(producerRawEndFrame, startFrame + Int64(frameCount))
        producerEndFrame = max(producerEndFrame, end)
        guard first < end else { return }
        _ = recordedDropoutCount.add(1, ordering: .relaxed)
        let gap = AudioGap(startFrame: first, frameCount: end - first, reason: .invalidBuffer)
        guard let slot = reserveProducerSlot() else {
            remember(gap)
            return
        }
        publish(slot: slot, startFrame: first, frameCount: end - first,
                sampleCount: 0, gap: gap)
    }

    /// Called after callbacks have stopped. Allows finish() to reconstruct loss at the end
    /// even when no subsequent successful callback can carry its position.
    public func finish(tailFrame: Int64) {
        precondition(tailFrame >= 0)
        let reconciledTail = max(0, normalized(tailFrame) ?? producerEndFrame)
        if finishedTail.exchange(reconciledTail, ordering: .acquiringAndReleasing) < 0,
           reconciledTail > producerEndFrame {
            _ = recordedDropoutCount.add(1, ordering: .relaxed)
        }
    }

    public var tailFrame: Int64? {
        let value = finishedTail.load(ordering: .acquiring)
        return value >= 0 ? value : nil
    }

    /// Only inspect after callbacks have stopped and all queued blocks have been consumed.
    public var trailingGap: AudioGap? { pendingGap }

    public func pop() -> AudioBlock? {
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)
        guard read < write else { return nil }
        let slot = Int(read % UInt64(capacity))
        let source = UnsafeBufferPointer(start: storage.advanced(by: slot * blockSampleCapacity), count: lengths[slot])
        let result = AudioBlock(startFrame: starts[slot], frameCount: frames[slot],
                                samples: Array(source), gapBefore: gapsBefore[slot], gap: gaps[slot])
        readSequence.store(read &+ 1, ordering: .releasing)
        return result
    }

    public var overflowCount: UInt64 { recordedOverflowCount.load(ordering: .relaxed) }
    /// Number of distinct callback losses: PTS discontinuities, invalid buffers,
    /// overflowed callbacks, and an uncovered stop tail. One discontinuity and one
    /// rejected callback can count separately if they describe different frame ranges.
    public var dropoutCount: UInt64 { recordedDropoutCount.load(ordering: .relaxed) }

    private func normalized(_ startFrame: Int64) -> Int64? {
        // One small forward difference can be PTS rounding. A second is
        // evidence of missing frames: restore the first difference before
        // placing this callback, so repeated short losses cannot vanish.
        let (delta, overflow) = startFrame.subtractingReportingOverflow(producerRawEndFrame)
        guard !overflow else { return nil }
        if delta >= 0 && delta <= timestampToleranceFrames {
            guard delta > 0 else { return producerEndFrame }
            if repeatedSmallGapLoss {
                let (mapped, mappedOverflow) = producerEndFrame.addingReportingOverflow(delta)
                return mappedOverflow ? nil : mapped
            }
            if suppressedSmallGapFrames > 0 {
                let (mapped, mappedOverflow) = producerEndFrame.addingReportingOverflow(
                    suppressedSmallGapFrames + delta)
                guard !mappedOverflow else { return nil }
                suppressedSmallGapFrames = 0
                repeatedSmallGapLoss = true
                return mapped
            }
            suppressedSmallGapFrames = delta
            return producerEndFrame
        }
        let (mapped, mappedOverflow) = producerEndFrame.addingReportingOverflow(delta)
        guard !mappedOverflow else { return nil }
        suppressedSmallGapFrames = 0
        repeatedSmallGapLoss = false
        return mapped
    }

    private func reserveProducerSlot() -> Int? {
        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)
        guard write &- read < UInt64(capacity) else { return nil }
        return Int(write % UInt64(capacity))
    }

    private func publish(slot: Int, startFrame: Int64, frameCount: Int64,
                         sampleCount: Int, gap: AudioGap? = nil) {
        lengths[slot] = sampleCount
        starts[slot] = startFrame
        frames[slot] = frameCount
        gaps[slot] = gap
        gapsBefore[slot] = pendingGap
        pendingGap = nil
        let write = writeSequence.load(ordering: .relaxed)
        writeSequence.store(write &+ 1, ordering: .releasing)
    }

    private func remember(_ gap: AudioGap) {
        if let pendingGap, pendingGap.endFrame == gap.startFrame,
           pendingGap.reason == gap.reason {
            self.pendingGap = AudioGap(startFrame: pendingGap.startFrame,
                                       frameCount: pendingGap.frameCount + gap.frameCount,
                                       reason: gap.reason)
        } else {
            // When a full ring loses callbacks of mixed kinds, preserve the full
            // lost extent as one overflow event rather than silently losing frames.
            let first = min(pendingGap?.startFrame ?? gap.startFrame, gap.startFrame)
            self.pendingGap = AudioGap(startFrame: first,
                                       frameCount: max(pendingGap?.endFrame ?? gap.endFrame, gap.endFrame) - first,
                                       reason: pendingGap == nil ? gap.reason : .overflow)
        }
    }

    private func recordOverflow(startFrame: Int64 = 0, frameCount: Int64 = 0) {
        if frameCount > 0 {
            remember(AudioGap(startFrame: startFrame, frameCount: frameCount, reason: .overflow))
        }
        _ = recordedOverflowCount.add(1, ordering: .relaxed)
        _ = recordedDropoutCount.add(1, ordering: .relaxed)
    }
}
