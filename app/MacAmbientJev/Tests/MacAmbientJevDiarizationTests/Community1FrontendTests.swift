import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1FrontendTests {
    @Test func decodesEveryPowersetClassAndUsesFirstClassOnTies() throws {
        let frameCount = Community1Profile.segmentationFrames
        let classCount = Community1Profile.powersetClasses
        var cyclingLogits = [Float](repeating: -10, count: frameCount * classCount)
        for frame in 0..<frameCount {
            cyclingLogits[frame * classCount + frame % classCount] = 1
        }
        let cycling = Community1Frontend.decode(try PowersetScores(logProbabilities: cyclingLogits))
        #expect(cycling.speakerBits.count == 589)
        for frame in 0..<frameCount {
            #expect(cycling.speakerBits[frame] == Community1Profile.powersetSpeakerBits[frame % classCount])
        }

        let equalLogits = [Float](repeating: 0, count: frameCount * classCount)
        let equal = Community1Frontend.decode(try PowersetScores(logProbabilities: equalLogits))
        #expect(equal.speakerBits == [UInt8](repeating: 0, count: frameCount))

        for lowerClass in 0..<classCount {
            for upperClass in (lowerClass + 1)..<classCount {
                var tiedLogits = [Float](repeating: -5, count: frameCount * classCount)
                for frame in 0..<frameCount {
                    let row = frame * classCount
                    tiedLogits[row + lowerClass] = -1
                    tiedLogits[row + upperClass] = -1
                }
                let tied = Community1Frontend.decode(try PowersetScores(logProbabilities: tiedLogits))
                #expect(tied.speakerBits == [UInt8](
                    repeating: Community1Profile.powersetSpeakerBits[lowerClass],
                    count: frameCount
                ))
            }
        }

        let minimumLogits = [Float](
            repeating: -Float.greatestFiniteMagnitude,
            count: frameCount * classCount
        )
        let minimum = Community1Frontend.decode(try PowersetScores(logProbabilities: minimumLogits))
        #expect(minimum.speakerBits == [UInt8](repeating: 0, count: frameCount))
    }

    @Test func rejectsMalformedPowersetScoresActivityMasksAndSpeakerWeights() throws {
        for count in [0, 4_122, 4_124] {
            let error = try #require(throws: FrontendError.self) {
                try PowersetScores(logProbabilities: [Float](repeating: 0, count: count))
            }
            #expect(error.description.contains("exactly 4123 values; got \(count)"))
        }

        for (index, invalidValue) in [
            (0, Float.nan),
            (0, Float.infinity),
            (0, -Float.infinity),
            (4_122, Float.nan),
            (4_122, Float.infinity),
            (4_122, -Float.infinity),
        ] {
            var values = [Float](repeating: 0, count: 4_123)
            values[index] = invalidValue
            let error = try #require(throws: FrontendError.self) {
                try PowersetScores(logProbabilities: values)
            }
            #expect(error.description.contains("logProbabilities[\(index)] must be finite"))
        }

        for count in [588, 590] {
            #expect(throws: FrontendError.self) {
                try ActivityMask(values: [Float](repeating: 0, count: count))
            }
            let weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: count
            )
            #expect(throws: FrontendError.self) {
                try Community1Frontend.selectMasks(speakerWeights: weights)
            }
        }

        for rowCount in [2, 4] {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: 589
            )
            weights[17] = [Float](repeating: 0, count: rowCount)
            let error = try #require(throws: FrontendError.self) {
                try Community1Frontend.selectMasks(speakerWeights: weights)
            }
            #expect(error.description.contains("speakerWeights[17] must contain exactly 3 speakers; got \(rowCount)"))
        }

        for (_, invalidValue) in [
            (0, Float.nan),
            (0, Float.infinity),
            (0, -Float.infinity),
            (0, -0.01),
            (0, 1.01),
        ] {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: 589
            )
            weights[0][1] = invalidValue
            let error = try #require(throws: FrontendError.self) {
                try Community1Frontend.selectMasks(speakerWeights: weights)
            }
            let expectedPart = invalidValue.isFinite
                ? "speakerWeights[0][1] must be in 0...1"
                : "speakerWeights[0][1] must be finite"
            #expect(error.description.contains(expectedPart))
        }

        for (index, invalidValue) in [
            (0, Float.nan),
            (0, Float.infinity),
            (0, -Float.infinity),
            (0, -0.01),
            (0, 1.01),
        ] {
            var values = [Float](repeating: 0, count: 589)
            values[index] = invalidValue
            let error = try #require(throws: FrontendError.self) {
                try ActivityMask(values: values)
            }
            let expectedPart = invalidValue.isFinite
                ? "activity mask[\(index)] must be in 0...1"
                : "activity mask[\(index)] must be finite"
            #expect(error.description.contains(expectedPart))
        }
    }

    @Test func selectsZeroThroughThreeDisjointSpeakerRunsInAscendingOrder() throws {
        let runs = [(0, 118), (180, 298), (400, 518)]
        for activeSpeakerCount in 0...3 {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: Community1Profile.segmentationFrames
            )
            for speaker in 0..<activeSpeakerCount {
                for frame in runs[speaker].0..<runs[speaker].1 {
                    weights[frame][speaker] = 1
                }
            }

            let selected = try Community1Frontend.selectMasks(speakerWeights: weights)
            #expect(selected.count == activeSpeakerCount)
            guard selected.count == activeSpeakerCount else { continue }
            #expect(selected.map(\.speakerIndex) == Array(0..<activeSpeakerCount))
            for speaker in 0..<activeSpeakerCount {
                #expect(selected[speaker].startFrame == runs[speaker].0)
                #expect(selected[speaker].endFrame == runs[speaker].1 - 1)
                #expect(selected[speaker].mask.values.count == 589)
                #expect(selected[speaker].mask.values[runs[speaker].0] == 1)
                #expect(selected[speaker].mask.values[runs[speaker].1 - 1] == 1)
            }
        }

        var allOverlap = [[Float]](
            repeating: [Float](repeating: 0, count: 3),
            count: Community1Profile.segmentationFrames
        )
        for frame in 0..<118 {
            allOverlap[frame] = [1, 1, 1]
        }
        #expect(try Community1Frontend.selectMasks(speakerWeights: allOverlap).isEmpty)
    }

    @Test func overlapThresholdUsesStrictComparisonAndZerosOnlyOverlappingFrames() throws {
        let threshold = Community1Profile.overlapThreshold
        for secondSpeakerWeight in [threshold.nextDown, threshold, threshold.nextUp] {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: Community1Profile.segmentationFrames
            )
            for frame in 0..<200 {
                weights[frame][0] = 1
            }
            weights[50][1] = secondSpeakerWeight

            let selected = try Community1Frontend.selectMasks(speakerWeights: weights)
            #expect(selected.map(\.speakerIndex) == [0])
            let firstMask = try #require(selected.first)
            var expected = [Float](repeating: 0, count: 589)
            for frame in 0..<200 {
                expected[frame] = 1
            }
            if secondSpeakerWeight == threshold.nextUp {
                expected[50] = 0
            }
            #expect(firstMask.mask.values == expected)
            #expect(firstMask.startFrame == 0)
            #expect(firstMask.endFrame == 199)
        }
    }

    @Test func fractionalCleanMaskThresholdUsesFloatWeightSum() throws {
        let threshold = Float(Community1Profile.segmentationFrames)
            * Community1Profile.minimumActiveRatio
        let exactFraction = threshold - 117
        for (fraction, expectedCount) in [
            (exactFraction - 0.01, 0),
            (exactFraction, 1),
            (exactFraction + 0.01, 1),
        ] {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: Community1Profile.segmentationFrames
            )
            for frame in 0..<117 {
                weights[frame][0] = 1
            }
            weights[117][0] = fraction
            let selected = try Community1Frontend.selectMasks(speakerWeights: weights)
            #expect(selected.count == expectedCount)
        }
    }

    @Test func cleanMaskGateRejectsSeventeenEighteenAnd117FramesButAccepts118() throws {
        for frameCount in [17, 18, 117, 118] {
            var weights = [[Float]](
                repeating: [Float](repeating: 0, count: 3),
                count: Community1Profile.segmentationFrames
            )
            for frame in 0..<frameCount {
                weights[frame][0] = 1
            }
            let selected = try Community1Frontend.selectMasks(speakerWeights: weights)
            #expect(selected.count == (frameCount == 118 ? 1 : 0))
        }
    }

    @Test func decoderActivitySelectorMatchesExpandedBinarySpeakerWeights() throws {
        let frameCount = Community1Profile.segmentationFrames
        let classCount = Community1Profile.powersetClasses
        var logits = [Float](repeating: -10, count: frameCount * classCount)
        for frame in 0..<frameCount {
            logits[frame * classCount + frame % classCount] = 0
        }
        let activity = Community1Frontend.decode(try PowersetScores(logProbabilities: logits))
        var expanded = [[Float]](
            repeating: [Float](repeating: 0, count: Community1Profile.localSpeakers),
            count: frameCount
        )
        for frame in 0..<frameCount {
            for speaker in 0..<Community1Profile.localSpeakers
                where activity.speakerBits[frame] & (UInt8(1) << UInt8(speaker)) != 0 {
                expanded[frame][speaker] = 1
            }
        }

        let fromActivity = try Community1Frontend.selectMasks(activity)
        let fromWeights = try Community1Frontend.selectMasks(speakerWeights: expanded)
        #expect(fromActivity.count == fromWeights.count)
        guard fromActivity.count == fromWeights.count else { return }
        for index in fromActivity.indices {
            #expect(fromActivity[index].speakerIndex == fromWeights[index].speakerIndex)
            #expect(fromActivity[index].mask.values == fromWeights[index].mask.values)
            #expect(fromActivity[index].startFrame == fromWeights[index].startFrame)
            #expect(fromActivity[index].endFrame == fromWeights[index].endFrame)
        }
    }

    @Test func poolingMaskUsesAlignCornersSamplingAndIntegerScatterPositions() throws {
        let frameCount = Community1Profile.segmentationFrames
        let poolingFrames = Community1Profile.poolingFrames
        let scatterIndices = (0..<poolingFrames).map {
            $0 * frameCount / poolingFrames
        }
        #expect(scatterIndices.count == 125)
        #expect(Set(scatterIndices).count == poolingFrames)
        #expect(scatterIndices == scatterIndices.sorted())
        #expect(scatterIndices.first == 0)
        #expect(scatterIndices.last == 584)
        #expect(scatterIndices.allSatisfy { (0..<frameCount).contains($0) })

        let zeroMask = try ActivityMask(values: [Float](repeating: 0, count: frameCount))
        #expect(Community1Frontend.poolingMask(zeroMask).values
            == [Float](repeating: 0, count: frameCount))

        let oneValues = [Float](repeating: 1, count: frameCount)
        let oneMask = try ActivityMask(values: oneValues)
        let pooledOnes = Community1Frontend.poolingMask(oneMask)
        var expectedOnes = [Float](repeating: 0, count: frameCount)
        for index in scatterIndices {
            expectedOnes[index] = 1
        }
        #expect(pooledOnes.values == expectedOnes)
        #expect(pooledOnes.values != oneMask.values)

        let ramp = try ActivityMask(values: (0..<frameCount).map { Float($0) / 588 })
        let pooledRamp = Community1Frontend.poolingMask(ramp)
        for pooledIndex in 0..<poolingFrames {
            let scatterIndex = scatterIndices[pooledIndex]
            #expect(abs(pooledRamp.values[scatterIndex] - Float(pooledIndex) / 124) < 1e-7)
        }

        var startImpulse = [Float](repeating: 0, count: frameCount)
        startImpulse[0] = 1
        var endImpulse = [Float](repeating: 0, count: frameCount)
        endImpulse[frameCount - 1] = 1
        var middleImpulse = [Float](repeating: 0, count: frameCount)
        middleImpulse[frameCount / 2] = 1
        let alternating = (0..<frameCount).map { $0.isMultiple(of: 2) ? Float.zero : Float(1) }
        let scattered = (0..<frameCount).map { Float(($0 * 37) % 101) / 100 }
        for inputValues in [startImpulse, endImpulse, middleImpulse, alternating, scattered] {
            let mask = try ActivityMask(values: inputValues)
            let actual = Community1Frontend.poolingMask(mask).values
            var expected = [Float](repeating: 0, count: frameCount)
            for pooledIndex in 0..<poolingFrames {
                let coordinate = Double(pooledIndex) * 588 / 124
                let leftIndex = Int(coordinate.rounded(.down))
                let rightIndex = min(leftIndex + 1, frameCount - 1)
                let rightWeight = Float(coordinate - Double(leftIndex))
                let leftWeight = 1 - rightWeight
                let sampledValue = inputValues[leftIndex] * leftWeight
                    + inputValues[rightIndex] * rightWeight
                expected[pooledIndex * frameCount / poolingFrames] = sampledValue
            }
            #expect(actual == expected)
            #expect(actual.enumerated().allSatisfy { index, value in
                scatterIndices.contains(index) || value == 0
            })
        }
    }

    @Test func windowPlanSchedulesStartsBeforeEOFAndPadsActualReads() throws {
        let sampleCounts: [Int64] = [
            0, 1, 31_999, 32_000, 32_001, 159_999, 160_000, 160_001, 192_000, 192_001,
        ]
        for sampleCount in sampleCounts {
            let plan = try Community1WindowPlan(sampleCount: sampleCount)
            let expectedCount = sampleCount == 0 ? 0 : Int((sampleCount - 1) / 32_000 + 1)
            #expect(plan.count == expectedCount)
            for index in 0..<plan.count {
                let expectedStart = Int64(index) * 32_000
                #expect(try plan.startFrame(at: index) == expectedStart)
                #expect(expectedStart < sampleCount)

                var requestedRange: Range<Int64>?
                let window = try plan.window(at: index) { range in
                    requestedRange = range
                    return range.map { Float($0 % 31) / 31 }
                }
                let expectedAvailable = Int(min(160_000, sampleCount - expectedStart))
                let expectedRange = expectedStart..<(expectedStart + Int64(expectedAvailable))
                #expect(requestedRange == expectedRange)
                #expect(window.startFrame == expectedStart)
                #expect(window.availableSampleCount == expectedAvailable)
                #expect(window.samples.count == 160_000)
                #expect(window.samples.prefix(expectedAvailable).enumerated().allSatisfy {
                    localIndex, sample in
                    sample == Float((expectedStart + Int64(localIndex)) % 31) / 31
                })
                #expect(window.samples[expectedAvailable...].allSatisfy { $0 == 0 })
            }

            if sampleCount > 0 {
                let lastStart = Int64(expectedCount - 1) * 32_000
                let lastWindowEnd = lastStart + 160_000
                #expect(DiarizationFinalWindowPadding.clampedEndFrame(
                    lastWindowEnd,
                    sampleCount: sampleCount,
                    windowSamples: 160_000,
                    stepSamples: 32_000
                ) == sampleCount)
                #expect(DiarizationFinalWindowPadding.clampedEndFrame(
                    lastWindowEnd + 1,
                    sampleCount: sampleCount,
                    windowSamples: 160_000,
                    stepSamples: 32_000
                ) == nil)
            }
        }

        let emptyPlan = try Community1WindowPlan(sampleCount: 0)
        #expect(throws: FrontendError.self) { try emptyPlan.startFrame(at: 0) }
        let oneSamplePlan = try Community1WindowPlan(sampleCount: 1)
        #expect(throws: FrontendError.self) { try oneSamplePlan.startFrame(at: -1) }
        #expect(throws: FrontendError.self) { try oneSamplePlan.startFrame(at: oneSamplePlan.count) }
        #expect(throws: FrontendError.self) { try oneSamplePlan.window(at: oneSamplePlan.count) { _ in [] } }
        #expect(throws: FrontendError.self) { try Community1WindowPlan(sampleCount: -1) }
    }

    @Test func hugeWindowPlanUsesConstantMemoryAndKeepsFinalRangeInBounds() throws {
        let plan = try Community1WindowPlan(sampleCount: Int64.max)
        #expect(plan.count > 0)
        let lastIndex = plan.count - 1
        let lastStart = try plan.startFrame(at: lastIndex)
        #expect(lastStart < Int64.max)
        #expect(lastStart % 32_000 == 0)
        #expect(Int64.max - lastStart > 0)
        #expect(Int64.max - lastStart <= 32_000)
        var readRange: Range<Int64>?
        let finalWindow = try plan.window(at: lastIndex) { range in
            readRange = range
            #expect(range.lowerBound == lastStart)
            #expect(range.upperBound == Int64.max)
            #expect(range.count == Int(Int64.max - lastStart))
            return [Float](repeating: 0, count: range.count)
        }
        #expect(readRange?.lowerBound == lastStart)
        #expect(readRange?.upperBound == Int64.max)
        #expect(finalWindow.startFrame == lastStart)
        #expect(finalWindow.availableSampleCount == Int(Int64.max - lastStart))
        #expect(finalWindow.samples.count == 160_000)
        #expect(finalWindow.samples[finalWindow.availableSampleCount...].allSatisfy { $0 == 0 })
    }

    @Test func windowRejectsInvalidReaderCountsAndNonfiniteSamplesAndPropagatesErrors() throws {
        let plan = try Community1WindowPlan(sampleCount: 1)
        let shortReaderError = try #require(throws: FrontendError.self) {
            try plan.window(at: 0) { _ in [] }
        }
        #expect(shortReaderError.description.contains("reader returned 0 samples; expected 1"))
        let longReaderError = try #require(throws: FrontendError.self) {
            try plan.window(at: 0) { _ in [0, 1] }
        }
        #expect(longReaderError.description.contains("reader returned 2 samples; expected 1"))
        for invalidSample in [Float.nan, Float.infinity, -Float.infinity] {
            let error = try #require(throws: FrontendError.self) {
                try plan.window(at: 0) { _ in [invalidSample] }
            }
            #expect(error.description.contains("window 0 sample[0] must be finite"))
        }
        #expect(throws: WindowReaderFailure.self) {
            try plan.window(at: 0) { _ in throw WindowReaderFailure.unavailable }
        }
    }

    @Test func windowChecksCancellationBeforeCallingReader() async throws {
        let plan = try Community1WindowPlan(sampleCount: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) {
                try plan.window(at: 0) { _ in
                    Issue.record("cancelled window must not invoke its reader")
                    return [0]
                }
            }
        }
        await task.value
    }
}

private enum WindowReaderFailure: Error {
    case unavailable
}
