import Testing
import MacAmbientJevDiarization

@Suite
struct DiarizationFinalWindowPaddingTests {
    @Test
    func leavesInRangeEndUnchanged() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            15_999,
            sampleCount: 16_000,
            windowSamples: 160_000,
            stepSamples: 32_000
        ) == 15_999)
    }

    @Test
    func clampsAndRejectsAtFinalWindowPaddingBoundary() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            160_000, sampleCount: 16_000, windowSamples: 160_000, stepSamples: 32_000
        ) == 16_000)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            160_001, sampleCount: 16_000, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            1_567_946, sampleCount: 1_567_286, windowSamples: 160_000, stepSamples: 32_000
        ) == 1_567_286)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            288_000, sampleCount: 160_000, windowSamples: 160_000, stepSamples: 32_000
        ) == 160_000)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            288_001, sampleCount: 160_000, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            320_000, sampleCount: 160_001, windowSamples: 160_000, stepSamples: 32_000
        ) == 160_001)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            320_001, sampleCount: 160_001, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            160_000, sampleCount: 32_000, windowSamples: 160_000, stepSamples: 32_000
        ) == 32_000)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            160_001, sampleCount: 32_000, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            192_000, sampleCount: 32_001, windowSamples: 160_000, stepSamples: 32_000
        ) == 32_001)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            192_001, sampleCount: 32_001, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)
    }

    @Test
    func usesTheLastScheduledWindowWhenStepAndWindowDiffer() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            160_001, sampleCount: 160_000, windowSamples: 160_000, stepSamples: 160_000
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            300, sampleCount: 250, windowSamples: 100, stepSamples: 200
        ) == 250)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            301, sampleCount: 250, windowSamples: 100, stepSamples: 200
        ) == nil)

        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            151, sampleCount: 150, windowSamples: 100, stepSamples: 200
        ) == nil)
    }

    @Test
    func zeroSampleCountHasNoPadding() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: 0, windowSamples: 160_000, stepSamples: 32_000
        ) == 0)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            1, sampleCount: 0, windowSamples: 160_000, stepSamples: 32_000
        ) == nil)
    }

    @Test
    func rejectsNegativeInputsAndNonpositiveWindowGeometry() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: -1, windowSamples: 100, stepSamples: 50
        ) == nil)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            -1, sampleCount: 1, windowSamples: 100, stepSamples: 50
        ) == nil)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: 1, windowSamples: 0, stepSamples: 50
        ) == nil)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: 1, windowSamples: -1, stepSamples: 50
        ) == nil)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: 1, windowSamples: 100, stepSamples: 0
        ) == nil)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            0, sampleCount: 1, windowSamples: 100, stepSamples: -1
        ) == nil)
    }

    @Test
    func handlesInt64LimitsWithoutOverflow() {
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            Int64.max,
            sampleCount: Int64.max,
            windowSamples: 160_000,
            stepSamples: 32_000
        ) == Int64.max)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            Int64.max,
            sampleCount: Int64.max - 1,
            windowSamples: 160_000,
            stepSamples: 32_000
        ) == Int64.max - 1)
        #expect(DiarizationFinalWindowPadding.clampedEndFrame(
            Int64.max,
            sampleCount: 1,
            windowSamples: Int64.max,
            stepSamples: Int64.max
        ) == 1)
    }

    @Test(arguments: [
        Int64(0), 1, 15_999, 16_000, 31_999, 32_000, 32_001,
        159_999, 160_000, 160_001, 1_567_286
    ])
    func matchesReferenceScheduleForSmallGeometryGrid(sampleCount: Int64) {
        let geometries: [(windowSamples: Int64, stepSamples: Int64)] = [
            (160_000, 32_000),
            (160_000, 160_000),
            (100, 200)
        ]

        for geometry in geometries {
            let lastWindowStart = sampleCount > 0
                ? ((sampleCount - 1) / geometry.stepSamples) * geometry.stepSamples
                : 0
            let availableFinalWindowSamples = sampleCount > 0
                ? sampleCount - lastWindowStart
                : 0
            let paddingSamples = sampleCount > 0
                ? max(0, geometry.windowSamples - availableFinalWindowSamples)
                : 0
            let lastAcceptedEnd = sampleCount + paddingSamples
            let probes: [Int64] = [
                -1,
                0,
                sampleCount / 2,
                sampleCount,
                sampleCount + 1,
                lastAcceptedEnd,
                lastAcceptedEnd + 1
            ]

            for endFrame in probes {
                let expected: Int64?
                if endFrame < 0 {
                    expected = nil
                } else if endFrame <= sampleCount {
                    expected = endFrame
                } else if endFrame - sampleCount <= paddingSamples {
                    expected = sampleCount
                } else {
                    expected = nil
                }

                #expect(DiarizationFinalWindowPadding.clampedEndFrame(
                    endFrame,
                    sampleCount: sampleCount,
                    windowSamples: geometry.windowSamples,
                    stepSamples: geometry.stepSamples
                ) == expected)
            }
        }
    }
}
