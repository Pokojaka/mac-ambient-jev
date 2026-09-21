import Foundation

public final class AudioBlockRing: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [[Float]]
    private var lengths: [Int]
    private var head = 0
    private var tail = 0
    private var storedCount = 0
    private var recordedOverflowCount: UInt64 = 0
    private let blockFrameCapacity: Int

    public init(capacity: Int, blockFrameCapacity: Int) {
        precondition(capacity > 0)
        precondition(blockFrameCapacity > 0)
        self.blockFrameCapacity = blockFrameCapacity
        self.blocks = (0..<capacity).map { _ in
            Array(repeating: 0, count: blockFrameCapacity)
        }
        self.lengths = Array(repeating: 0, count: capacity)
    }

    @discardableResult
    public func push(samples: [Float]) -> Bool {
        guard samples.count <= blockFrameCapacity else {
            recordOverflow()
            return false
        }
        guard lock.try() else {
            return false
        }
        defer { lock.unlock() }

        guard storedCount < blocks.count else {
            recordedOverflowCount += 1
            return false
        }

        for index in samples.indices {
            blocks[head][index] = samples[index]
        }
        lengths[head] = samples.count
        head = (head + 1) % blocks.count
        storedCount += 1
        return true
    }

    public func pop() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCount > 0 else { return nil }

        let length = lengths[tail]
        let result = Array(blocks[tail][0..<length])
        lengths[tail] = 0
        tail = (tail + 1) % blocks.count
        storedCount -= 1
        return result
    }

    public var overflowCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return recordedOverflowCount
    }

    private func recordOverflow() {
        lock.lock()
        recordedOverflowCount += 1
        lock.unlock()
    }
}
