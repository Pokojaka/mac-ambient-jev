import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline
import MacAmbientJevVADFixtures
@testable import MacAmbientJevRuntime

/// Downloads all three pinned models from Hugging Face into the application-support root
/// named by the environment (about 2.5 GB), verifies and loads them, and runs each on a short committed clip. Run it once by hand:
///
///     RUN_MODEL_TESTS=1 MAC_AMBIENT_JEV_TEST_APP_SUPPORT=/absolute/folder \
///       swift test --package-path app/MacAmbientJev --filter RealModelFetchIntegrationTests
///
/// The test runs only when `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` names an absolute path, so it never
/// downloads into the app's own folder. Files already in the folder are kept: kill a run and start
/// it again to see a real Range resume through the CDN. The throughput printed at the end counts only
/// the bytes this run downloaded.
@Suite("RealModelFetchIntegrationTests")
struct RealModelFetchIntegrationTests {
    @Test(
        .enabled(
            if: realModelTestsEnabled && testApplicationSupportIsSet,
            "RUN_MODEL_TESTS=1 と MAC_AMBIENT_JEV_TEST_APP_SUPPORT（絶対パス）があるときだけ実行する（最大約2.5 GB をダウンロードする）"
        ),
        .timeLimit(.minutes(10))
    )
    @MainActor
    func fetchesVerifiesLoadsAndRunsEveryPinnedModel() async throws {
        let store = try realModelStore()
        // Bytes already on disk for the models this run has to fetch (finished files and `.partial`
        // files). They are not downloaded again, so they stay out of the throughput.
        let alreadyOnDisk = MacModel.allCases
            .filter { !store.isFetched($0) }
            .reduce(Int64(0)) { $0 + Self.bytesOnDisk(in: store.directory($1)) }

        let asr = NativeQwen3ASREngine(models: store)
        let preparer = ModelPreparer(
            provisioning: MacModelProvisioning(store: store, transport: URLSessionModelTransport()),
            asr: asr
        )
        let clock = ContinuousClock()
        let start = clock.now
        var downloadEnd: ContinuousClock.Instant?
        var lastPercent = -1
        preparer.onChange = { status in
            if status.phase != .downloading, downloadEnd == nil { downloadEnd = clock.now }
            let percent = status.bytesTotal > 0 ? Int(status.bytesDone * 100 / status.bytesTotal) : 0
            if status.phase == .downloading, percent != lastPercent, percent % 10 == 0 {
                lastPercent = percent
                print("download \(percent)%  \(status.bytesDone) / \(status.bytesTotal) bytes")
            }
        }

        preparer.ensurePrepared(after: nil)
        let downloaded = preparer.status.bytesTotal - alreadyOnDisk
        await preparer.runTask?.value
        let finished = clock.now

        #expect(preparer.status.phase == .ready)
        let downloadSeconds = (downloadEnd ?? finished) - start
        let elapsed = finished - start
        let seconds = Double(downloadSeconds.components.seconds) + Double(downloadSeconds.components.attoseconds) / 1e18
        print("""
            downloaded \(downloaded) bytes in this run (\(alreadyOnDisk) were already on disk) in \(downloadSeconds) = \(Double(downloaded) / seconds / 1_048_576) MiB/s;
            verify and load took \(elapsed - downloadSeconds); total \(elapsed)
            """)

        let samples = try SileroTestInputs.speechClipSamples()
        let text = try await asr.transcribe(ASRAudioInput(samples: samples, sampleRate: 16_000)).text
        print("asr: \(text)")
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        await asr.unload()

        try await FluidOfflineDiarizationEngine(models: store).prepare()
        let vad = try await FluidVADSegmentationEngine.make(
            models: store, segmentationRunID: "seg", canonicalSampleRate: 16_000, measureMicInputLevels: false
        )
        _ = try await vad.process16kChunk(Array(repeating: 0, count: vad.chunkSize))
    }

    private static func bytesOnDisk(in directory: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(Int64(0)) { sum, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return sum + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }
}
