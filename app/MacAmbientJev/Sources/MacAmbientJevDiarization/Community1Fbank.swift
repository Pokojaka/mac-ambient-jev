// Pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc.
import Foundation

/// The 998 x 80 per-bin mean-normalized log-mel features of one Community-1 window, frame-major.
public struct Community1FbankFeatures: Sendable {
    public let values: [Float]

    fileprivate init(values: [Float]) {
        self.values = values
    }
}

/// Portable Kaldi fbank replicating the compiled `FBank.mlmodelc` graph.
///
/// Op order follows `FBank.mlmodelc/model.mil:12-94`: scale by 32768, frame, remove the frame mean,
/// preemphasize with the first sample replicated, window, zero-pad to 512, power spectrum, mel bank,
/// `log(max(energy + 1e-6, 1e-6))`, then subtract each bin's mean over the 998 frames.
/// Framing and windowing run in Float32, the radix-2 FFT in Double, power and normalization in Float32.
struct Community1Fbank: Sendable {
    static let shared = Community1Fbank()

    let window: [Float]
    private let bitReversed: [Int]
    private let twiddleCosine: [Double]
    private let twiddleSine: [Double]
    let melWeights: [Float]
    let melFirstBin: [Int]
    let melEndBin: [Int]

    private init() {
        let frameLength = Community1Profile.frameLengthSamples
        let fftSize = Community1Profile.fftSize
        let melBins = Community1Profile.melBins
        let fftBins = Community1Profile.fftBins

        // Symmetric Hamming; compiled window weights `FBank.mlmodelc/model.mil:8`.
        window = (0..<frameLength).map { index in
            let phase = 2 * Double.pi * Double(index) / Double(frameLength - 1)
            return Float(Double(Community1Profile.hammingAlpha) - Double(Community1Profile.hammingBeta) * cos(phase))
        }

        var reversed = [Int](repeating: 0, count: fftSize)
        let stageCount = fftSize.trailingZeroBitCount
        for index in 0..<fftSize {
            var value = index
            var result = 0
            for _ in 0..<stageCount {
                result = (result << 1) | (value & 1)
                value >>= 1
            }
            reversed[index] = result
        }
        bitReversed = reversed

        let half = fftSize / 2
        twiddleCosine = (0..<half).map { cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        twiddleSine = (0..<half).map { -sin(2 * Double.pi * Double($0) / Double(fftSize)) }

        func mel(_ hertz: Double) -> Double {
            Community1Profile.melScaleSlope * log(1 + hertz / Community1Profile.melScaleBreakHz)
        }
        let lowMel = mel(Double(Community1Profile.lowFrequencyHz))
        let highMel = mel(Double(Community1Profile.highFrequencyHz))
        let delta = (highMel - lowMel) / Double(melBins + 1)
        let binWidthHz = Double(Community1Profile.sampleRate) / Double(fftSize)
        var weights = [Float](repeating: 0, count: melBins * fftBins)
        var firstBins = [Int](repeating: 0, count: melBins)
        var endBins = [Int](repeating: 0, count: melBins)
        for bank in 0..<melBins {
            let left = lowMel + Double(bank) * delta
            let center = lowMel + Double(bank + 1) * delta
            let right = lowMel + Double(bank + 2) * delta
            var first = fftBins
            var end = 0
            for bin in 0..<fftBins {
                let position = mel(binWidthHz * Double(bin))
                var weight = 0.0
                if position > left && position <= center {
                    weight = (position - left) / (center - left)
                } else if position > center && position < right {
                    weight = (right - position) / (right - center)
                }
                if weight > 0 {
                    weights[bank * fftBins + bin] = Float(weight)
                    first = min(first, bin)
                    end = bin + 1
                }
            }
            firstBins[bank] = first
            endBins[bank] = end
        }
        melWeights = weights
        melFirstBin = firstBins
        melEndBin = endBins
    }

    func features(of audio: WindowAudio) -> Community1FbankFeatures {
        let frameCount = Community1Profile.fbankFrames
        let melBins = Community1Profile.melBins
        var logMel = [Float](repeating: 0, count: frameCount * melBins)
        var frame = [Float](repeating: 0, count: Community1Profile.frameLengthSamples)
        var real = [Double](repeating: 0, count: Community1Profile.fftSize)
        var imaginary = [Double](repeating: 0, count: Community1Profile.fftSize)
        var power = [Float](repeating: 0, count: Community1Profile.fftBins)

        for frameIndex in 0..<frameCount {
            fillFrame(&frame, from: audio.samples, start: frameIndex * Community1Profile.frameShiftSamples)
            transform(frame, real: &real, imaginary: &imaginary)
            for bin in 0..<Community1Profile.fftBins {
                power[bin] = Float(real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            let rowStart = frameIndex * melBins
            for bank in 0..<melBins {
                var energy = 0.0
                let weightStart = bank * Community1Profile.fftBins
                for bin in melFirstBin[bank]..<melEndBin[bank] {
                    energy += Double(melWeights[weightStart + bin]) * Double(power[bin])
                }
                let offset = Float(energy) + Community1Profile.logEnergyOffset
                let clipped = max(offset, Community1Profile.logEnergyFloor)
                logMel[rowStart + bank] = Float(log(Double(clipped)))
            }
        }

        for bank in 0..<melBins {
            var sum = 0.0
            for frameIndex in 0..<frameCount {
                sum += Double(logMel[frameIndex * melBins + bank])
            }
            let mean = Float(sum / Double(frameCount))
            for frameIndex in 0..<frameCount {
                logMel[frameIndex * melBins + bank] -= mean
            }
        }
        return Community1FbankFeatures(values: logMel)
    }

    /// Scales, removes the frame mean, preemphasizes with the first sample replicated, and windows one frame.
    private func fillFrame(_ frame: inout [Float], from samples: [Float], start: Int) {
        let length = Community1Profile.frameLengthSamples
        let scale = Community1Profile.waveformScale
        var sum = 0.0
        for index in 0..<length {
            sum += Double(samples[start + index] * scale)
        }
        let mean = Float(sum / Double(length))
        var previous = samples[start] * scale - mean
        for index in 0..<length {
            let centered = samples[start + index] * scale - mean
            frame[index] = (centered - Community1Profile.preemphasis * previous) * window[index]
            previous = centered
        }
    }

    /// In-place iterative radix-2 FFT of the zero-padded frame in Double.
    func transform(_ frame: [Float], real: inout [Double], imaginary: inout [Double]) {
        let fftSize = Community1Profile.fftSize
        for index in 0..<fftSize {
            let source = bitReversed[index]
            real[index] = source < frame.count ? Double(frame[source]) : 0
            imaginary[index] = 0
        }
        var span = 1
        while span < fftSize {
            let twiddleStride = fftSize / (2 * span)
            var blockStart = 0
            while blockStart < fftSize {
                for offset in 0..<span {
                    let cosine = twiddleCosine[offset * twiddleStride]
                    let sine = twiddleSine[offset * twiddleStride]
                    let upper = blockStart + offset
                    let lower = upper + span
                    let productReal = real[lower] * cosine - imaginary[lower] * sine
                    let productImaginary = real[lower] * sine + imaginary[lower] * cosine
                    real[lower] = real[upper] - productReal
                    imaginary[lower] = imaginary[upper] - productImaginary
                    real[upper] += productReal
                    imaginary[upper] += productImaginary
                }
                blockStart += 2 * span
            }
            span *= 2
        }
    }
}
