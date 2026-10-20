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
        #expect(Community1Profile.excludeOverlap)
    }

    @Test func frozenNumericalFloorsAndRoundingRules() {
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
        #expect(Community1Profile.hungarianRounding == .toNearestOrAwayFromZero)
        #expect(Community1Profile.expectedSpeakerCountRounding == .toNearestOrEven)
        #expect(Community1Profile.reconstructionFrameRounding == .toNearestOrAwayFromZero)
        #expect(Community1Profile.spanFrameRounding == .toNearestOrAwayFromZero)
        #expect(Community1Profile.zeroVoteReembedding == false)
    }
}
