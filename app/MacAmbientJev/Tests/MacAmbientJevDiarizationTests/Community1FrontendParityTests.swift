import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1FrontendParityTests {
    @Test func decodeMatchesFluidAudio() throws {
        let fixture = try loadFrontendFixture()
        #expect(fixture.decodeCases.count == 1)

        for item in fixture.decodeCases {
            try #require(item.logits.dtype == "float32", "\(item.name): logits must be float32")
            try #require(item.logits.shape == [589, 7], "\(item.name): logits must have shape [589, 7]")
            try #require(item.expectedSpeakerBits.count == 589, "\(item.name): expected speaker bits must have 589 frames")

            let scores = try PowersetScores(logProbabilities: item.logits.float32())
            let actual = Community1Frontend.decode(scores).speakerBits.map(Int.init)
            #expect(actual == item.expectedSpeakerBits)
        }
    }

    @Test func selectedMasksAndFrameBoundsMatchFluidAudioExtraction() throws {
        let fixture = try loadFrontendFixture()
        #expect(fixture.maskCases.count == 16)

        for item in fixture.maskCases {
            try #require(item.speakerWeights.dtype == "float32", "\(item.name): speaker weights must be float32")
            try #require(item.speakerWeights.shape == [589, 3], "\(item.name): speaker weights must have shape [589, 3]")
            let flattenedWeights = try item.speakerWeights.float32()
            let speakerWeights = (0..<589).map { frame in
                Array(flattenedWeights[(frame * 3)..<(frame * 3 + 3)])
            }
            let selected = try Community1Frontend.selectMasks(speakerWeights: speakerWeights)

            try #require(
                selected.count == item.expectedSlots.count,
                "\(item.name): selected mask count must match expected slots"
            )
            try #require(
                item.expectedStartFrames.count == item.expectedSlots.count
                    && item.expectedEndFrames.count == item.expectedSlots.count,
                "\(item.name): expected bounds must match expected slots"
            )
            let expectedMaskShape = [item.expectedSlots.count, 589]
            try #require(
                item.expectedMasks.dtype == "float32" && item.expectedMasks.shape == expectedMaskShape,
                "\(item.name): expected masks must be float32 with shape \(expectedMaskShape)"
            )
            try #require(
                item.expectedResampledMasks.dtype == "float32"
                    && item.expectedResampledMasks.shape == expectedMaskShape,
                "\(item.name): identity-resampled masks must be float32 with shape \(expectedMaskShape)"
            )

            #expect(selected.map(\.speakerIndex) == item.expectedSlots)
            #expect(selected.map(\.startFrame) == item.expectedStartFrames)
            #expect(selected.map(\.endFrame) == item.expectedEndFrames)

            let chosenMasks = selected.flatMap { $0.mask.values }
            let chosenBits = chosenMasks.map(\.bitPattern)
            #expect(chosenBits == (try item.expectedMasks.float32()).map(\.bitPattern))
            #expect(chosenBits == (try item.expectedResampledMasks.float32()).map(\.bitPattern))
        }
    }

    @Test func windowPlanMatchesFluidAudioSchedulingAndPadding() throws {
        let fixture = try loadFrontendFixture()
        #expect(fixture.windowCases.count == 8)

        for item in fixture.windowCases {
            let sampleCount = try #require(Int64(exactly: item.sampleCount), "sample count must fit Int64")
            let plan = try Community1WindowPlan(sampleCount: sampleCount)
            try #require(plan.count == item.expectedStarts.count, "window count must match expected starts")
            try #require(
                item.expectedAvailable.count == item.expectedStarts.count
                    && item.expectedPadding.count == item.expectedStarts.count,
                "window availability and padding must match expected starts"
            )
            #expect(zip(item.expectedAvailable, item.expectedPadding).allSatisfy { pair in
                pair.0 + pair.1 == Community1Profile.windowSamples
            })

            for index in item.expectedStarts.indices {
                let expectedStart = Int64(item.expectedStarts[index])
                let expectedAvailable = item.expectedAvailable[index]
                #expect(expectedStart < sampleCount)
                #expect(try plan.startFrame(at: index) == expectedStart)

                var requestedStart: Int64?
                var requestedCount: Int?
                var readSamples: [Float] = []
                let window = try plan.window(at: index) { range in
                    requestedStart = range.lowerBound
                    requestedCount = range.count
                    #expect(range.lowerBound == expectedStart)
                    #expect(range.count == expectedAvailable)
                    readSamples = range.map { Float(($0 % 17) + 1) / 32 }
                    return readSamples
                }

                #expect(requestedStart == expectedStart)
                #expect(requestedCount == expectedAvailable)
                #expect(window.startFrame == expectedStart)
                #expect(window.startFrame < sampleCount)
                #expect(window.availableSampleCount == expectedAvailable)
                try #require(
                    window.samples.count == Community1Profile.windowSamples,
                    "window output must contain exactly 160000 samples"
                )
                try #require(
                    expectedAvailable >= 0 && expectedAvailable <= window.samples.count,
                    "available sample count must be within the padded window"
                )
                #expect(Array(window.samples.prefix(expectedAvailable)) == readSamples)
                #expect(window.samples[expectedAvailable...].allSatisfy { $0 == 0 })
            }
        }
    }

    @Test func tailPoolingMatchesContractAndDoesNotUseHalfPixelResampling() throws {
        let fixture = try loadFrontendFixture()
        #expect(fixture.interpolationCases.count == 6)

        let frameCount = 589
        let poolingFrames = 125
        let scatterIndices = (0..<poolingFrames).map { $0 * frameCount / poolingFrames }
        #expect(scatterIndices.count == poolingFrames)
        #expect(Set(scatterIndices).count == poolingFrames)
        #expect(zip(scatterIndices, scatterIndices.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
        #expect(scatterIndices.allSatisfy { (0..<frameCount).contains($0) })

        for item in fixture.interpolationCases {
            try #require(item.input.dtype == "float32" && item.input.shape == [frameCount], "\(item.name): input must have 589 float32 frames")
            try #require(item.expectedIdentity.dtype == "float32" && item.expectedIdentity.shape == [frameCount], "\(item.name): identity resampling must have 589 float32 frames")
            try #require(item.expectedPooling.dtype == "float32" && item.expectedPooling.shape == [frameCount], "\(item.name): pooling output must have 589 float32 frames")
            try #require(item.expectedHalfPixel.dtype == "float32" && item.expectedHalfPixel.shape == [poolingFrames], "\(item.name): half-pixel reference must have 125 float32 frames")

            let input = try item.input.float32()
            #expect(input.map(\.bitPattern) == (try item.expectedIdentity.float32()).map(\.bitPattern))

            let mask = try ActivityMask(values: input)
            let pooled = Community1Frontend.poolingMask(mask).values
            try #require(pooled.count == frameCount, "\(item.name): pooling output must have 589 frames")
            let expectedPooling = try item.expectedPooling.float32()
            #expect(pooled.map(\.bitPattern) == expectedPooling.map(\.bitPattern))
            #expect(pooled.enumerated().allSatisfy { index, value in
                scatterIndices.contains(index) || value.bitPattern == Float.zero.bitPattern
            })

            let gathered = scatterIndices.map { pooled[$0] }
            let halfPixelReference = try item.expectedHalfPixel.float32()
            if ["ramp", "scattered", "alternating"].contains(item.name) {
                // Compare sampling geometry only; this does not assert CoreML FP16 graph arithmetic.
                #expect(gathered.map(\.bitPattern) != halfPixelReference.map(\.bitPattern))
            }
        }
    }

    private func loadFrontendFixture() throws -> DiarizationFrontendFixture {
        let fixture = try DiarizationParityFixtures.load(
            "frontend.json",
            as: DiarizationFrontendFixture.self
        )
        #expect(fixture.metadata.schemaVersion == 1)
        #expect(fixture.metadata.fluidAudioVersion == "0.15.8")
        #expect(fixture.metadata.fluidAudioRevision == "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc")
        return fixture
    }
}
