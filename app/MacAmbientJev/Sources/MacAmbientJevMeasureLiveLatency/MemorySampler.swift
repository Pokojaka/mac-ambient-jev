import Darwin
import Foundation
import MacAmbientJevRuntime

struct MemorySample: Encodable {
    let elapsed_seconds: Double
    let phase: String
    let footprint_bytes: UInt64
}

struct MemorySummary {
    let firstMedian: Double
    let lastMedian: Double
    let peak: UInt64
    let count: Int

    init(samples: [MemorySample], stopSeconds: Double) {
        let recording = samples.filter { $0.phase == "recording" }
        func median(_ values: [UInt64]) -> Double {
            let sorted = values.sorted()
            precondition(!sorted.isEmpty)
            let middle = sorted.count / 2
            if sorted.count % 2 == 1 { return Double(sorted[middle]) }
            return (Double(sorted[middle - 1]) + Double(sorted[middle])) / 2
        }
        firstMedian = median(recording.filter { $0.elapsed_seconds <= 300 }.map(\.footprint_bytes))
        lastMedian = median(recording.filter { $0.elapsed_seconds >= stopSeconds - 300 }.map(\.footprint_bytes))
        peak = samples.map(\.footprint_bytes).max()!
        count = samples.count
    }
}

final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var origin: ContinuousClock.Instant!
    private var stopped = false
    private var samples: [MemorySample] = []
    private var failure: Error?

    init(url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func start(at origin: ContinuousClock.Instant) {
        lock.lock(); defer { lock.unlock() }
        self.origin = origin
        record(at: origin)
    }

    func sample() {
        lock.lock(); defer { lock.unlock() }
        record(at: .now)
    }

    func stop() -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        let instant = ContinuousClock.now
        stopped = true
        record(at: instant)
        return instant
    }

    func finish() throws -> [MemorySample] {
        lock.lock(); defer { lock.unlock() }
        record(at: .now)
        try handle.close()
        if let failure { throw failure }
        return samples
    }

    private func record(at instant: ContinuousClock.Instant) {
        guard failure == nil else { return }
        do {
            let sample = MemorySample(elapsed_seconds: origin.duration(to: instant) / .seconds(1),
                                      phase: stopped ? "stopping" : "recording",
                                      footprint_bytes: try processFootprint().get())
            var data = try JSONEncoder().encode(sample)
            data.append(0x0a)
            try handle.write(contentsOf: data)
            samples.append(sample)
        } catch {
            failure = error
        }
    }
}
