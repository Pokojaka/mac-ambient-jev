import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

private struct Qwen3ASRMelGoldenFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let sampleCount: Int
        let frameCount: Int
        let preDropFrameCount: Int
        let samplesF32LEBase64: String
        let values: [Double]
        let droppedFrameValues: [Double]
        let globalMaxBeforeDrop: Double
        let globalMaxRetained: Double

        private enum CodingKeys: String, CodingKey {
            case name
            case sampleCount = "sample_count"
            case frameCount = "frame_count"
            case preDropFrameCount = "pre_drop_frame_count"
            case samplesF32LEBase64 = "samples_f32le_base64"
            case values
            case droppedFrameValues = "dropped_frame_values"
            case globalMaxBeforeDrop = "global_max_before_drop"
            case globalMaxRetained = "global_max_retained"
        }
    }

    let numpyVersion: String
    let librosaVersion: String
    let sampleRate: Int
    let nFFT: Int
    let hop: Int
    let nMels: Int
    let cases: [Case]

    private enum CodingKeys: String, CodingKey {
        case numpyVersion = "numpy_version"
        case librosaVersion = "librosa_version"
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
    @Test(arguments: ["sine_mix", "chirp", "short_0_3s", "last_frame_peak", "minimum_reflect"])
    func matchesNumpyLibrosaGolden(name: String) throws {
        let golden = try Qwen3ASRMelTestInputs.golden()
        #expect(golden.numpyVersion == "2.5.4")
        #expect(golden.librosaVersion == "1.0.0")
        #expect(golden.sampleRate == 16_000)
        #expect(golden.nFFT == 400)
        #expect(golden.hop == 160)
        #expect(golden.nMels == 128)

        let fixture = try #require(golden.cases.first { $0.name == name })
        let expectedFrameCount: Int
        switch name {
        case "sine_mix": expectedFrameCount = 100
        case "chirp": expectedFrameCount = 23
        case "short_0_3s": expectedFrameCount = 30
        case "last_frame_peak": expectedFrameCount = 3
        case "minimum_reflect": expectedFrameCount = 1
        default: Issue.record("Unexpected golden case: \(name)"); return
        }

        let samples = try Qwen3ASRMelTestInputs.samples(from: fixture)
        #expect(samples.count == fixture.sampleCount)
        #expect(fixture.frameCount == expectedFrameCount)
        #expect(fixture.frameCount == fixture.sampleCount / 160)
        #expect(fixture.preDropFrameCount == fixture.frameCount + 1)
        #expect(fixture.values.count == 128 * fixture.frameCount)
        #expect(fixture.droppedFrameValues.count == 128)

        let actual = try Qwen3ASRMelFrontend().compute(samples: samples)
        #expect(actual.frameCount == fixture.frameCount)
        #expect(actual.values.count == 128 * fixture.frameCount)
        #expect(actual.values.allSatisfy { $0.isFinite })

        // The fixture rounds final values to 1e-6 and computes with NumPy float64; this
        // tolerance allows rounding and intermediate float32 window/FFT noise while
        // preserving the trained Float32 frontend's meaningful numerical parity.
        let maximumError = try #require(
            zip(actual.values, fixture.values)
                .map { abs(Double($0) - $1) }
                .max()
        )
        print("\(name): max absolute mel error = \(maximumError)")
        #expect(maximumError <= 1e-4, "\(name): maximum absolute error was \(maximumError)")
    }

    @Test
    func droppedPeakSetsTheRetainedFramesDynamicRangeWithoutBeingEmitted() throws {
        let golden = try Qwen3ASRMelTestInputs.golden()
        let fixture = try #require(golden.cases.first { $0.name == "last_frame_peak" })
        #expect(fixture.globalMaxBeforeDrop > fixture.globalMaxRetained)

        let actual = try Qwen3ASRMelFrontend().compute(
            samples: Qwen3ASRMelTestInputs.samples(from: fixture)
        )
        #expect(actual.frameCount == fixture.frameCount)
        #expect(actual.values.count == fixture.frameCount * 128)
        let actualMinimum = try #require(actual.values.min())
        let expectedMinimum = (fixture.globalMaxBeforeDrop - 8 + 4) / 4
        #expect(abs(Double(actualMinimum) - expectedMinimum) <= 1e-4)
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

struct Qwen3ASRMelFrontendPerformanceTests {
    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    @Test
    func measuresColdAndWarmThirtySecondAudio() throws {
        let samples = (0..<480_000).map { index -> Float in
            let time = Double(index) / 16_000
            return Float(0.5 * sin(2 * Double.pi * 440 * time) + 0.2 * sin(2 * Double.pi * 1_000 * time))
        }
        let frontend = Qwen3ASRMelFrontend()
        let clock = ContinuousClock()

        #if DEBUG
        print("Qwen3ASR mel benchmark build=debug")
        #else
        print("Qwen3ASR mel benchmark build=release")
        #endif

        let firstStart = clock.now
        let first = try frontend.compute(samples: samples)
        let firstElapsed = seconds(firstStart.duration(to: clock.now))
        #expect(first.frameCount == 3_000)
        let checksum = first.values.reduce(0.0) { $0 + Double($1) }
        #expect(checksum.isFinite)

        var warmElapsed: [Double] = []
        for _ in 0..<3 {
            let start = clock.now
            let warm = try frontend.compute(samples: samples)
            warmElapsed.append(seconds(start.duration(to: clock.now)))
            #expect(warm.frameCount == 3_000)
        }
        let sortedWarm = warmElapsed.sorted()
        print("Qwen3ASR mel benchmark first=\(firstElapsed)s, warm min=\(sortedWarm[0])s median=\(sortedWarm[1])s")
    }
}
