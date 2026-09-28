import Foundation

/// Actor-isolated writer operations used by the capture drain. The protocol permits a
/// suspended writer in tests, so actor reentrancy can be exercised deterministically.
public protocol AudioCaptureWriting: Actor {
    var channelCount: Int { get }
    func append(samples: [Float]) async throws
    func recordGap(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) throws
    func committedSnapshot() -> AudioCheckpoint
    func finish() throws -> AudioCheckpoint
}

extension DurableAudioWriter: AudioCaptureWriting {}

public actor AudioCaptureDrain {
    private let ring: AudioBlockRing
    private let writer: any AudioCaptureWriting
    private var cursorFrame: Int64 = 0
    private var writerStartFrame: Int64?

    // An actor does not stay exclusive while awaiting another actor. Keep all
    // drain/checkpoint/finish operations in one FIFO lane across writer awaits.
    private var operationInProgress = false
    private var waitingOperations: [CheckedContinuation<Void, Never>] = []
    private var nextWaitingOperation = 0

    public init(ring: AudioBlockRing, writer: any AudioCaptureWriting) {
        self.ring = ring
        self.writer = writer
    }

    @discardableResult
    public func drainAvailable() async throws -> Int {
        await acquire()
        defer { release() }
        return try await drainLocked()
    }

    /// Drains queued blocks before returning the writer's durable full-chunk boundary.
    public func committedSnapshot() async throws -> AudioCheckpoint {
        await acquire()
        defer { release() }
        _ = try await drainLocked()
        return await writer.committedSnapshot()
    }

    public func finish() async throws -> AudioCheckpoint {
        await acquire()
        defer { release() }
        _ = try await drainLocked()
        if let loss = ring.trailingGap {
            try await fill(to: loss.startFrame, reason: .missingCallback)
            try await fill(to: loss.endFrame, reason: loss.reason)
        }
        if let tail = ring.tailFrame {
            try await fill(to: tail, reason: .stopTail)
        }
        return try await writer.finish()
    }

    private func acquire() async {
        if operationInProgress {
            await withCheckedContinuation { continuation in
                waitingOperations.append(continuation)
            }
        } else {
            operationInProgress = true
        }
    }

    private func release() {
        if nextWaitingOperation == waitingOperations.count {
            waitingOperations.removeAll(keepingCapacity: true)
            nextWaitingOperation = 0
            operationInProgress = false
        } else {
            let next = waitingOperations[nextWaitingOperation]
            nextWaitingOperation += 1
            next.resume()
        }
    }

    private func drainLocked() async throws -> Int {
        if writerStartFrame == nil {
            writerStartFrame = await writer.committedSnapshot().committedFrames
        }
        var count = 0
        while let block = ring.pop() {
            if let loss = block.gapBefore {
                try await fill(to: loss.startFrame, reason: .missingCallback)
                try await fill(to: min(loss.endFrame, block.startFrame), reason: loss.reason)
            }
            try await fill(to: block.startFrame, reason: .missingCallback)
            if let loss = block.gap {
                try await fill(to: loss.endFrame, reason: loss.reason)
                continue
            }
            let overlap = max(0, cursorFrame - block.startFrame)
            guard overlap < block.frameCount else { continue }
            let channels = await writer.channelCount
            let sampleOffset = Int(overlap) * channels
            guard sampleOffset <= block.samples.count else {
                throw DurableAudioWriterError.invalidChannelSampleCount
            }
            let samples = sampleOffset == 0 ? block.samples : Array(block.samples[sampleOffset...])
            try await writer.append(samples: samples)
            cursorFrame = block.startFrame + block.frameCount
            count += 1
        }
        return count
    }

    private func fill(to endFrame: Int64, reason: AudioGapReason) async throws {
        guard endFrame > cursorFrame else { return }
        let start = cursorFrame
        let frameCount = endFrame - start
        let (absoluteStart, overflow) = writerStartFrame!.addingReportingOverflow(start)
        guard !overflow else { throw DurableAudioWriterError.checkpointFrameCountMismatch }
        try await writer.recordGap(startFrame: absoluteStart, frameCount: frameCount, reason: reason)
        let channels = await writer.channelCount
        let silenceFrames = max(1, 4_096 / channels)
        let silence = [Float](repeating: 0, count: silenceFrames * channels)
        var remaining = frameCount
        while remaining > 0 {
            let frames = Int(min(remaining, Int64(silenceFrames)))
            let samples = frames == silenceFrames ? silence : Array(silence[..<(frames * channels)])
            try await writer.append(samples: samples)
            remaining -= Int64(frames)
        }
        cursorFrame = endFrame
    }
}
