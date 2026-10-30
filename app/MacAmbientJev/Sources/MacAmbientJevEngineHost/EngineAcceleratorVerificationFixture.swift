import Foundation
import MacAmbientJevCore

/// Pinned production audio and expected transcript for accelerator verification.
enum EngineAcceleratorVerificationFixture {
    static let fixtureHash = "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9"
    static let expectedText = "今日は音声認識の動作を確認します。"
    static let policyVersion = "1"
    static let decodingSettings = "language=ja;greedy;max_new_tokens=448;no_repeat_ngram_size=null"

    private static let sampleCount = 52_907
    private static let expectedByteCount = 44 + 52_907 * 2

    static func load() throws -> ASRAudioInput {
        guard let url = Bundle.module.url(
            forResource: "qwen3_asr_voicevox_short",
            withExtension: "wav",
            subdirectory: "Resources"
        ) else {
            throw corruptFixtureError
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw corruptFixtureError
        }
        guard FileSHA256.hexDigest(of: data) == fixtureHash, data.count == expectedByteCount else {
            throw corruptFixtureError
        }

        let bytes = [UInt8](data)
        var samples = [Float]()
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let offset = 44 + index * 2
            let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Float(Int16(bitPattern: bits)) / 32_768.0)
        }
        return ASRAudioInput(samples: samples, sampleRate: 16_000)
    }

    private static var corruptFixtureError: EngineAdapterError {
        EngineAdapterError(
            code: .modelCorrupt,
            message: "アクセラレーター検証用音声が見つからないか、破損しています",
            recoveryAction: .none,
            details: []
        )
    }
}
