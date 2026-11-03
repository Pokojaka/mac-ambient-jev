import Foundation
import Testing
import MacAmbientJevVADFixtures
@preconcurrency import FluidAudio
@testable import MacAmbientJevRuntime

@Suite("MacModelLoadingIntegrationTests")
struct MacModelLoadingIntegrationTests {
    @Test(.enabled(if: realModelTestsEnabled, "RUN_MODEL_TESTS=1 でピン留めしたモデルを使うときだけ実行する"))
    func diarizerLoadedFromTheVerifiedDirectoryMatchesFluidAudioAndDiarizes() async throws {
        let store = try realModelStore()
        let directory = try await store.verifiedDirectory(.diarization)

        let loaded = try await FluidModelLoading.diarizerModels(from: directory)
        let names = ModelNames.OfflineDiarizer.self
        let reference = try await loadOfflineDiarizerModelsUsingStaging(
            modelURLs: Dictionary(uniqueKeysWithValues: [
                names.segmentationPath, names.fbankPath, names.embeddingPath, names.pldaRhoPath,
            ].map { ($0, directory.appending(path: $0, directoryHint: .isDirectory)) }),
            pldaJSONURL: directory.appending(path: names.pldaParameters)
        )
        #expect(loaded.pldaPsi == reference.pldaPsi)

        let manager = OfflineDiarizerManager(config: FluidOfflineDiarizationEngine.configuration)
        manager.initialize(models: loaded)
        let result = try await manager.process(audio: SileroTestInputs.speechClipSamples())
        #expect(!result.segments.isEmpty)
    }

    @Test(.enabled(if: realModelTestsEnabled, "RUN_MODEL_TESTS=1 でピン留めしたモデルを使うときだけ実行する"))
    func enginesPrepareFromTheVerifiedDirectories() async throws {
        let store = try realModelStore()
        try await FluidOfflineDiarizationEngine(models: store).prepare()
        let vad = try await FluidVADSegmentationEngine.make(
            models: store, segmentationRunID: "seg", canonicalSampleRate: 16_000, measureMicInputLevels: false
        )
        let output = try await vad.process16kChunk(Array(repeating: 0, count: vad.chunkSize))
        #expect(output.segments.isEmpty)
    }
}
