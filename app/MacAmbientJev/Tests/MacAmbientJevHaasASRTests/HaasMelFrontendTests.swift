import Foundation
import MacAmbientJevCore
import MacAmbientJevSpeechFixtures
import Testing
@testable import MacAmbientJevHaasASR

private struct HaasMelGolden: Decodable {
    let shape: [Int]
    let validLength: Int
    let values: [Float]
}

struct HaasMelFrontendTests {
    @Test
    func matchesReferenceGolden() throws {
        let goldenURL = try #require(Bundle.module.url(
            forResource: "haas_mel_golden", withExtension: "json", subdirectory: "Resources"
        ))
        let golden = try JSONDecoder().decode(HaasMelGolden.self, from: Data(contentsOf: goldenURL))
        let wavURL = try SpeechFixtures.wavURL(named: "qwen3_asr_voicevox_short")
        let wav = try Data(contentsOf: wavURL)
        #expect(try FileSHA256.hexDigest(ofFileAt: wavURL) == "2dc561b78aed55815183f51ad66e1733909bdcefccd7f745e7cf0c64eecbb0e9")
        try #require(wav.count >= 44 + 32_000)
        try #require(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        let samples = (0..<16_000).map { index -> Float in
            let offset = 44 + index * 2
            let bits = UInt16(wav[offset]) | (UInt16(wav[offset + 1]) << 8)
            return Float(Int16(bitPattern: bits)) / 32_768
        }
        let features = HaasMelFrontend.features(of: samples)
        #expect(golden.shape == [1, 128, 112])
        #expect(golden.validLength == 100)
        #expect(features.validFrames == golden.validLength)
        #expect(features.paddedFrames == golden.shape[2])
        #expect(features.values.count == golden.values.count)
        #expect(features.values.allSatisfy { $0.isFinite })
        try #require(features.paddedFrames >= features.validFrames)
        #expect((0..<128).allSatisfy { mel in
            (features.validFrames..<features.paddedFrames).allSatisfy {
                features.values[mel * features.paddedFrames + $0] == 0
            }
        })
        let maxAbsError = try #require(zip(features.values, golden.values)
            .map { abs($0 - $1) }.max())
        print("HaasMelFrontendTests max-abs error = \(maxAbsError)")
        // Measured standalone max error: 6.2286854e-6; Float reduction/log rounding vs numpy is expected.
        #expect(maxAbsError <= 1e-4)
    }
}
