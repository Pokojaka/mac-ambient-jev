import Foundation
import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1ReconstructionTests {
    @Test func everyFluidAudioReconstructionFixture() throws {
        let fixture = try DiarizationParityFixtures.load(
            "reconstruction.json",
            as: DiarizationReconstructionFixture.self
        )
        #expect(fixture.cases.count == 13, Comment(rawValue: "Every pinned reconstruction case must run"))

        for item in fixture.cases {
            let offsets = try item.chunkOffsets.float64()
            let weights = try item.speakerWeights.float32()
            let expectedWeightCount = item.hardClusters.count * item.numFrames * 3
            #expect(offsets.count == item.hardClusters.count, Comment(rawValue: item.name))
            #expect(item.speakerWeights.shape == [item.hardClusters.count, item.numFrames, 3], Comment(rawValue: item.name))
            #expect(weights.count == expectedWeightCount, Comment(rawValue: item.name))
            #expect(weights.allSatisfy { $0 == 0 || $0 == 1 }, Comment(rawValue: item.name))
            guard offsets.count == item.hardClusters.count,
                  item.speakerWeights.shape == [item.hardClusters.count, item.numFrames, 3],
                  weights.count == expectedWeightCount else {
                Issue.record("\(item.name): incompatible decoded input shapes or counts")
                continue
            }

            let windows = item.hardClusters.enumerated().map { windowIndex, assignments in
                let bits = (0..<item.numFrames).map { frameIndex -> UInt8 in
                    let base = (windowIndex * item.numFrames + frameIndex) * 3
                    var value: UInt8 = 0
                    for localSpeaker in 0..<3 {
                        let weight = weights[base + localSpeaker]
                        if weight == 1 {
                            value |= UInt8(1) << UInt8(localSpeaker)
                        }
                    }
                    return value
                }
                return ReconstructionWindow(
                    offsetSeconds: offsets[windowIndex],
                    speakerBits: bits,
                    assignments: assignments
                )
            }
            let result = try Community1Reconstruction.reconstruct(
                windows: windows,
                clusterCount: item.clusterCount,
                frameDuration: item.frameDuration
            )
            let expectedValues = try item.expectedSegments.float32()
            let expectedValueCount = item.expectedSpeakerIDs.count * 3
            #expect(item.expectedSegments.shape == [item.expectedSpeakerIDs.count, 3], Comment(rawValue: item.name))
            #expect(expectedValues.count == expectedValueCount, Comment(rawValue: item.name))
            #expect(result.segments.count == item.expectedSpeakerIDs.count, Comment(rawValue: item.name))
            guard item.expectedSegments.shape == [item.expectedSpeakerIDs.count, 3],
                  expectedValues.count == expectedValueCount,
                  result.segments.count == item.expectedSpeakerIDs.count else {
                Issue.record("\(item.name): incompatible expected shape/count or reconstructed segment count")
                continue
            }

            for index in result.segments.indices {
                let actual = result.segments[index]
                let base = index * 3
                #expect(actual.speakerID == item.expectedSpeakerIDs[index], Comment(rawValue: "\(item.name), segment \(index)"))
                #expect(actual.startSeconds.bitPattern == expectedValues[base].bitPattern, Comment(rawValue: "\(item.name), segment \(index) start"))
                #expect(actual.endSeconds.bitPattern == expectedValues[base + 1].bitPattern, Comment(rawValue: "\(item.name), segment \(index) end"))
                #expect(actual.quality.bitPattern == expectedValues[base + 2].bitPattern, Comment(rawValue: "\(item.name), segment \(index) quality"))
            }
        }
    }

    @Test func longRollingRunMatchesDenseReference() throws {
        let windowCount = 1_000
        let frameCount = Community1Profile.segmentationFrames
        let frameDuration = 10.0 / Double(frameCount)
        let windows = (0..<windowCount).map { windowIndex -> ReconstructionWindow in
            let first = windowIndex % 7
            let assignments: [Int]
            switch windowIndex % 4 {
            case 0:
                assignments = [first, (first + 1) % 7, -2]
            case 1:
                assignments = [first, first, (first + 3) % 7]
            case 2:
                assignments = [first, -2, (first + 2) % 7]
            default:
                assignments = [(first + 2) % 7, (first + 4) % 7, -2]
            }
            let bits = (0..<frameCount).map { frame -> UInt8 in
                switch frame {
                case 24..<145: return 1
                case 145..<190: return 3
                case 206..<305: return 2
                case 305..<360: return 7
                case 390..<485: return 4
                case 485..<558: return 5
                default: return 0
                }
            }
            return ReconstructionWindow(
                offsetSeconds: Double(windowIndex) * 2.0,
                speakerBits: bits,
                assignments: assignments
            )
        }

        let dense = denseReconstructionReference(
            windows: windows,
            clusterCount: 7,
            frameDuration: frameDuration
        )
        let actual = try Community1Reconstruction.reconstruct(
            windows: windows,
            clusterCount: 7,
            frameDuration: frameDuration
        )
        #expect(!(dense.isEmpty), Comment(rawValue: "The deterministic run must retain segments"))
        #expect(!(actual.segments.isEmpty), Comment(rawValue: "The rolling reconstruction must retain segments"))
        #expect(Set(dense.map(\.speakerID)).count >= 2, Comment(rawValue: "The input must exercise multiple speakers"))
        #expect(Set(dense.map(\.quality)).count > 1, Comment(rawValue: "The input must exercise varied qualities"))
        expectSegmentParity(actual.segments, dense, context: "1,000-window dense reference")
    }

    @Test func accumulatorMemoryBoundedByWindowCoverage() throws {
        func run(windowCount: Int) throws -> ReconstructionResult {
            let bits = [UInt8](repeating: 7, count: Community1Profile.segmentationFrames)
            let windows: [ReconstructionWindow] = (0..<windowCount).map { index -> ReconstructionWindow in
                ReconstructionWindow(
                    offsetSeconds: Double(index) * 2.0,
                    speakerBits: bits,
                    assignments: [3 * index, 3 * index + 1, 3 * index + 2]
                )
            }
            return try Community1Reconstruction.reconstruct(
                windows: windows,
                clusterCount: 3 * windowCount,
                frameDuration: 10.0 / Double(Community1Profile.segmentationFrames)
            )
        }

        let short = try run(windowCount: 20)
        let long = try run(windowCount: 2_000)
        let maximumCoverageRows = 590 // At most one segmentation window's grid coverage.
        let maximumVoteEntries = 5 * Community1Profile.segmentationFrames * 3 // Five 2-second-spaced windows cover 10 seconds.

        #expect(short.peakBufferedFrames > 0)
        #expect(long.peakBufferedFrames > 0)
        #expect(short.peakBufferedFrames <= maximumCoverageRows)
        #expect(long.peakBufferedFrames <= maximumCoverageRows)
        #expect(short.peakBufferedFrames == long.peakBufferedFrames)
        #expect(short.peakBufferedVoteEntries <= maximumVoteEntries)
        #expect(long.peakBufferedVoteEntries <= maximumVoteEntries)
        #expect(short.peakBufferedVoteEntries == long.peakBufferedVoteEntries)
    }

    @Test func equalStartAndEndOverlapUsesAscendingClusterTrimOrder() throws {
        let window = ReconstructionWindow(
            offsetSeconds: 0,
            speakerBits: [UInt8](repeating: 3, count: Community1Profile.segmentationFrames),
            assignments: [0, 1, -2]
        )
        for _ in 0..<5 {
            let result = try Community1Reconstruction.reconstruct(
                windows: [window],
                clusterCount: 2,
                frameDuration: 10.0 / Double(Community1Profile.segmentationFrames)
            )
            #expect(result.segments.count == 1)
            #expect(result.segments[0].speakerID == "S1")
            #expect(result.segments[0].startSeconds.bitPattern == Float(0).bitPattern)
            #expect(result.segments[0].endSeconds.bitPattern == Float(10).bitPattern)
        }
    }

    @Test func globalAdjacencyPreventsPerSpeakerGapMerge() throws {
        let bits: [UInt8] = (0..<200).map { frame in
            let clusterZero = (0..<60).contains(frame) || (65..<125).contains(frame)
            let clusterOne = (20..<62).contains(frame)
            return (clusterZero ? 1 : 0) | (clusterOne ? 2 : 0)
        }
        let result = try Community1Reconstruction.reconstruct(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: bits, assignments: [0, 1, -2])],
            clusterCount: 2,
            frameDuration: 0.01
        )
        #expect(result.segments.map(\.speakerID) == ["S1", "S1"])
        #expect(result.segments[0].startSeconds.bitPattern == Float(0).bitPattern)
        #expect(result.segments[0].endSeconds.bitPattern == Float(60 * 0.01).bitPattern)
        #expect(result.segments[1].startSeconds.bitPattern == Float(65 * 0.01).bitPattern)
        #expect(result.segments[1].endSeconds.bitPattern == Float(125 * 0.01).bitPattern)
    }

    @Test func zeroClustersClampToOneAndPreserveZeroVoteSpeaker() throws {
        let result = try Community1Reconstruction.reconstruct(
            windows: [ReconstructionWindow(
                offsetSeconds: 0,
                speakerBits: [UInt8](repeating: 7, count: Community1Profile.segmentationFrames),
                assignments: [-2, -2, -2]
            )],
            clusterCount: 0,
            frameDuration: 10.0 / Double(Community1Profile.segmentationFrames)
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].speakerID == "S1")
        #expect(result.segments[0].quality == 0)
    }

    @Test func uncoveredGapAndNonzeroOffsetsMatchDenseReference() throws {
        let bits = [UInt8](repeating: 1, count: Community1Profile.segmentationFrames)
        let windows = [
            ReconstructionWindow(offsetSeconds: 1, speakerBits: bits, assignments: [0, -2, -2]),
            ReconstructionWindow(offsetSeconds: 20, speakerBits: bits, assignments: [0, -2, -2]),
        ]
        let expected = denseReconstructionReference(windows: windows, clusterCount: 1, frameDuration: 0.01)
        let actual = try Community1Reconstruction.reconstruct(windows: windows, clusterCount: 1, frameDuration: 0.01)
        expectSegmentParity(actual.segments, expected, context: "uncovered gap and nonzero offsets")
        #expect(actual.segments.map(\.speakerID) == ["S1", "S1"])
        #expect(actual.segments[0].startSeconds.bitPattern == Float(1).bitPattern)
        #expect(actual.segments[0].endSeconds.bitPattern == Float(6.89).bitPattern)
        #expect(actual.segments[1].startSeconds.bitPattern == Float(20).bitPattern)
        #expect(actual.segments[1].endSeconds.bitPattern == Float(25.89).bitPattern)
    }

    @Test func halfFrameOffsetMapsEachLocalFrameFromItsSourceTime() throws {
        let bits = (0..<200).map { frame -> UInt8 in
            (3..<50).contains(frame) || (70..<130).contains(frame) ? 1 : 0
        }
        // Local frames 2 and 3 both map to global frame 3: the former is inactive, the
        // latter active, so their mean expected count rounds 0.5 to zero. Mapping the
        // offset once and adding local indices would put active frame 3 at global frame 4.
        let windows = [ReconstructionWindow(offsetSeconds: 0.005, speakerBits: bits, assignments: [0, -2, -2])]
        let expected = denseReconstructionReference(windows: windows, clusterCount: 1, frameDuration: 0.01)
        let actual = try Community1Reconstruction.reconstruct(windows: windows, clusterCount: 1, frameDuration: 0.01)
        expectSegmentParity(actual.segments, expected, context: "half-frame source mapping")
        #expect(actual.segments.map(\.speakerID) == ["S1", "S1"])
        #expect(actual.segments[0].startSeconds.bitPattern == Float(0.05).bitPattern)
        #expect(actual.segments[0].endSeconds.bitPattern == Float(0.51).bitPattern)
        #expect(actual.segments[1].startSeconds.bitPattern == Float(0.71).bitPattern)
        #expect(actual.segments[1].endSeconds.bitPattern == Float(1.31).bitPattern)
    }

    @Test func emptyInputAndMalformedInputsFailFast() throws {
        let empty = try Community1Reconstruction.reconstruct(windows: [], clusterCount: 0, frameDuration: 0.01)
        #expect(empty.segments.isEmpty)
        #expect(empty.peakBufferedFrames == 0)
        #expect(empty.peakBufferedVoteEntries == 0)

        let oneFrame = ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [0, -2, -2])
        expectInvalidInput(windows: [], clusterCount: -1, frameDuration: 0.01)
        for invalidDuration in [0.0, -0.01, Double.nan, Double.infinity, -Double.infinity] {
            expectInvalidInput(windows: [], clusterCount: 1, frameDuration: invalidDuration)
        }
        expectInvalidInput(windows: [oneFrame], clusterCount: 1, frameDuration: 0.01, replacingOffset: -0.01)
        expectInvalidInput(windows: [oneFrame], clusterCount: 1, frameDuration: 0.01, replacingOffset: .nan)
        expectInvalidInput(windows: [oneFrame], clusterCount: 1, frameDuration: 0.01, replacingOffset: .infinity)
        expectInvalidInput(
            windows: [
                ReconstructionWindow(offsetSeconds: 1, speakerBits: [0], assignments: [0, -2, -2]),
                ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [0, -2, -2]),
            ],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: [], assignments: [0, -2, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [
                ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [0, -2, -2]),
                ReconstructionWindow(offsetSeconds: 1, speakerBits: [0, 0], assignments: [0, -2, -2]),
            ],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: [8], assignments: [0, -2, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [0, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [-1, -2, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 0, speakerBits: [0], assignments: [1, -2, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
        expectInvalidInput(
            windows: [ReconstructionWindow(offsetSeconds: 1e100, speakerBits: [0], assignments: [0, -2, -2])],
            clusterCount: 1,
            frameDuration: 0.01
        )
    }
}

private struct DenseReferenceRun {
    var start: Double
    var end: Double
    var scoreSum: Double
    var frameCount: Int
}

/// Independent full-duration oracle for small-K tests; intentionally not rolling.
private func denseReconstructionReference(
    windows: [ReconstructionWindow],
    clusterCount: Int,
    frameDuration: Double
) -> [ReconstructedSegment] {
    let effectiveClusterCount = max(clusterCount, 1)
    let maximumEnd = windows.map {
        $0.offsetSeconds + Double($0.speakerBits.count) * frameDuration
    }.max() ?? 0
    let totalFrames = max(1, Int(ceil(maximumEnd / frameDuration)))
    var activationSums = Array(
        repeating: [Double](repeating: 0, count: effectiveClusterCount),
        count: totalFrames
    )
    var positiveCounts = Array(
        repeating: [Double](repeating: 0, count: effectiveClusterCount),
        count: totalFrames
    )
    var expectedCountSums = [Double](repeating: 0, count: totalFrames)
    var coveringCounts = [Double](repeating: 0, count: totalFrames)

    for window in windows {
        for localFrame in window.speakerBits.indices {
            let sourceFrameStart = window.offsetSeconds + Double(localFrame) * frameDuration
            let mapped = Int((sourceFrameStart / frameDuration).rounded())
            let globalFrame = min(max(mapped, 0), totalFrames - 1)
            let bits = window.speakerBits[localFrame]
            expectedCountSums[globalFrame] += Double(bits.nonzeroBitCount)
            coveringCounts[globalFrame] += 1

            var frameActivations = [Double](repeating: 0, count: effectiveClusterCount)
            for localSpeaker in 0..<3 where bits & (UInt8(1) << UInt8(localSpeaker)) != 0 {
                let cluster = window.assignments[localSpeaker]
                if cluster >= 0 {
                    frameActivations[cluster] = max(frameActivations[cluster], 1)
                }
            }
            for cluster in 0..<effectiveClusterCount where frameActivations[cluster] > 0 {
                activationSums[globalFrame][cluster] += frameActivations[cluster]
                positiveCounts[globalFrame][cluster] += 1
            }
        }
    }

    var activeRuns: [Int: DenseReferenceRun] = [:]
    var raw: [ReconstructedSegment] = []
    for frame in 0..<totalFrames {
        var required = 0
        if coveringCounts[frame] > 0 {
            let mean = expectedCountSums[frame] / coveringCounts[frame]
            required = min(
                max(Int(mean.rounded(.toNearestOrEven)), 0),
                min(effectiveClusterCount, Community1Profile.localSpeakers)
            )
        }

        let ranked = (0..<effectiveClusterCount).sorted { lhs, rhs in
            if activationSums[frame][lhs] != activationSums[frame][rhs] {
                return activationSums[frame][lhs] > activationSums[frame][rhs]
            }
            return lhs < rhs
        }
        let selected = Array(ranked.prefix(required)).sorted()
        let selectedSet = Set(selected)
        let frameStart = Double(frame) * frameDuration
        let frameEnd = frameStart + frameDuration

        for cluster in activeRuns.keys.sorted() where !selectedSet.contains(cluster) {
            if let run = activeRuns.removeValue(forKey: cluster), frameStart > run.start {
                let average = run.scoreSum / Double(run.frameCount)
                raw.append(ReconstructedSegment(
                    clusterIndex: cluster,
                    startSeconds: Float(run.start),
                    endSeconds: Float(frameStart),
                    quality: Float(min(max(average, 0), 1))
                ))
            }
        }
        for cluster in selected {
            let score = positiveCounts[frame][cluster] > 0
                ? activationSums[frame][cluster] / positiveCounts[frame][cluster]
                : 0
            if var run = activeRuns[cluster] {
                run.end = frameEnd
                run.scoreSum += score
                run.frameCount += 1
                activeRuns[cluster] = run
            } else {
                activeRuns[cluster] = DenseReferenceRun(
                    start: frameStart,
                    end: frameEnd,
                    scoreSum: score,
                    frameCount: 1
                )
            }
        }
    }
    for cluster in activeRuns.keys.sorted() {
        guard let run = activeRuns[cluster], run.end > run.start else { continue }
        let average = run.scoreSum / Double(run.frameCount)
        raw.append(ReconstructedSegment(
            clusterIndex: cluster,
            startSeconds: Float(run.start),
            endSeconds: Float(run.end),
            quality: Float(min(max(average, 0), 1))
        ))
    }

    let orderedForMerge = stableStartOrder(raw)
    var merged: [ReconstructedSegment] = []
    if let first = orderedForMerge.first {
        var current = first
        let gapThreshold = max(Community1Profile.minimumGapSeconds, Community1Profile.minimumOffSeconds)
        for segment in orderedForMerge.dropFirst() {
            let gap = Double(segment.startSeconds) - Double(current.endSeconds)
            if segment.clusterIndex == current.clusterIndex && gap <= gapThreshold {
                let lhsDuration = Double(current.endSeconds - current.startSeconds)
                let rhsDuration = Double(segment.endSeconds - segment.startSeconds)
                let totalDuration = lhsDuration + rhsDuration
                let quality: Float
                if totalDuration > 0 {
                    let weighted = Double(current.quality) * lhsDuration + Double(segment.quality) * rhsDuration
                    quality = Float(min(max(weighted / totalDuration, 0), 1))
                } else {
                    quality = min(max((current.quality + segment.quality) / 2, 0), 1)
                }
                current = ReconstructedSegment(
                    clusterIndex: current.clusterIndex,
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, segment.endSeconds),
                    quality: quality
                )
            } else {
                merged.append(current)
                current = segment
            }
        }
        merged.append(current)
    }

    var sanitized = stableStartOrder(merged)
    let minimumDuration = max(
        Float(Community1Profile.minimumSegmentSeconds),
        Float(Community1Profile.minimumOnSeconds)
    )
    sanitized = sanitized.filter { $0.endSeconds - $0.startSeconds >= minimumDuration }
    let exclusiveMinimum = Float(Community1Profile.minimumSegmentSeconds)
    var retained: [ReconstructedSegment] = []
    for segment in sanitized {
        var adjustedStart = segment.startSeconds
        if let previous = retained.last, adjustedStart < previous.endSeconds {
            adjustedStart = previous.endSeconds
        }
        guard adjustedStart < segment.endSeconds else { continue }
        let retainedDuration = segment.endSeconds - adjustedStart
        guard retainedDuration >= exclusiveMinimum else { continue }
        let originalDuration = segment.endSeconds - segment.startSeconds
        let qualityScale = originalDuration > 0 ? retainedDuration / originalDuration : 1
        retained.append(ReconstructedSegment(
            clusterIndex: segment.clusterIndex,
            startSeconds: adjustedStart,
            endSeconds: segment.endSeconds,
            quality: min(max(segment.quality * qualityScale, 0), 1)
        ))
    }
    return retained
}

private func stableStartOrder(_ segments: [ReconstructedSegment]) -> [ReconstructedSegment] {
    segments.enumerated().sorted { lhs, rhs in
        if lhs.element.startSeconds == rhs.element.startSeconds {
            return lhs.offset < rhs.offset
        }
        return lhs.element.startSeconds < rhs.element.startSeconds
    }.map(\.element)
}

private func expectSegmentParity(
    _ actual: [ReconstructedSegment],
    _ expected: [ReconstructedSegment],
    context: String
) {
    #expect(actual.count == expected.count, Comment(rawValue: context))
    guard actual.count == expected.count else { return }
    for index in actual.indices {
        #expect(actual[index].speakerID == expected[index].speakerID, Comment(rawValue: "\(context), segment \(index)"))
        #expect(actual[index].startSeconds.bitPattern == expected[index].startSeconds.bitPattern, Comment(rawValue: "\(context), segment \(index) start"))
        #expect(actual[index].endSeconds.bitPattern == expected[index].endSeconds.bitPattern, Comment(rawValue: "\(context), segment \(index) end"))
        #expect(
            actual[index].quality.bitPattern == expected[index].quality.bitPattern,
            Comment(rawValue: "\(context), segment \(index) quality bits")
        )
    }
}

private func expectInvalidInput(
    windows: [ReconstructionWindow],
    clusterCount: Int,
    frameDuration: Double
) {
    expectInvalidInput(
        windows: windows,
        clusterCount: clusterCount,
        frameDuration: frameDuration,
        replacingOffset: nil
    )
}

private func expectInvalidInput(
    windows: [ReconstructionWindow],
    clusterCount: Int,
    frameDuration: Double,
    replacingOffset: Double?
) {
    let inputWindows: [ReconstructionWindow]
    if let replacingOffset, windows.count == 1 {
        inputWindows = [ReconstructionWindow(
            offsetSeconds: replacingOffset,
            speakerBits: windows[0].speakerBits,
            assignments: windows[0].assignments
        )]
    } else {
        inputWindows = windows
    }
    #expect(throws: ReconstructionError.self) {
        try Community1Reconstruction.reconstruct(
            windows: inputWindows,
            clusterCount: clusterCount,
            frameDuration: frameDuration
        )
    }
}
