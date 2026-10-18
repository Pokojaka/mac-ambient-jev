import FluidAudio
import Testing
import MacAmbientJevPipeline
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

@Suite("FluidVADSegmentationEngineTests")
struct FluidVADSegmentationEngineTests {
    @Test
    func vadThresholdsAndSegmentationDurationsRemainIndependent() {
        let vadConfig = FluidVADSegmentationEngine.vadConfig
        let segmentationConfig = FluidVADSegmentationEngine.segmentationConfig
        #expect(vadConfig.defaultThreshold == 0.50)
        #expect(segmentationConfig.negativeThreshold == nil)
        #expect(abs(
            segmentationConfig.effectiveNegativeThreshold(baseThreshold: vadConfig.defaultThreshold) - 0.35
        ) < 0.000_001)
        #expect(segmentationConfig.speechPadding == 0)
        #expect(segmentationConfig.minSilenceDuration == 0.75)
        #expect(segmentationConfig.maxSpeechDuration == 14.0)
        #expect(VADSegmentationParameters.speechProbabilityThreshold == 0.50)
        #expect(VADSegmentationParameters.splitSearchWindowSeconds == 2.0)
        #expect(VADSegmentationParameters.splitEnergyFrameSeconds == 0.02)
        #expect(VADSegmentationParameters.minimumIndependentSegmentSeconds == 0.5)
        #expect(VADSegmentationParameters.preRollSeconds == 0.10)
        #expect(VADSegmentationParameters.maxSegmentSeconds == 14.0)
        #expect(VADSegmentationParameters.minSilenceSeconds == 0.75)
        #expect(VADSegmentationParameters.chunkSamples == VadManager.chunkSize)
        #expect(MicSpeechLevelMeasurement.speechProbabilityThreshold == 0.85)
        #expect(ASRAudioInput.minimumDurationSeconds == 0.02)
    }
}
