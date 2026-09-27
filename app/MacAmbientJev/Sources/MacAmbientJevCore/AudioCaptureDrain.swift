import Foundation

public actor AudioCaptureDrain {
    private let ring: AudioBlockRing
    private let writer: DurableAudioWriter

    public init(ring: AudioBlockRing, writer: DurableAudioWriter) {
        self.ring = ring
        self.writer = writer
    }

    @discardableResult
    public func drainAvailable() async throws -> Int {
        var drainedBlockCount = 0

        let silence = [Float](repeating: 0, count: writer.channelCount * 4_096)
        while let block = ring.pop() {
            var remaining = block.droppedSamplesBefore
            while remaining > 0 {
                let count = min(remaining, silence.count)
                try await writer.append(samples: Array(silence[..<count]))
                remaining -= count
            }
            try await writer.append(samples: block.samples)
            drainedBlockCount += 1
        }

        return drainedBlockCount
    }

    /// Drains capture blocks that are already queued, then returns the durable
    /// full-chunk boundary without flushing the writer's partial chunk.
    public func committedSnapshot() async throws -> AudioCheckpoint {
        _ = try await drainAvailable()
        return await writer.committedSnapshot()
    }

    public func finish() async throws -> AudioCheckpoint {
        _ = try await drainAvailable()
        return try await writer.finish()
    }
}
