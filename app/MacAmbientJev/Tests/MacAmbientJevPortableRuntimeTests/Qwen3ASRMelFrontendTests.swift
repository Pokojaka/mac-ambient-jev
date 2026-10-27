import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

private struct Qwen3ASRMelGoldenFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let sampleCount: Int
        let frameCount: Int
        let samplesF32LEBase64: String
        let values: [Double]

        private enum CodingKeys: String, CodingKey {
            case name
            case sampleCount = "sample_count"
            case frameCount = "frame_count"
            case samplesF32LEBase64 = "samples_f32le_base64"
            case values
        }
    }

    let sampleRate: Int
    let nFFT: Int
    let hop: Int
    let nMels: Int
    let cases: [Case]

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case nFFT = "n_fft"
        case hop
        case nMels = "n_mels"
        case cases
    }
}

private enum Qwen3ASRMelTestInputs {
    static func golden() throws -> Qwen3ASRMelGoldenFixture {
        let url = try #require(Bundle.module.url(
            forResource: "qwen3_mel_golden", withExtension: "json", subdirectory: "Resources"
        ))
        return try JSONDecoder().decode(Qwen3ASRMelGoldenFixture.self, from: Data(contentsOf: url))
    }

    static func samples(from fixture: Qwen3ASRMelGoldenFixture.Case) throws -> [Float] {
        let data = try #require(Data(base64Encoded: fixture.samplesF32LEBase64))
        #expect(data.count == fixture.sampleCount * MemoryLayout<UInt32>.size)
        try #require(data.count.isMultiple(of: 4))
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            return Float(bitPattern: bits)
        }
    }
}

struct Qwen3ASRMelFrontendGoldenTests {
    @Test(arguments: ["sine_mix", "chirp", "short_0_3s", "last_frame_peak", "dropped_only_peak", "minimum_reflect"])
    func matchesOfficialWhisperFeatureExtractorGolden(name: String) throws {
        let golden = try Qwen3ASRMelTestInputs.golden()
        #expect(golden.sampleRate == 16_000)
        #expect(golden.nFFT == 400)
        #expect(golden.hop == 160)
        #expect(golden.nMels == 128)

        let fixture = try #require(golden.cases.first { $0.name == name })
        let samples = try Qwen3ASRMelTestInputs.samples(from: fixture)
        #expect(samples.count == fixture.sampleCount)
        #expect(fixture.frameCount == fixture.sampleCount / golden.hop)
        #expect(fixture.values.count == 128 * fixture.frameCount)

        let actual = try Qwen3ASRMelFrontend().compute(samples: samples)
        #expect(actual.frameCount == fixture.frameCount)
        #expect(actual.values.count == 128 * fixture.frameCount)
        #expect(actual.values.allSatisfy { $0.isFinite })

        // Full-precision official WhisperFeatureExtractor output; measured max error was 1.1920928955078125e-7, with a modest rounding margin at the 2e-7 tolerance.
        let maximumError = try #require(
            zip(actual.values, fixture.values)
                .map { abs(Double($0) - $1) }
                .max()
        )
        print("\(name): max absolute mel error = \(maximumError)")
        #expect(maximumError <= 2e-7, "\(name): maximum absolute error was \(maximumError)")
    }

    @Test
    func droppedPeakDoesNotChangeRetainedFrames() throws {
        // For 559 samples, retained frame windows end at source index 519; index 558 enters only the dropped frame.
        let golden = try Qwen3ASRMelTestInputs.golden()
        let fixture = try #require(golden.cases.first { $0.name == "dropped_only_peak" })
        let samples = try Qwen3ASRMelTestInputs.samples(from: fixture)
        #expect(fixture.sampleCount == 559)
        #expect(samples.count == fixture.sampleCount)
        #expect(samples[558] == 1_000)

        var zeroedDroppedPeakSamples = samples
        zeroedDroppedPeakSamples[558] = 0

        let frontend = Qwen3ASRMelFrontend()
        let withDroppedPeak = try frontend.compute(samples: samples)
        let withoutDroppedPeak = try frontend.compute(samples: zeroedDroppedPeakSamples)
        #expect(withDroppedPeak.frameCount == fixture.frameCount)
        #expect(withoutDroppedPeak.frameCount == fixture.frameCount)
        #expect(withDroppedPeak.values.count == fixture.values.count)
        #expect(withDroppedPeak.values == withoutDroppedPeak.values)
        #expect(withDroppedPeak.values == fixture.values.map { Float($0) })
    }
}

struct Qwen3ASRMelFrontendValidationTests {
    private let frontend = Qwen3ASRMelFrontend()

    @Test
    func rejectsEmptyAndTooShortAudioAndAcceptsMinimumReflectLength() throws {
        #expect(throws: Qwen3ASRMelError.emptyInput) {
            try frontend.compute(samples: [])
        }
        for sampleCount in [1, 199, 200] {
            let error = try #require(throws: Qwen3ASRMelError.inputTooShort(sampleCount: sampleCount)) {
                try frontend.compute(samples: [Float](repeating: 0, count: sampleCount))
            }
            #expect(error.description.contains("reflect padding 200"))
            #expect(error.description.contains("201"))
        }

        let minimum = try frontend.compute(samples: [Float](repeating: 0, count: 201))
        #expect(minimum.frameCount == 1)
        #expect(minimum.values.count == 128)
    }

    @Test(arguments: [Float.nan, Float.infinity, -Float.infinity])
    func rejectsNonFiniteSamplesAtTheirExactIndex(sample: Float) {
        var samples = [Float](repeating: 0, count: 201)
        samples[123] = sample
        #expect(throws: Qwen3ASRMelError.nonFiniteSample(index: 123)) {
            try frontend.compute(samples: samples)
        }
    }

    @Test
    func silenceHasTheConfiguredLogPowerFloor() throws {
        let actual = try frontend.compute(samples: [Float](repeating: 0, count: 4_800))
        #expect(actual.frameCount == 30)
        #expect(actual.values.count == 128 * 30)
        #expect(actual.values.allSatisfy { $0 == -1.5 })
    }

    @Test
    func veryLargeFiniteFloatSamplesDoNotOverflowTheDoublePowerPath() throws {
        let samples = (0..<201).map { $0.isMultiple(of: 2) ? Float.greatestFiniteMagnitude : -Float.greatestFiniteMagnitude }
        let actual = try frontend.compute(samples: samples)
        #expect(actual.frameCount == 1)
        #expect(actual.values.count == 128)
        #expect(actual.values.allSatisfy { $0.isFinite })
    }

    @Test
    func frameLimitValidationIsMemoryFreeAndActualInputFailsBeforeSampleValidation() throws {
        let maximumSampleCount = 120_000 * 160 + 159
        #expect(try Qwen3ASRMelFrontend.validatedFrameCount(sampleCount: maximumSampleCount) == 120_000)
        #expect(throws: Qwen3ASRMelError.tooManyFrames(120_001)) {
            try Qwen3ASRMelFrontend.validatedFrameCount(sampleCount: 120_001 * 160)
        }
        #expect(throws: Qwen3ASRMelError.tooManyFrames(Int.max / 160)) {
            try Qwen3ASRMelFrontend.validatedFrameCount(sampleCount: Int.max)
        }

        var oversized = [Float](repeating: 0, count: 120_001 * 160)
        oversized[0] = .nan
        #expect(throws: Qwen3ASRMelError.tooManyFrames(120_001)) {
            try frontend.compute(samples: oversized)
        }
    }
}
