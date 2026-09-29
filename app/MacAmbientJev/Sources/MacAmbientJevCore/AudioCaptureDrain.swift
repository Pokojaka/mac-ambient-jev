import Foundation

/// Actor-isolated writer operations used by the capture drain. The protocol permits a
/// suspended writer in tests, so actor reentrancy can be exercised deterministically.
public protocol AudioCaptureWriting: Actor {
    var channelCount: Int { get }
    func append(samples: [Float]) async throws
    func recordGap(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) throws
    func committedSnapshot() -> AudioCheckpoint
    /// Flushes accepted but not yet committed samples after an interrupted append.
    func checkpoint() throws -> AudioCheckpoint
    func finish() throws -> AudioCheckpoint
}

extension DurableAudioWriter: AudioCaptureWriting {}

public actor AudioCaptureDrain {
    private let ring: AudioBlockRing
    private let writer: any AudioCaptureWriting
    private var cursorFrame: Int64 = 0
    private var writerStartFrame: Int64?
    private var pendingBlock: AudioBlock?
    private var appendNeedsReconciliation = false
    private var pendingGapEndFrame: Int64?

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
        if appendNeedsReconciliation {
            // append can commit some chunks and retain another in the writer before
            // throwing. Flush that accepted prefix before deciding what to resend.
            let checkpoint = try await writer.checkpoint()
            let accepted = checkpoint.committedFrames - writerStartFrame!
            cursorFrame = max(cursorFrame, accepted)
            appendNeedsReconciliation = false
        }
        var count = 0
        while let block = pendingBlock ?? ring.pop() {
            pendingBlock = block
            if let loss = block.gapBefore {
                try await fill(to: loss.startFrame, reason: .missingCallback)
                try await fill(to: min(loss.endFrame, block.startFrame), reason: loss.reason)
            }
            try await fill(to: block.startFrame, reason: .missingCallback)
            if let loss = block.gap {
                try await fill(to: loss.endFrame, reason: loss.reason)
                pendingBlock = nil
                continue
            }
            let overlap = max(0, cursorFrame - block.startFrame)
            if overlap < block.frameCount {
                let channels = await writer.channelCount
                let (sampleOffset, overflow) = Int(overlap).multipliedReportingOverflow(by: channels)
                guard !overflow, sampleOffset <= block.samples.count else {
                    throw DurableAudioWriterError.invalidChannelSampleCount
                }
                let samples = sampleOffset == 0 ? block.samples : Array(block.samples[sampleOffset...])
                try await append(samples: samples)
                cursorFrame = block.startFrame + block.frameCount
            }
            pendingBlock = nil
            count += 1
        }
        return count
    }

    private func append(samples: [Float]) async throws {
        do {
            try await writer.append(samples: samples)
        } catch {
            appendNeedsReconciliation = true
            throw error
        }
    }

    private func fill(to endFrame: Int64, reason: AudioGapReason) async throws {
        guard endFrame > cursorFrame else {
            if pendingGapEndFrame == endFrame { pendingGapEndFrame = nil }
            return
        }
        if pendingGapEndFrame != endFrame {
            let (absoluteStart, overflow) = writerStartFrame!.addingReportingOverflow(cursorFrame)
            guard !overflow else { throw DurableAudioWriterError.checkpointFrameCountMismatch }
            try await writer.recordGap(startFrame: absoluteStart, frameCount: endFrame - cursorFrame, reason: reason)
            pendingGapEndFrame = endFrame
        }
        let channels = await writer.channelCount
        let silenceFrames = max(1, 4_096 / channels)
        let silence = [Float](repeating: 0, count: silenceFrames * channels)
        while cursorFrame < endFrame {
            let frames = Int(min(endFrame - cursorFrame, Int64(silenceFrames)))
            let samples = frames == silenceFrames ? silence : Array(silence[..<(frames * channels)])
            try await append(samples: samples)
            cursorFrame += Int64(frames)
        }
        pendingGapEndFrame = nil
    }
}
