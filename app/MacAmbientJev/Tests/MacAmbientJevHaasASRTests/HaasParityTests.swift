import Foundation
import MacAmbientJevCore
import MacAmbientJevONNX
import MacAmbientJevSpeechFixtures
import Testing
@testable import MacAmbientJevHaasASR

@Suite(.serialized)
struct HaasParityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1", "Set RUN_MODEL_TESTS=1 and HAAS_ASR_ONNX_MODEL_DIRECTORY to run model parity."))
    func exactTokenParity() async throws {
        let directory = try haasModelDirectory()
        let goldenURL = try #require(Bundle.module.url(forResource: "haas_parity_golden", withExtension: "json", subdirectory: "Resources"))
        let golden = try JSONDecoder().decode(HaasParityGolden.self, from: Data(contentsOf: goldenURL))
        let engine = HaasASREngine(intraOpThreads: 4, locateModel: { HaasASRModelFiles(verifiedDirectory: directory) })
        do {
            try await engine.prepare()
            let clock = ContinuousClock()
            for clip in golden.clips {
                let wav = try Data(contentsOf: SpeechFixtures.wavURL(named: clip.resourceName))
                try #require(wav.count >= 44)
                #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
                #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
                #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
                #expect(wav[16] == 16 && wav[17] == 0 && wav[18] == 0 && wav[19] == 0)
                #expect(wav[20] == 1 && wav[21] == 0 && wav[22] == 1 && wav[23] == 0)
                let sampleRate = Int(wav[24]) | (Int(wav[25]) << 8) | (Int(wav[26]) << 16) | (Int(wav[27]) << 24)
                #expect(sampleRate == 16_000 && wav[34] == 16 && wav[35] == 0)
                #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
                let dataBytes = Int(wav[40]) | (Int(wav[41]) << 8) | (Int(wav[42]) << 16) | (Int(wav[43]) << 24)
                try #require(dataBytes % 2 == 0 && wav.count >= 44 + dataBytes)
                let samples = (0..<(dataBytes / 2)).map { i -> Float in
                    let offset = 44 + i * 2
                    return Float(Int16(bitPattern: UInt16(wav[offset]) | (UInt16(wav[offset + 1]) << 8))) / 32_768
                }
                #expect(samples.count == clip.sampleCount)
                let input = ASRAudioInput(samples: Array(samples.prefix(480_000)), sampleRate: 16_000)
                let start = clock.now
                let actual = try await engine.transcribeWithTokens(input)
                let elapsed = start.duration(to: clock.now)
                #expect(actual.tokenIDs == clip.tokenIDs)
                #expect(actual.text == clip.text)
                print("Haas parity clip=\(clip.resourceName) tokens=\(actual.tokenIDs.count) elapsed=\(elapsed) text=\(actual.text)")
                let result = try await engine.transcribe(input)
                #expect(result.text == clip.text)
                #expect(result.detectedLanguage == nil)
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1", "Set RUN_MODEL_TESTS=1 and HAAS_ASR_ONNX_MODEL_DIRECTORY to run model parity."))
    func rejectsDecoderGraphAtEncoderPath() throws {
        let source = try haasModelDirectory().appendingPathComponent("int8dyn", isDirectory: true)
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("haas-wrong-graph-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer {
            do { try manager.removeItem(at: temporary) }
            catch { Issue.record("Could not remove test directory \(temporary.path): \(error)") }
        }
        let int8dyn = temporary.appendingPathComponent("int8dyn", isDirectory: true)
        try manager.createDirectory(at: int8dyn, withIntermediateDirectories: false)
        try manager.copyItem(at: source.appendingPathComponent("decoder_joint.onnx"), to: int8dyn.appendingPathComponent("encoder.onnx"))
        try manager.copyItem(at: source.appendingPathComponent("decoder_joint.onnx.data"), to: int8dyn.appendingPathComponent("decoder_joint.onnx.data"))
        do {
            _ = try HaasONNXGraphs(files: HaasASRModelFiles(verifiedDirectory: temporary), environment: ONNXEnvironment.shared(), intraOpThreads: 4)
            Issue.record("Expected HaasASRError.unexpectedGraph for decoder at encoder path")
        } catch let error as HaasASRError {
            if case .unexpectedGraph = error { return }
            Issue.record("Expected unexpectedGraph, got \(error)")
        } catch {
            Issue.record("Expected HaasASRError.unexpectedGraph, got \(error)")
        }
    }
}

private struct HaasParityGolden: Decodable {
    struct Clip: Decodable {
        let resourceName: String
        let sampleCount: Int
        let tokenIDs: [Int]
        let text: String
    }
    let clips: [Clip]
}

private func haasModelDirectory() throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment["HAAS_ASR_ONNX_MODEL_DIRECTORY"], "HAAS_ASR_ONNX_MODEL_DIRECTORY is required")
    try #require(!path.isEmpty, "HAAS_ASR_ONNX_MODEL_DIRECTORY must not be empty")
    try #require((path as NSString).isAbsolutePath, "HAAS_ASR_ONNX_MODEL_DIRECTORY must be absolute")
    let url = URL(fileURLWithPath: path, isDirectory: true)
    var isDirectory: ObjCBool = false
    let manager = FileManager.default
    try #require(manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue && manager.isReadableFile(atPath: url.path), "HAAS_ASR_ONNX_MODEL_DIRECTORY must be an existing readable directory")
    return url
}
