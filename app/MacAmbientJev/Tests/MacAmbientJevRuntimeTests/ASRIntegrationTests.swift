import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

@Suite
struct ASRIntegrationTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1",
            "Set RUN_MODEL_TESTS=1 to run the real-model ASR smoke test."
        )
    )
    func qwen3ASRLoadsModelAndTranscribesJapaneseAudio() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audioPath = try #require(
            environment["ASR_SMOKE_AUDIO"],
            "ASR_SMOKE_AUDIO must point to an explicit absolute WAV path."
        )
        try #require(audioPath.hasPrefix("/"))
        let audioURL = URL(fileURLWithPath: audioPath)
        try #require(FileManager.default.isReadableFile(atPath: audioURL.path))

        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        try #require(format.sampleRate == 16_000)
        try #require(format.channelCount == 1)
        try #require(audioFile.length > 0)
        try #require(audioFile.length <= Int64(format.sampleRate * 60))

        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            )
        )
        try audioFile.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let samples = Array(
            UnsafeBufferPointer(
                start: channels[0],
                count: Int(buffer.frameLength)
            )
        )

        let modelStore = ModelStore(paths: try .systemDefault(fileManager: .default))
        let engine = NativeQwen3ASREngine(modelStore: modelStore)
        try await engine.prepare()
        struct ModelConfiguration: Decodable {
            let support_languages: [String]
        }
        let configuration = try JSONDecoder().decode(
            ModelConfiguration.self,
            from: Data(contentsOf: modelStore.qwen3ASRCacheRoot.appending(path: "config.json"))
        )
        let promptLanguage = try #require(engine.provenance.configuration["language"] ?? nil)
        try #require(configuration.support_languages.contains(promptLanguage),
                     "The decoder prompt must use a language name supported by the loaded model.")
        let result = try await engine.transcribe(
            ASRAudioInput(samples: samples, sampleRate: Int(format.sampleRate))
        )
        await engine.unload()

        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!transcript.isEmpty)
        #expect(
            transcript.range(
                of: #"[ぁ-ゟ゠-ヿ一-龯]"#,
                options: .regularExpression
            ) != nil
        )
    }
}
