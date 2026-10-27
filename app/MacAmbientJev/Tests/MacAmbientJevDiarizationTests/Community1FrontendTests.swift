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
