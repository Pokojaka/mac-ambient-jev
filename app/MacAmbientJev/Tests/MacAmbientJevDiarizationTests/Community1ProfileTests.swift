import Foundation
import Testing
@testable import MacAmbientJevDiarization

@Suite struct Community1ProfileTests {
    @Test func fixedGeometryAndModelShapes() {
        #expect(Community1Profile.sampleRate == 16_000)
        #expect(Community1Profile.windowSamples == 160_000)
        #expect(Community1Profile.stepSamples == 32_000)
        #expect(Community1Profile.windowDurationSeconds == 10.0)
        #expect(Community1Profile.stepRatio == 0.2)
        #expect(Double(Community1Profile.windowSamples) / Double(Community1Profile.sampleRate)
            == Community1Profile.windowDurationSeconds)
        #expect(Double(Community1Profile.stepSamples) / Double(Community1Profile.windowSamples)
            == Community1Profile.stepRatio)
        #expect(Community1Profile.segmentationFrames == 589)
        #expect(Community1Profile.powersetClasses == 7)
        #expect(Community1Profile.localSpeakers == 3)
        #expect(Community1Profile.embeddingDimensions == 256)
        #expect(Community1Profile.rhoDimensions == 128)
        #expect(Community1Profile.fbankFrames == 998)
        #expect(Community1Profile.melBins == 80)
        #expect(Community1Profile.poolingFrames == 125)
    }

    @Test func profileMatchesFluidAudioParameters() throws {
        let fixture = try DiarizationParityFixtures.load(
            "parameters.json",
            as: DiarizationParameterFixture.self
        )
        let expectedNumeric: [String: Double] = [
            "sampleRate": Double(Community1Profile.sampleRate),
            "windowSamples": Double(Community1Profile.windowSamples),
            "stepSamples": Double(Community1Profile.stepSamples),
            "windowDurationSeconds": Community1Profile.windowDurationSeconds,
            "stepRatio": Community1Profile.stepRatio,
            "minimumSegmentSeconds": Community1Profile.minimumSegmentSeconds,
            "ahcThreshold": Community1Profile.ahcThreshold,
            "fa": Community1Profile.fa,
            "fb": Community1Profile.fb,
            "maximumIterations": Double(Community1Profile.maximumIterations),
            "elboTolerance": Community1Profile.elboTolerance,
            "minimumGapSeconds": Community1Profile.minimumGapSeconds,
            "minimumOnSeconds": Community1Profile.minimumOnSeconds,
            "minimumOffSeconds": Community1Profile.minimumOffSeconds,
            "activePriorThreshold": Community1Profile.activePriorThreshold,
            // These are effective configuration observations, not portable profile selectors:
            // execution fixes batch size to 1, powerset ignores speech thresholds, and zero-vote is disabled.
            "embeddingBatchSize": 32,
            "speechOnsetThreshold": 0.5,
            "speechOffsetThreshold": 0.5,
            "zeroVoteMinimumDurationSeconds": 0.4,
        ]
        #expect(Set(fixture.numeric.keys) == Set(expectedNumeric.keys))
        for key in expectedNumeric.keys.sorted() {
            #expect(fixture.numeric[key] == expectedNumeric[key])
        }

        let expectedFixed = [
            "constrainedAssignment": "true",
            "embeddingExportPath": "nil",
            "embeddingSkipStrategy": "none",
            "excludeOverlap": "true",
            "exclusive": "true",
            "exposeChunkEmbeddings": "false",
            "maxSpeakers": "nil",
            "minSpeakers": "nil",
            "numSpeakers": "nil",
            "zeroVoteReembedding": "false",
        ]
        #expect(Set(fixture.fixed.keys) == Set(expectedFixed.keys))
        for key in expectedFixed.keys.sorted() {
            #expect(fixture.fixed[key] == expectedFixed[key])
        }
    }

    @Test func powersetBitOrderIsPinned() {
        #expect(Community1Profile.powersetSpeakerBits == [0, 1, 2, 4, 3, 5, 6])
    }

    @Test func minimumMaskThresholdsAndUnreachableFallbackRelation() {
        let frameDuration = Community1Profile.windowDurationSeconds
            / Double(Community1Profile.segmentationFrames)
        let derivedMinimumEmbeddingFrames = Int(ceil(
            Community1Profile.minimumSegmentSeconds / frameDuration
        ))
        let derivedMinimumActiveFrames = Int(ceil(
            Double(Community1Profile.minimumActiveRatio)
                * Double(Community1Profile.segmentationFrames)
        ))

        #expect(Community1Profile.overlapThreshold == 1e-3)
        #expect(Community1Profile.minimumActiveRatio == 0.2)
        #expect(Community1Profile.minimumSegmentSeconds == 0.3)
        #expect(derivedMinimumEmbeddingFrames == 18)
        #expect(derivedMinimumActiveFrames == 118)
        #expect(Community1Profile.minimumEmbeddingFrames == derivedMinimumEmbeddingFrames)
        #expect(Community1Profile.minimumActiveFrames == derivedMinimumActiveFrames)
        #expect(Community1Profile.minimumEmbeddingFrames < Community1Profile.minimumActiveFrames)
    }

    @Test func frozenNumericalFloors() {
        #expect(Community1Profile.embeddingL2Floor == 1e-4)
        #expect(Community1Profile.pldaFirstNormFloor == 1e-6)
        #expect(Community1Profile.pldaSecondNormFloor == 1e-6)
        #expect(Community1Profile.pldaEigenMaximumSweeps == 64)
        #expect(Community1Profile.pldaEigenRelativeTolerance == 1e-12)
        #expect(Community1Profile.phiFloor == 1e-12)
        #expect(Community1Profile.inversePrecisionDenominatorFloor == 1e-12)
        #expect(Community1Profile.logPriorFloor == 1e-8)
        #expect(Community1Profile.activePriorThreshold == 1e-7)
        #expect(Community1Profile.hungarianQuantization == 1e6)
    }
}
