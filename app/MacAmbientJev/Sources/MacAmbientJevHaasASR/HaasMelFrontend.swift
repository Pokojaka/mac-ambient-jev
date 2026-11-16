import Foundation

struct HaasMelFeatures: Equatable {
    /// 128 bin-major rows of `paddedFrames` values; frames after `validFrames` are zero.
    let values: [Float]
    let paddedFrames: Int
    let validFrames: Int
}

enum HaasMelFrontend {
    static let sampleRate = 16_000
    static let fftSize = 512
    static let windowLength = 400
    static let hop = 160
    static let melBins = 128
    static let padTo = 16

    static let window: [Float] = {
        var result = [Float](repeating: 0, count: fftSize)
        let offset = (fftSize - windowLength) / 2
        for index in 0..<windowLength {
            let phase = 2.0 * Double.pi * Double(index) / Double(windowLength - 1)
            result[offset + index] = bf16(Float(0.5 - 0.5 * Foundation.cos(phase)))
        }
        return result
    }()

    static let filterbank: [Float] = {
        let maxMel = slaneyMel(Double(sampleRate) / 2.0)
        let melPoints = (0..<(melBins + 2)).map {
            Double($0) * maxMel / Double(melBins + 1)
        }
        let hzPoints = melPoints.map(inverseSlaneyMel)
        var result = [Float](repeating: 0, count: melBins * (fftSize / 2 + 1))
        for mel in 0..<melBins {
            let lower = hzPoints[mel]
            let center = hzPoints[mel + 1]
            let upper = hzPoints[mel + 2]
            let areaNorm = 2.0 / (hzPoints[mel + 2] - hzPoints[mel])
            for bin in 0...(fftSize / 2) {
                let frequency = Double(bin) * Double(sampleRate) / Double(fftSize)
                let triangle = max(0.0, min(
                    (frequency - lower) / (center - lower),
                    (upper - frequency) / (upper - center)
                ))
                let floatTriangle = Float(triangle)
                let scaled = Float(Double(floatTriangle) * areaNorm)
                result[mel * (fftSize / 2 + 1) + bin] = bf16(scaled)
            }
        }
        return result
    }()

    static func features(of samples: [Float]) -> HaasMelFeatures {
        let validFrames = samples.count / hop
        precondition(validFrames >= 2, "Haas mel frontend requires at least 320 samples (two valid frames).")

        var emphasized = samples
        for index in 1..<samples.count {
            let previous = Float(0.97) * samples[index - 1]
            emphasized[index] = samples[index] - previous
        }

        let frameCount = 1 + samples.count / hop
        let paddedFrames = ((frameCount + padTo - 1) / padTo) * padTo
        var melFrames = [[Float]](
            repeating: [Float](repeating: 0, count: frameCount), count: melBins
        )
        var real = [Double](repeating: 0, count: fftSize)
        var imaginary = [Double](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: fftSize / 2 + 1)

        for frame in 0..<frameCount {
            let frameStart = frame * hop - fftSize / 2
            for index in 0..<fftSize {
                let sampleIndex = frameStart + index
                let sample = sampleIndex >= 0 && sampleIndex < emphasized.count
                    ? emphasized[sampleIndex] : 0
                let windowed = sample * window[index]
                real[index] = Double(windowed)
                imaginary[index] = 0
            }
            transform(real: &real, imaginary: &imaginary)

            for bin in 0...fftSize / 2 {
                power[bin] = Float(real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            for mel in 0..<melBins {
                let rowOffset = mel * (fftSize / 2 + 1)
                var sum: Float = 0
                for bin in 0...fftSize / 2 {
                    let product = filterbank[rowOffset + bin] * power[bin]
                    sum = sum + product
                }
                melFrames[mel][frame] = Foundation.log(sum + Float(1.0 / 16_777_216.0))
            }
        }

        var values = [Float](repeating: 0, count: melBins * paddedFrames)
        for mel in 0..<melBins {
            let row = melFrames[mel]
            var mean: Float = 0
            for frame in 0..<validFrames { mean = mean + row[frame] }
            mean = mean / Float(validFrames)
            var squaredDifferences: Float = 0
            for frame in 0..<validFrames {
                let difference = row[frame] - mean
                squaredDifferences = squaredDifferences + difference * difference
            }
            let standardDeviation = Foundation.sqrt(
                squaredDifferences / Float(validFrames - 1)
            ) + Float(1e-5)
            let offset = mel * paddedFrames
            for frame in 0..<validFrames {
                values[offset + frame] = (row[frame] - mean) / standardDeviation
            }
        }
        return HaasMelFeatures(values: values, paddedFrames: paddedFrames, validFrames: validFrames)
    }

    private static func bf16(_ value: Float) -> Float {
        let bits = value.bitPattern
        let rounded = (bits &+ 0x7fff &+ ((bits >> 16) & 1)) & 0xffff0000
        return Float(bitPattern: rounded)
    }

    private static func slaneyMel(_ hz: Double) -> Double {
        if hz <= 1_000.0 { return hz * (3.0 / 200.0) }
        return 15.0 + Foundation.log(hz / 1_000.0) / (Foundation.log(6.4) / 27.0)
    }

    private static func inverseSlaneyMel(_ mel: Double) -> Double {
        if mel <= 15.0 { return mel * (200.0 / 3.0) }
        return 1_000.0 * Foundation.exp((mel - 15.0) * (Foundation.log(6.4) / 27.0))
    }

    private static let bitReversal: [Int] = (0..<fftSize).map { value in
        var remaining = value
        var reversed = 0
        for _ in 0..<9 {
            reversed = (reversed << 1) | (remaining & 1)
            remaining >>= 1
        }
        return reversed
    }
    private static let twiddleReal: [Double] = (0..<(fftSize / 2)).map {
        Foundation.cos(2.0 * Double.pi * Double($0) / Double(fftSize))
    }
    private static let twiddleImaginary: [Double] = (0..<(fftSize / 2)).map {
        -Foundation.sin(2.0 * Double.pi * Double($0) / Double(fftSize))
    }

    private static func transform(real: inout [Double], imaginary: inout [Double]) {
        for index in 0..<fftSize {
            let reversed = bitReversal[index]
            if reversed > index {
                real.swapAt(index, reversed)
                imaginary.swapAt(index, reversed)
            }
        }
        var length = 2
        while length <= fftSize {
            let half = length / 2
            let twiddleStep = fftSize / length
            for base in stride(from: 0, to: fftSize, by: length) {
                for offset in 0..<half {
                    let even = base + offset
                    let odd = even + half
                    let twiddle = offset * twiddleStep
                    let oddReal = real[odd] * twiddleReal[twiddle]
                        - imaginary[odd] * twiddleImaginary[twiddle]
                    let oddImaginary = real[odd] * twiddleImaginary[twiddle]
                        + imaginary[odd] * twiddleReal[twiddle]
                    let evenReal = real[even]
                    let evenImaginary = imaginary[even]
                    real[even] = evenReal + oddReal
                    imaginary[even] = evenImaginary + oddImaginary
                    real[odd] = evenReal - oddReal
                    imaginary[odd] = evenImaginary - oddImaginary
                }
            }
            length <<= 1
        }
    }
}
