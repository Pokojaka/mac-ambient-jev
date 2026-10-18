import Foundation

public struct Qwen3ASRMelSpectrogram: Sendable {
    public let values: [Float]
    public let frameCount: Int
}

public enum Qwen3ASRMelError: Error, Equatable, CustomStringConvertible, Sendable {
    case emptyInput
    case inputTooShort(sampleCount: Int)
    case nonFiniteSample(index: Int)
    case tooManyFrames(Int)

    public var description: String {
        switch self {
        case .emptyInput:
            "audio input is empty"
        case let .inputTooShort(sampleCount):
            "audio input has \(sampleCount) samples; reflect padding 200 requires at least 201 samples"
        case let .nonFiniteSample(index):
            "audio sample at index \(index) is not finite"
        case let .tooManyFrames(frameCount):
            "audio input produces \(frameCount) frames; maximum is 120000"
        }
    }
}

public struct Qwen3ASRMelFrontend: Sendable {
    private struct ComplexValue: Sendable {
        let real: Double
        let imaginary: Double

        static let zero = ComplexValue(real: 0, imaginary: 0)
    }

    private struct MelTap: Sendable {
        let bin: Int
        let weight: Double
    }

    private static let fftSize = 400
    private static let hopSize = 160
    private static let melCount = 128
    private static let binCount = fftSize / 2 + 1
    private static let maximumFrames = 120_000
    private static let minimumSampleCount = 201

