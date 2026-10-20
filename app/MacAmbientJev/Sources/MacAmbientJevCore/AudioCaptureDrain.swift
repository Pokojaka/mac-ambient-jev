import Foundation

/// Actor-isolated writer operations used by the capture drain. The protocol permits a
/// suspended writer in tests, so actor reentrancy can be exercised deterministically.
public protocol AudioCaptureWriting: Actor {
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
    private let converter: any CanonicalAudioConverting
    private var cursorFrame: Int64 = 0 // Source/device coordinates, including replacement silence.
    private var writerStartFrame: Int64?
    private var writtenFrames: Int64 = 0
    private var gapCount = 0
    private var totalGapFrames: Int64 = 0
    private var pendingBlock: AudioBlock?
    private var appendNeedsReconciliation = false
    private var pendingOutput: [Float] = []
    private var pendingOutputOffset = 0
    private var pendingGapEndFrame: Int64?
    private var eosFlushed = false
    private var finishedCheckpoint: AudioCheckpoint?

    // An actor does not stay exclusive while awaiting another actor. Keep all
    // drain/checkpoint/finish operations in one FIFO lane across writer awaits.
    private var operationInProgress = false
    private var waitingOperations: [CheckedContinuation<Void, Never>] = []
    private var nextWaitingOperation = 0
    private var queuedOperationObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var queuedOperationCount: Int {
        waitingOperations.count - nextWaitingOperation
    }

    public init(ring: AudioBlockRing, writer: any AudioCaptureWriting, converter: any CanonicalAudioConverting) {
        self.ring = ring
        self.writer = writer
        self.converter = converter
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

    /// The writer's committed chunks only, without draining or flushing. After a failed finish()
    /// this is the healthy prefix: every chunk in it was published and indexed.
    public func durableCheckpoint() async -> AudioCheckpoint {
        await acquire()
        defer { release() }
        return await writer.committedSnapshot()
    }

    public func finish() async throws -> AudioCheckpoint {
        await acquire()
        defer { release() }
        if let finishedCheckpoint { return finishedCheckpoint }
        _ = try await drainLocked()
        if let loss = ring.trailingGap {
            try await fill(to: loss.startFrame, reason: .missingCallback)
            try await fill(to: loss.endFrame, reason: loss.reason)
        }
        if let tail = ring.tailFrame {
            try await fill(to: tail, reason: .stopTail)
        }
        if !eosFlushed {
            pendingOutput = try converter.finish()
            pendingOutputOffset = 0
            eosFlushed = true
        }
        try await appendPendingOutput()
        let checkpoint = try await writer.finish()
        finishedCheckpoint = checkpoint
        return checkpoint
    }

    /// Includes timestamp discontinuities and invalid/overflow ranges filled with silence.
    public func gapStatistics() -> (count: Int, frames: Int64) {
        (gapCount, totalGapFrames)
    }

    func waitForQueuedOperations(_ count: Int) async {
        precondition(count > 0, "Queued operation count must be positive")
        guard queuedOperationCount < count else { return }
        await withCheckedContinuation { continuation in
            queuedOperationObservers.append((count, continuation))
            resumeQueuedOperationObserversIfReady()
        }
    }

    private func acquire() async {
        if operationInProgress {
            await withCheckedContinuation { continuation in
                waitingOperations.append(continuation)
                resumeQueuedOperationObserversIfReady()
            }
        } else {
            operationInProgress = true
        }
    }

    private func resumeQueuedOperationObserversIfReady() {
        let queuedCount = queuedOperationCount
        var remainingObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in queuedOperationObservers {
            if queuedCount >= observer.count {
                observer.continuation.resume()
            } else {
                remainingObservers.append(observer)
            }
        }
        queuedOperationObservers = remainingObservers
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
            let checkpoint = await writer.committedSnapshot()
            try CanonicalAudio.validate(sampleRate: checkpoint.sampleRate, channelCount: checkpoint.channelCount,
                                        sampleFormat: checkpoint.sampleFormat)
            writerStartFrame = checkpoint.committedFrames
        }
        try await appendPendingOutput()
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
                guard block.samples.count == Int(block.frameCount) else {
                    throw CanonicalAudioError.invalidSamples
                }
                let samples = overlap == 0 ? block.samples : Array(block.samples[Int(overlap)...])
                pendingOutput = try converter.convert(mono: samples)
                pendingOutputOffset = 0
                cursorFrame = block.startFrame + block.frameCount
                // Source has been consumed. A failed append retains its output, not its input.
                pendingBlock = nil
                try await appendPendingOutput()
            }
            pendingBlock = nil
            count += 1
        }
        return count
    }

    private func appendPendingOutput() async throws {
        if appendNeedsReconciliation {
            let checkpoint = try await writer.checkpoint()
            let accepted = checkpoint.committedFrames - writerStartFrame! - writtenFrames
            guard accepted >= 0, accepted <= pendingOutput.count - pendingOutputOffset else {
                throw DurableAudioWriterError.checkpointFrameCountMismatch
            }
            pendingOutputOffset += Int(accepted)
            writtenFrames += accepted
            appendNeedsReconciliation = false
        }
        guard pendingOutputOffset < pendingOutput.count else {
            pendingOutput.removeAll(keepingCapacity: true)
            pendingOutputOffset = 0
            return
        }
        let samples = pendingOutputOffset == 0 ? pendingOutput : Array(pendingOutput[pendingOutputOffset...])
        do {
            try await writer.append(samples: samples)
        } catch {
            appendNeedsReconciliation = true
            throw error
        }
        writtenFrames += Int64(samples.count)
        pendingOutput.removeAll(keepingCapacity: true)
        pendingOutputOffset = 0
    }

    private func fill(to endFrame: Int64, reason: AudioGapReason) async throws {
        guard endFrame > cursorFrame else {
            if pendingGapEndFrame == endFrame { pendingGapEndFrame = nil }
            return
        }
        if pendingGapEndFrame != endFrame {
            let start = try CanonicalAudio.boundary(cursorFrame, sampleRate: converter.sourceSampleRate)
            let end = try CanonicalAudio.boundary(endFrame, sampleRate: converter.sourceSampleRate)
            if end > start {
                try await writer.recordGap(startFrame: writerStartFrame! + start, frameCount: end - start, reason: reason)
                gapCount += 1
                totalGapFrames += end - start
            }
            pendingGapEndFrame = endFrame
        }
        let silence = [Float](repeating: 0, count: 4096)
        while cursorFrame < endFrame {
            let frames = Int(min(endFrame - cursorFrame, Int64(silence.count)))
            pendingOutput = try converter.convert(mono: frames == silence.count ? silence : Array(silence[..<frames]))
            pendingOutputOffset = 0
            cursorFrame += Int64(frames)
            try await appendPendingOutput()
        }
        pendingGapEndFrame = nil
    }
}
