import Foundation
import Testing
@testable import MacAmbientJevDiarization

/// Deterministic synthetic windows. The Mac generator in DiarizationFbankParityTests.swift carries the same recipe.
enum FbankParityInputs {
    static let caseNames = ["speech", "clipping", "silence", "short", "dc-offset"]
    static let constructions: [String: String] = [
        "speech": "160000 samples. Seed 1 LCG noise. x[n]=0.12*env[n]*sum_{k=1..6}(sin(2*pi*140*k*n/16000)/k)+0.01*noise[n], with env[n]=gate*(0.15+0.85*triangle(n mod 4000 over 0..1..0)) and gate=0 for n in 60000..<80000, else 1. Harmonics come from rotation oscillators.",
        "clipping": "160000 samples. Seed 2 LCG noise. x[n]=clamp(1.8*(0.7*sin(2*pi*220*n/16000)+0.3*sin(2*pi*3300*n/16000))+0.05*noise[n], -1, 1), so the waveform sits at exactly +-1 over long stretches.",
        "silence": "160000 samples of exact digital zero. Every mel energy is 0, which exercises the 1e-6 log floor.",
        "short": "48000 real samples (3 s) built like speech with f0 160 Hz and seed 3, followed by 112000 zeros so the 10 s window is zero padded.",
        "dc-offset": "160000 samples. Seed 4 LCG noise. x[n]=0.25+0.05*sin(2*pi*1000*n/16000)+0.002*noise[n].",
    ]

    static func availableSampleCount(_ name: String) -> Int {
        name == "short" ? 48_000 : 160_000
    }

    static func samples(_ name: String) -> [Float] {
        let count = availableSampleCount(name)
        var noise = Noise(seed: seed(name))
        switch name {
        case "speech":
            return speech(count: count, fundamental: 140, noise: &noise)
        case "short":
            return speech(count: count, fundamental: 160, noise: &noise)
        case "clipping":
            var low = Oscillator(hertz: 220)
            var high = Oscillator(hertz: 3300)
            return (0..<count).map { _ in
                let value = 1.8 * (0.7 * low.next() + 0.3 * high.next()) + 0.05 * noise.next()
                return Float(min(1, max(-1, value)))
            }
        case "silence":
            return [Float](repeating: 0, count: count)
        case "dc-offset":
            var tone = Oscillator(hertz: 1_000)
            return (0..<count).map { _ in Float(0.25 + 0.05 * tone.next() + 0.002 * noise.next()) }
        default:
            fatalError("unknown fbank parity case \(name)")
        }
    }

    private static func seed(_ name: String) -> UInt64 {
        switch name {
        case "speech": return 1
        case "clipping": return 2
        case "short": return 3
        case "dc-offset": return 4
        default: return 0
        }
    }

    private static func speech(count: Int, fundamental: Double, noise: inout Noise) -> [Float] {
        var harmonics = (1...6).map { Oscillator(hertz: fundamental * Double($0)) }
        return (0..<count).map { index in
            let phase = index % 4_000
            let triangle = phase < 2_000 ? Double(phase) / 2_000 : Double(4_000 - phase) / 2_000
            let gate = (60_000..<80_000).contains(index) ? 0.0 : 1.0
            let envelope = gate * (0.15 + 0.85 * triangle)
            var sum = 0.0
            for harmonic in harmonics.indices {
                sum += harmonics[harmonic].next() / Double(harmonic + 1)
            }
            return Float(0.12 * envelope * sum + 0.01 * noise.next())
        }
    }

    private struct Oscillator {
        private var cosine = 1.0
        private var sine = 0.0
        private let stepCosine: Double
        private let stepSine: Double

        init(hertz: Double) {
            let angle = 2 * Double.pi * hertz / 16_000
            stepCosine = cos(angle)
            stepSine = sin(angle)
        }

        mutating func next() -> Double {
            let output = sine
            let nextCosine = cosine * stepCosine - sine * stepSine
            sine = cosine * stepSine + sine * stepCosine
            cosine = nextCosine
            return output
        }
    }

    private struct Noise {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 2 * Double(state >> 11) / 9_007_199_254_740_992 - 1
        }
    }
}

@Suite struct Community1FbankTests {
    private static let fixtureAbsoluteError: Float = 3e-3

    @Test(arguments: FbankParityInputs.caseNames)
    func fullGridMatchesCoreML(name: String) throws {
        let fixture = try Self.caseFixture(name)
        let samples = FbankParityInputs.samples(name)
        try #require(samples.count == fixture.availableSampleCount)
        try #require(fixture.construction == FbankParityInputs.constructions[name])
        let audio = try Community1WindowPlan(sampleCount: Int64(samples.count)).window(at: 0) { range in
            Array(samples[Int(range.lowerBound)..<Int(range.upperBound)])
        }

        let features = Community1Fbank.shared.features(of: audio).values
        let expected = try fixture.expectedFeatures.float32()
        try #require(features.count == 998 * 80)
        try #require(expected.count == features.count)
        var maximumError: Float = 0
        for index in features.indices {
            maximumError = max(maximumError, abs(features[index] - expected[index]))
        }
        #expect(maximumError <= Self.fixtureAbsoluteError)
    }

    @Test func eachBinHasZeroMeanOverTheWindow() throws {
        let samples = FbankParityInputs.samples("speech")
        let audio = try Community1WindowPlan(sampleCount: Int64(samples.count)).window(at: 0) { range in
            Array(samples[Int(range.lowerBound)..<Int(range.upperBound)])
        }
        let features = Community1Fbank.shared.features(of: audio).values
        for bin in 0..<Community1Profile.melBins {
            var sum = 0.0
            for frame in 0..<Community1Profile.fbankFrames {
                sum += Double(features[frame * Community1Profile.melBins + bin])
            }
            #expect(abs(sum / Double(Community1Profile.fbankFrames)) <= 1e-5)
        }
    }

    private static func caseFixture(_ name: String) throws -> DiarizationFbankCaseFixture {
        let fixture = try DiarizationParityFixtures.load("fbank-\(name).json", as: DiarizationFbankCaseFixture.self)
        try #require(fixture.name == name)
        try #require(fixture.metadata.schemaVersion == 1)
        try #require(fixture.metadata.fluidAudioVersion == "0.15.8")
        try #require(fixture.metadata.fluidAudioRevision == "87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc")
        try #require(fixture.expectedFeatures.shape == [998, 80])
        return fixture
    }
}