    private static let window: [Double] = (0..<fftSize).map { index in
        0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(fftSize))
    }

    private static let fftBitReversal: [Int] = (0..<16).map { value in
        var source = value
        var reversed = 0
        for _ in 0..<4 {
            reversed = (reversed << 1) | (source & 1)
            source >>= 1
        }
        return reversed
    }

    private static let fftTwiddles: [ComplexValue] = (0..<8).map { index in
        let angle = -2 * Double.pi * Double(index) / 16
        return ComplexValue(real: cos(angle), imaginary: sin(angle))
    }

    private static let combineTwiddles: [ComplexValue] = (0...200).flatMap { bin in
        (0..<25).map { residue in
            let angle = -2 * Double.pi * Double(bin * residue) / 400
            return ComplexValue(real: cos(angle), imaginary: sin(angle))
        }
    }

    private static let melFilters: [[MelTap]] = {
        let lowerMel = slaneyMel(0)
        let upperMel = slaneyMel(8_000)
        let melPoints = (0..<130).map { index in
            lowerMel + (upperMel - lowerMel) * Double(index) / 129
        }
        let frequencyPoints = melPoints.map(inverseSlaneyMel)

        return (0..<melCount).map { melIndex in
            let left = frequencyPoints[melIndex]
            let center = frequencyPoints[melIndex + 1]
            let right = frequencyPoints[melIndex + 2]
            let areaScale = 2 / (right - left)
            var taps: [MelTap] = []
            for bin in 0..<binCount {
                let frequency = 40 * Double(bin)
                let rising = (frequency - left) / (center - left)
                let falling = (right - frequency) / (right - center)
                let triangle = max(0, min(rising, falling))
                let floatTriangle = Float(triangle)
                let normalizedWeight = Float(Double(floatTriangle) * areaScale)
                if normalizedWeight > 0 {
                    taps.append(MelTap(bin: bin, weight: Double(normalizedWeight)))
                }
            }
            return taps
        }
    }()

    public init() {}

    public func compute(samples: [Float]) throws -> Qwen3ASRMelSpectrogram {
        let frameCount = try Self.validatedFrameCount(sampleCount: samples.count)
        for (index, sample) in samples.enumerated() {
            guard sample.isFinite else { throw Qwen3ASRMelError.nonFiniteSample(index: index) }
        }

        var output = [Float](repeating: 0, count: Self.melCount * frameCount)
        var globalMaximum = -Double.infinity
        var frameSamples = [Double](repeating: 0, count: Self.fftSize)
        var fftReal = [Double](repeating: 0, count: 16)
        var fftImaginary = [Double](repeating: 0, count: 16)
        var transformedResidues = [ComplexValue](repeating: .zero, count: 25 * 16)
        var powerBins = [Double](repeating: 0, count: Self.binCount)

        for frameIndex in 0...frameCount {
            let frameStart = frameIndex * Self.hopSize - Self.fftSize / 2
            for index in 0..<Self.fftSize {
                let sourceIndex = frameStart + index
                let reflectedIndex: Int
                if sourceIndex < 0 {
                    reflectedIndex = -sourceIndex
                } else if sourceIndex >= samples.count {
                    reflectedIndex = 2 * samples.count - 2 - sourceIndex
                } else {
                    reflectedIndex = sourceIndex
                }
                frameSamples[index] = Double(samples[reflectedIndex]) * Self.window[index]
            }

            for residue in 0..<25 {
                for sampleIndex in 0..<16 {
                    let sourceIndex = residue + 25 * sampleIndex
                    let reversedIndex = Self.fftBitReversal[sampleIndex]
                    fftReal[reversedIndex] = frameSamples[sourceIndex]
                    fftImaginary[reversedIndex] = 0
                }

                var stageLength = 2
                while stageLength <= 16 {
                    let halfLength = stageLength / 2
                    let twiddleStride = 16 / stageLength
                    for blockStart in Swift.stride(from: 0, to: 16, by: stageLength) {
                        for offset in 0..<halfLength {
                            let evenIndex = blockStart + offset
                            let oddIndex = evenIndex + halfLength
                            let twiddle = Self.fftTwiddles[offset * twiddleStride]
                            let oddReal = fftReal[oddIndex] * twiddle.real - fftImaginary[oddIndex] * twiddle.imaginary
                            let oddImaginary = fftReal[oddIndex] * twiddle.imaginary + fftImaginary[oddIndex] * twiddle.real
                            let evenReal = fftReal[evenIndex]
                            let evenImaginary = fftImaginary[evenIndex]
                            fftReal[evenIndex] = evenReal + oddReal
                            fftImaginary[evenIndex] = evenImaginary + oddImaginary
                            fftReal[oddIndex] = evenReal - oddReal
                            fftImaginary[oddIndex] = evenImaginary - oddImaginary
                        }
                    }
                    stageLength *= 2
                }

                for bin in 0..<16 {
                    transformedResidues[residue * 16 + bin] = ComplexValue(
                        real: fftReal[bin],
                        imaginary: fftImaginary[bin]
                    )
                }
            }

            for bin in 0..<Self.binCount {
                var real = 0.0
                var imaginary = 0.0
                let twiddleOffset = bin * 25
                for residue in 0..<25 {
                    let partial = transformedResidues[residue * 16 + bin % 16]
                    let twiddle = Self.combineTwiddles[twiddleOffset + residue]
                    real += partial.real * twiddle.real - partial.imaginary * twiddle.imaginary
                    imaginary += partial.real * twiddle.imaginary + partial.imaginary * twiddle.real
                }
                powerBins[bin] = real * real + imaginary * imaginary
            }

            for melIndex in 0..<Self.melCount {
                var melPower = 0.0
                for tap in Self.melFilters[melIndex] {
                    melPower += tap.weight * powerBins[tap.bin]
                }
                let logPower = log10(max(melPower, 1e-10))
                globalMaximum = max(globalMaximum, logPower)
                if frameIndex < frameCount {
                    output[melIndex * frameCount + frameIndex] = Float(logPower)
                }
            }
        }

        let minimumLogPower = globalMaximum - 8
        for index in output.indices {
            let logPower = max(Double(output[index]), minimumLogPower)
            output[index] = Float((logPower + 4) / 4)
        }
        return Qwen3ASRMelSpectrogram(values: output, frameCount: frameCount)
    }

    static func validatedFrameCount(sampleCount: Int) throws -> Int {
        guard sampleCount > 0 else { throw Qwen3ASRMelError.emptyInput }
        guard sampleCount >= minimumSampleCount else {
            throw Qwen3ASRMelError.inputTooShort(sampleCount: sampleCount)
        }
        let frameCount = sampleCount / hopSize
        guard frameCount <= maximumFrames else {
            throw Qwen3ASRMelError.tooManyFrames(frameCount)
        }
        return frameCount
    }

    private static func slaneyMel(_ frequency: Double) -> Double {
        if frequency < 1_000 {
            return frequency / (200.0 / 3.0)
        }
        return 15 + log(frequency / 1_000) / (log(6.4) / 27)
    }

    private static func inverseSlaneyMel(_ mel: Double) -> Double {
        if mel < 15 {
            return mel * (200.0 / 3.0)
        }
        return 1_000 * exp((log(6.4) / 27) * (mel - 15))
    }
}
