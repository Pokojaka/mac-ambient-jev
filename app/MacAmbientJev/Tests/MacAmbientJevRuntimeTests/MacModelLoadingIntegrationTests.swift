import Testing
@preconcurrency import FluidAudio
@testable import MacAmbientJevRuntime

@Suite("MacModelLoadingIntegrationTests")
struct MacModelLoadingIntegrationTests {
    @Test(.enabled(if: realModelTestsEnabled, "RUN_MODEL_TESTS=1 でピン留めしたモデルを使うときだけ実行する"))
    func vadPreparesFromTheVerifiedDirectory() async throws {
        let store = try realModelStore()
        let vad = try await FluidVADSegmentationEngine.make(
            models: store, segmentationRunID: "seg", canonicalSampleRate: 16_000, measureMicInputLevels: false
        )
        let output = try await vad.process16kChunk(Array(repeating: 0, count: vad.chunkSize))
        #expect(output.segments.isEmpty)
    }
}
