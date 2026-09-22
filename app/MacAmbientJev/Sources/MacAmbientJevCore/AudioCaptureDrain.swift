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

        while let samples = ring.pop() {
            try await writer.append(samples: samples)
            drainedBlockCount += 1
        }

        return drainedBlockCount
    }

    public func finish() async throws -> AudioCheckpoint {
        _ = try await drainAvailable()
        return try await writer.finish()
    }
}
