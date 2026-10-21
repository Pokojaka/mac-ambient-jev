// Pinned reconstruction semantics: FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
import Foundation

struct ReconstructionWindow {
    let offsetSeconds: Double
    let speakerBits: [UInt8]
    let assignments: [Int]
}

struct ReconstructedSegment: Equatable {
    let clusterIndex: Int
    let startSeconds: Float
    let endSeconds: Float
    let quality: Float

    var speakerID: String { "S\(clusterIndex + 1)" }
}

struct ReconstructionResult {
    let segments: [ReconstructedSegment]
    let peakBufferedFrames: Int
    let peakBufferedVoteEntries: Int
}

enum ReconstructionError: Error {
    case invalidInput(String)
}

enum Community1Reconstruction {
    private struct FrameVotes {
        var expectedCountSum = 0
        var coveringCount = 0
        var votes: [Int: Int] = [:]
    }

    private struct ActiveRun {
        var start: Double
        var end: Double
        var scoreSum: Double
        var frameCount: Int
    }

    static func reconstruct(
        windows: [ReconstructionWindow],
        clusterCount: Int,
        frameDuration: Double
    ) throws -> ReconstructionResult {
        guard clusterCount >= 0 else {
            throw ReconstructionError.invalidInput("clusterCount must be nonnegative")
        }
        guard frameDuration.isFinite, frameDuration > 0 else {
            throw ReconstructionError.invalidInput("frameDuration must be finite and positive")
        }
        guard !windows.isEmpty else {
            return ReconstructionResult(segments: [], peakBufferedFrames: 0, peakBufferedVoteEntries: 0)
        }

        let effectiveClusterCount = max(clusterCount, 1)
        var commonFrameCount: Int?
        var previousOffset: Double?
        var maximumTimelineEnd = 0.0

        // Validate the complete geometry before any timeline allocation or integer conversion.
        for (windowIndex, window) in windows.enumerated() {
            guard window.offsetSeconds.isFinite, window.offsetSeconds >= 0 else {
                throw ReconstructionError.invalidInput("window \(windowIndex) offset must be finite and nonnegative")
            }
            if let previousOffset, window.offsetSeconds < previousOffset {
                throw ReconstructionError.invalidInput("window offsets must be nondecreasing")
            }
            previousOffset = window.offsetSeconds

            guard !window.speakerBits.isEmpty else {
                throw ReconstructionError.invalidInput("window \(windowIndex) must contain at least one frame")
            }
            if let commonFrameCount, window.speakerBits.count != commonFrameCount {
                throw ReconstructionError.invalidInput("all windows must have identical frame counts")
            }
            commonFrameCount = window.speakerBits.count

            guard window.speakerBits.allSatisfy({ $0 <= 7 }) else {
                throw ReconstructionError.invalidInput("speaker bits must be powerset values from 0 through 7")
            }
            guard window.assignments.count == Community1Profile.localSpeakers else {
                throw ReconstructionError.invalidInput("each window must have exactly three local speaker assignments")
            }
            for assignment in window.assignments {
                guard assignment == -2 || (assignment >= 0 && assignment < effectiveClusterCount) else {
                    throw ReconstructionError.invalidInput("assignments must be -2 or valid cluster indices")
                }
            }

            let windowDuration = Double(window.speakerBits.count) * frameDuration
            guard windowDuration.isFinite else {
                throw ReconstructionError.invalidInput("window timeline duration is not finite")
            }
            let windowEnd = window.offsetSeconds + windowDuration
            guard windowEnd.isFinite else {
                throw ReconstructionError.invalidInput("window timeline end is not finite")
            }
            maximumTimelineEnd = max(maximumTimelineEnd, windowEnd)
        }

        let frameCountValue = maximumTimelineEnd / frameDuration
        guard frameCountValue.isFinite else {
            throw ReconstructionError.invalidInput("timeline frame count is not finite")
        }
        let roundedFrameCount = ceil(frameCountValue)
        // Double(Int.max) rounds to the first out-of-range Int value on 64-bit platforms.
        guard roundedFrameCount < Double(Int.max) else {
            throw ReconstructionError.invalidInput("timeline frame count exceeds Int range")
        }
        let totalFrames = max(1, Int(roundedFrameCount))
        let lastFrameStart = Double(totalFrames - 1) * frameDuration
        let lastFrameEnd = lastFrameStart + frameDuration
        guard lastFrameStart.isFinite, lastFrameEnd.isFinite,
              Float(lastFrameStart).isFinite, Float(lastFrameEnd).isFinite,
              Float(maximumTimelineEnd).isFinite else {
            throw ReconstructionError.invalidInput("timeline output seconds exceed finite Float range")
        }

        // Check every exact source-frame mapping before the Int conversions used below.
        for window in windows {
            for frameIndex in window.speakerBits.indices {
                let sourceFrameStart = window.offsetSeconds + Double(frameIndex) * frameDuration
                let scaledFrame = sourceFrameStart / frameDuration
                guard sourceFrameStart.isFinite, scaledFrame.isFinite else {
                    throw ReconstructionError.invalidInput("source frame mapping is not finite")
                }
                let roundedFrame = scaledFrame.rounded()
                guard roundedFrame >= 0, roundedFrame < Double(Int.max) else {
                    throw ReconstructionError.invalidInput("source frame mapping exceeds Int range")
                }
            }
        }

        // With binary masks, FluidAudio's positive activation sum and positive activation
        // count are identical integer votes: each local frame contributes at most one vote
        // per mapped cluster, even when multiple local slots map to the same cluster.
        // Rolling rows are safe because nondecreasing window offsets mean no later window
        // can touch a frame below the current window's first mapped frame.
        var bufferedRows: [Int: FrameVotes] = [:]
        var activeRuns: [Int: ActiveRun] = [:]
        var rawSegments: [ReconstructedSegment] = []
        var nextFrameToFlush = 0
        var peakBufferedFrames = 0
        var peakBufferedVoteEntries = 0

        func mappedFrameIndex(window: ReconstructionWindow, frameIndex: Int) -> Int {
            let sourceFrameStart = window.offsetSeconds + Double(frameIndex) * frameDuration
            let rounded = Int((sourceFrameStart / frameDuration).rounded())
            return min(max(rounded, 0), totalFrames - 1)
        }

        func appendRun(cluster: Int, run: ActiveRun, endTime: Double) {
            guard endTime > run.start else { return }
            let averageScore = run.scoreSum / Double(run.frameCount)
            let quality = Float(min(max(averageScore, 0), 1))
            rawSegments.append(
                ReconstructedSegment(
                    clusterIndex: cluster,
                    startSeconds: Float(run.start),
                    endSeconds: Float(endTime),
                    quality: quality
                )
            )
        }

        func flush(untilExclusive limit: Int) throws {
            try Task.checkCancellation()
            while nextFrameToFlush < limit {
                let frameIndex = nextFrameToFlush
                let row = bufferedRows.removeValue(forKey: frameIndex)
                var requiredSpeakers = 0
                if let row, row.coveringCount > 0 {
                    let meanExpected = Double(row.expectedCountSum) / Double(row.coveringCount)
                    requiredSpeakers = min(
                        max(Int(meanExpected.rounded(.toNearestOrEven)), 0),
                        min(effectiveClusterCount, Community1Profile.localSpeakers)
                    )
                }

                var selected: [Int] = []
                if requiredSpeakers > 0, let row {
                    let rankedPositiveVotes = row.votes.sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value > rhs.value }
                        return lhs.key < rhs.key
                    }
                    selected = rankedPositiveVotes.prefix(requiredSpeakers).map(\.key)
                    var candidate = 0
                    while selected.count < requiredSpeakers {
                        if !selected.contains(candidate) { selected.append(candidate) }
                        candidate += 1
                    }
                    selected.sort()
                }

                let frameStart = Double(frameIndex) * frameDuration
                let frameEnd = frameStart + frameDuration
                for cluster in activeRuns.keys.sorted() where !selected.contains(cluster) {
                    if let run = activeRuns.removeValue(forKey: cluster) {
                        appendRun(cluster: cluster, run: run, endTime: frameStart)
                    }
                }

                for cluster in selected {
                    let score = (row?.votes[cluster] ?? 0) > 0 ? 1.0 : 0.0
                    if var run = activeRuns[cluster] {
                        run.end = frameEnd
                        run.scoreSum += score
                        run.frameCount += 1
                        activeRuns[cluster] = run
                    } else {
                        activeRuns[cluster] = ActiveRun(
                            start: frameStart,
                            end: frameEnd,
                            scoreSum: score,
                            frameCount: 1
                        )
                    }
                }
                nextFrameToFlush += 1
            }
        }

        for window in windows {
            try Task.checkCancellation()
            let firstMappedFrame = mappedFrameIndex(window: window, frameIndex: 0)
            try flush(untilExclusive: firstMappedFrame)

            for frameIndex in window.speakerBits.indices {
                let bits = window.speakerBits[frameIndex]
                let globalFrame = mappedFrameIndex(window: window, frameIndex: frameIndex)
                var row = bufferedRows[globalFrame] ?? FrameVotes()
                let (expectedCountSum, expectedOverflow) = row.expectedCountSum.addingReportingOverflow(bits.nonzeroBitCount)
                guard !expectedOverflow else {
                    throw ReconstructionError.invalidInput("expected speaker-count accumulation exceeds Int range")
                }
                let (coveringCount, coveringOverflow) = row.coveringCount.addingReportingOverflow(1)
                guard !coveringOverflow else {
                    throw ReconstructionError.invalidInput("frame coverage count exceeds Int range")
                }
                row.expectedCountSum = expectedCountSum
                row.coveringCount = coveringCount

                var activeClusters: [Int] = []
                for localSpeaker in 0..<Community1Profile.localSpeakers
                    where bits & (UInt8(1) << UInt8(localSpeaker)) != 0 {
                    let cluster = window.assignments[localSpeaker]
                    if cluster >= 0, !activeClusters.contains(cluster) {
                        activeClusters.append(cluster)
                    }
                }
                for cluster in activeClusters {
                    let (voteCount, voteOverflow) = (row.votes[cluster] ?? 0).addingReportingOverflow(1)
                    guard !voteOverflow else {
                        throw ReconstructionError.invalidInput("cluster vote count exceeds Int range")
                    }
                    row.votes[cluster] = voteCount
                }
                bufferedRows[globalFrame] = row
            }

            var voteEntryCount = 0
            for row in bufferedRows.values {
                let (sum, overflow) = voteEntryCount.addingReportingOverflow(row.votes.count)
                guard !overflow else {
                    throw ReconstructionError.invalidInput("buffered vote-entry count exceeds Int range")
                }
                voteEntryCount = sum
            }
            peakBufferedFrames = max(peakBufferedFrames, bufferedRows.count)
            peakBufferedVoteEntries = max(peakBufferedVoteEntries, voteEntryCount)
        }

        try flush(untilExclusive: totalFrames)
        for cluster in activeRuns.keys.sorted() {
            if let run = activeRuns[cluster] {
                appendRun(cluster: cluster, run: run, endTime: run.end)
            }
        }

        let gapThreshold = max(Community1Profile.minimumGapSeconds, Community1Profile.minimumOffSeconds)
        let merged = mergeAdjacentSegments(rawSegments, gapThreshold: gapThreshold)
        let sanitized = sanitize(merged)
        return ReconstructionResult(
            segments: sanitized,
            peakBufferedFrames: peakBufferedFrames,
            peakBufferedVoteEntries: peakBufferedVoteEntries
        )
    }

    private static func stableStartOrder(
        _ segments: [ReconstructedSegment]
    ) -> [ReconstructedSegment] {
        segments.enumerated().sorted { lhs, rhs in
            if lhs.element.startSeconds == rhs.element.startSeconds {
                return lhs.offset < rhs.offset
            }
            return lhs.element.startSeconds < rhs.element.startSeconds
        }.map(\.element)
    }

    private static func mergeAdjacentSegments(
        _ segments: [ReconstructedSegment],
        gapThreshold: Double
    ) -> [ReconstructedSegment] {
        let ordered = stableStartOrder(segments)
        guard let first = ordered.first else { return [] }
        var merged: [ReconstructedSegment] = []
        var current = first

        for segment in ordered.dropFirst() {
            if segment.clusterIndex == current.clusterIndex {
                let gap = Double(segment.startSeconds) - Double(current.endSeconds)
                if gap <= gapThreshold {
                    let lhsDuration = Double(current.endSeconds - current.startSeconds)
                    let rhsDuration = Double(segment.endSeconds - segment.startSeconds)
                    let totalDuration = lhsDuration + rhsDuration
                    let blendedQuality: Float
                    if totalDuration > 0 {
                        let weighted = Double(current.quality) * lhsDuration
                            + Double(segment.quality) * rhsDuration
                        blendedQuality = Float(min(max(weighted / totalDuration, 0), 1))
                    } else {
                        blendedQuality = min(max((current.quality + segment.quality) / 2, 0), 1)
                    }
                    current = ReconstructedSegment(
                        clusterIndex: current.clusterIndex,
                        startSeconds: current.startSeconds,
                        endSeconds: max(current.endSeconds, segment.endSeconds),
                        quality: blendedQuality
                    )
                    continue
                }
            }
            merged.append(current)
            current = segment
        }
        merged.append(current)
        return merged
    }

    private static func sanitize(
        _ segments: [ReconstructedSegment]
    ) -> [ReconstructedSegment] {
        var ordered = stableStartOrder(segments)
        let minimumDuration = max(
            Float(Community1Profile.minimumSegmentSeconds),
            Float(Community1Profile.minimumOnSeconds)
        )
        ordered = ordered.filter { ($0.endSeconds - $0.startSeconds) >= minimumDuration }

        var retained: [ReconstructedSegment] = []
        let exclusiveMinimum = Float(Community1Profile.minimumSegmentSeconds)
        for segment in ordered {
            var adjustedStart = segment.startSeconds
            let adjustedEnd = segment.endSeconds
            if let previous = retained.last, adjustedStart < previous.endSeconds {
                adjustedStart = previous.endSeconds
            }
            guard adjustedStart < adjustedEnd else { continue }

            let retainedDuration = adjustedEnd - adjustedStart
            guard retainedDuration >= exclusiveMinimum else { continue }

            let originalDuration = segment.endSeconds - segment.startSeconds
            let qualityScale = originalDuration > 0 ? retainedDuration / originalDuration : 1
            let adjustedQuality = min(max(segment.quality * qualityScale, 0), 1)
            retained.append(
                ReconstructedSegment(
                    clusterIndex: segment.clusterIndex,
                    startSeconds: adjustedStart,
                    endSeconds: adjustedEnd,
                    quality: adjustedQuality
                )
            )
        }
        return retained
    }
}
