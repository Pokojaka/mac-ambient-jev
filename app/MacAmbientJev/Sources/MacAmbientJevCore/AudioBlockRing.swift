import Foundation
import Synchronization

public struct AudioBlock: Sendable, Equatable {
    public let droppedSamplesBefore: Int
    public let samples: [Float]
}

public final class AudioBlockRing: @unchecked Sendable {
    private let capacity: Int
    private let blockSampleCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lengths: UnsafeMutablePointer<Int>
    private let droppedBefore: UnsafeMutablePointer<Int>
    private var pendingDroppedSamples = 0

    private let writeSequence = Atomic<UInt64>(0)
    private let readSequence = Atomic<UInt64>(0)
    private let recordedOverflowCount = Atomic<UInt64>(0)

    public init(capacity: Int, blockFrameCapacity: Int) {
        precondition(capacity > 0)
        precondition(blockFrameCapacity > 0)

        self.capacity = capacity
        self.blockSampleCapacity = blockFrameCapacity

        let totalSampleCapacity = capacity * blockFrameCapacity
        self.storage = .allocate(capacity: totalSampleCapacity)
        self.storage.initialize(
            repeating: 0,
            count: totalSampleCapacity
        )

        self.lengths = .allocate(capacity: capacity)
        self.lengths.initialize(repeating: 0, count: capacity)
        self.droppedBefore = .allocate(capacity: capacity)
        self.droppedBefore.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity * blockSampleCapacity)
        storage.deallocate()
        lengths.deinitialize(count: capacity)
        lengths.deallocate()
        droppedBefore.deinitialize(count: capacity)
        droppedBefore.deallocate()
    }

    @discardableResult
    public func push(samples: [Float]) -> Bool {
        guard samples.count <= blockSampleCapacity,
              let slot = reserveProducerSlot() else {
            recordOverflow(droppedSamples: samples.count)
            return false
        }

        let destination = storage.advanced(
            by: slot * blockSampleCapacity
        )
        for index in samples.indices {
            destination[index] = samples[index]
        }
        lengths[slot] = samples.count
        publishProducedSlot(slot)
        return true
    }

    @discardableResult
    public func pushPlanarFloat32(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Bool {
        guard channelCount > 0, frameCount >= 0 else {
            recordOverflow()
            return false
        }

        let (sampleCount, overflow) =
            channelCount.multipliedReportingOverflow(by: frameCount)
        guard !overflow else {
            recordOverflow()
            return false
        }
        guard sampleCount <= blockSampleCapacity,
              let slot = reserveProducerSlot() else {
            recordOverflow(droppedSamples: sampleCount)
            return false
        }

        let destination = storage.advanced(
            by: slot * blockSampleCapacity
        )
        for frame in 0..<frameCount {
            let destinationBase = frame * channelCount
            for channel in 0..<channelCount {
                destination[destinationBase + channel] =
                    channelData[channel][frame]
            }
        }

        lengths[slot] = sampleCount
        publishProducedSlot(slot)
        return true
    }

    public func pop() -> AudioBlock? {
        let read = readSequence.load(ordering: .relaxed)
        let write = writeSequence.load(ordering: .acquiring)

        guard read < write else {
            return nil
        }

        let slot = Int(read % UInt64(capacity))
        let length = lengths[slot]
        let source = UnsafeBufferPointer(
            start: storage.advanced(
                by: slot * blockSampleCapacity
            ),
            count: length
        )
        let result = AudioBlock(
            droppedSamplesBefore: droppedBefore[slot],
            samples: Array(source)
        )

        readSequence.store(
            read &+ 1,
            ordering: .releasing
        )
        return result
    }

    public var overflowCount: UInt64 {
        recordedOverflowCount.load(ordering: .relaxed)
    }

    private func reserveProducerSlot() -> Int? {
        let write = writeSequence.load(ordering: .relaxed)
        let read = readSequence.load(ordering: .acquiring)

        guard write &- read < UInt64(capacity) else {
            return nil
        }

        return Int(write % UInt64(capacity))
    }

    private func publishProducedSlot(_ slot: Int) {
        droppedBefore[slot] = pendingDroppedSamples
        pendingDroppedSamples = 0
        let write = writeSequence.load(ordering: .relaxed)
        writeSequence.store(
            write &+ 1,
            ordering: .releasing
        )
    }

    private func recordOverflow(droppedSamples: Int = 0) {
        let (total, overflow) =
            pendingDroppedSamples.addingReportingOverflow(droppedSamples)
        pendingDroppedSamples = overflow ? Int.max : total
        _ = recordedOverflowCount.add(
            1,
            ordering: .relaxed
        )
    }
}
