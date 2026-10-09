import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

private actor CountingASR: ASREngine {
    nonisolated let provenance = RunProvenance(engine: "fake-asr", model: nil, version: "test", configuration: [:])
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var isLoaded = false

    func prepare() async throws {
        guard !isLoaded else { return }
        loadCount += 1
        isLoaded = true
    }

    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        ASRResult(text: "", detectedLanguage: nil)
    }

    func unload() async {
        unloadCount += 1
        isLoaded = false
    }
}

private actor CountingDiarizer: DiarizationEngine {
    nonisolated let provenance = RunProvenance(engine: "fake-diarizer", model: nil, version: "test", configuration: [:])
    private(set) var unloadCount = 0
    func prepare() async throws {}
    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] { [] }
    func unload() async { unloadCount += 1 }
}

private struct UnusedVAD: FinalTranscriptVADSegmenter {
    let provenance = RunProvenance(engine: "fake-vad", model: nil, version: "test", configuration: [:])
    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] { [] }
}

private func makeProcessor(asr: CountingASR, diarizer: CountingDiarizer) -> NativeSessionProcessor {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support", directoryHint: .isDirectory),
        cacheURL: root.appending(path: "cache", directoryHint: .isDirectory),
        sessionsRootOverride: nil
    )
    return NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(asr: asr, diarization: diarizer, finalTranscriptVAD: UnusedVAD()),
        contentPriority: .disabled
    )
}

@Test("releasing idle resources unloads both engines, and preparing again loads the model again")
func releaseThenPrepareLoadsAgain() async throws {
    let asr = CountingASR()
    let diarizer = CountingDiarizer()
    let processor = makeProcessor(asr: asr, diarizer: diarizer)

    try await processor.prepareASR { _, _ in }
    #expect(await asr.loadCount == 1)

    await processor.releaseIdleResources()
    #expect(await asr.unloadCount == 1)
    #expect(await asr.isLoaded == false)
    #expect(await diarizer.unloadCount == 1)

    try await processor.prepareASR { _, _ in }
    #expect(await asr.loadCount == 2)
    #expect(await asr.isLoaded)
}
