import Foundation
import Testing
@testable import MacAmbientJevWindowsSupport
import MacAmbientJevCore

private func resamplerTone(rate: Double, frameCount: Int) -> [Float] {
    (0..<frameCount).map { frame in
        Float(0.375 * sin(2 * Double.pi * 375 * Double(frame) / rate))
    }
}

private func expectCanonicalAudioError(
    _ expected: (CanonicalAudioError) -> Bool,
    operation: () throws -> Void,
    message: String
) {
    do {
        try operation()
        Issue.record("\(message)")
    } catch let error as CanonicalAudioError {
        if !expected(error) { Issue.record("Unexpected canonical audio error: \(error)") }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test(arguments: [8_000.0, 16_000.0, 22_050.0, 44_100.0, 48_000.0, 96_000.0])
func resamplingIsContinuousAndEndsAtTheRoundedBoundary(rate: Double) throws {
    let sourceFrameCount = Int(rate / 4) + 17
    let source = resamplerTone(rate: rate, frameCount: sourceFrameCount)
    let expectedFrames = try CanonicalAudio.boundary(Int64(sourceFrameCount), sampleRate: rate)

    let wholeConverter = try CanonicalAudioResampler(sampleRate: rate)
    var wholeOutput = try wholeConverter.convert(mono: source)
    wholeOutput += try wholeConverter.finish()
    #expect(wholeOutput.count == Int(expectedFrames))
    #expect(wholeOutput.allSatisfy { $0.isFinite })

    let streamingConverter = try CanonicalAudioResampler(sampleRate: rate)
    let partitions = [1, 17, 511, 8_192]
    var streamingOutput: [Float] = []
    var sourceOffset = 0
    var partitionIndex = 0
    while sourceOffset < source.count {
        let count = min(partitions[partitionIndex % partitions.count], source.count - sourceOffset)
        streamingOutput += try streamingConverter.convert(
            mono: Array(source[sourceOffset..<(sourceOffset + count)])
        )
        sourceOffset += count
        partitionIndex += 1

        let streamedBoundary = try CanonicalAudio.boundary(Int64(sourceOffset), sampleRate: rate)
        #expect(Int64(streamingOutput.count) <= streamedBoundary)
    }

    let finalTail = try streamingConverter.finish()
    streamingOutput += finalTail
    #expect(streamingOutput.count == Int(expectedFrames))
    #expect(streamingOutput.allSatisfy { $0.isFinite })
    #expect(try streamingConverter.finish().isEmpty)

    let maximumPartitionDifference = zip(wholeOutput, streamingOutput)
        .map { abs($0 - $1) }
        .max() ?? 0
    #expect(wholeOutput.count == streamingOutput.count)
    #expect(maximumPartitionDifference < 0.000001)

    let interior = 128..<(streamingOutput.count - 128)
    let maximumSineError = interior.reduce(Float.zero) { largest, frame in
        let expected = Float(0.375 * sin(2 * Double.pi * 375 * Double(frame) / CanonicalAudio.sampleRate))
        return max(largest, abs(streamingOutput[frame] - expected))
    }
    #expect(maximumSineError < 0.025)

    expectCanonicalAudioError(
        { if case .alreadyFinished = $0 { return true }; return false },
        operation: { _ = try streamingConverter.convert(mono: [0.25]) },
        message: "A finished resampler must reject additional input"
    )
}

@Test(arguments: [1, 2, 3, 4, 17, 127])
func tinyStreamsFinishAtTheRoundedBoundary(frameCount: Int) throws {
    let rate = 48_000.0
    let source = [Float](repeating: 0.25, count: frameCount)
    let converter = try CanonicalAudioResampler(sampleRate: rate)
    let beforeEndOfStream = try converter.convert(mono: source)
    let finalTail = try converter.finish()
    let expectedFrames = try CanonicalAudio.boundary(Int64(frameCount), sampleRate: rate)

    #expect(beforeEndOfStream.allSatisfy { $0.isFinite })
    #expect(finalTail.allSatisfy { $0.isFinite })
    #expect(beforeEndOfStream.count + finalTail.count == Int(expectedFrames))
    #expect(try converter.finish().isEmpty)

    if frameCount == 17 {
        #expect(beforeEndOfStream.count < Int(expectedFrames))
        #expect(!finalTail.isEmpty)
    }
}

@Test
func emptyAndIdentityStreamsPreserveTheirExactContract() throws {
    let emptyConverter = try CanonicalAudioResampler(sampleRate: 48_000)
    #expect(try emptyConverter.convert(mono: []).isEmpty)
    #expect(try emptyConverter.finish().isEmpty)
    #expect(try emptyConverter.finish().isEmpty)

    let source = resamplerTone(rate: CanonicalAudio.sampleRate, frameCount: 4_017)
    let identityConverter = try CanonicalAudioResampler(sampleRate: CanonicalAudio.sampleRate)
    #expect(try identityConverter.convert(mono: source) == source)
    #expect(try identityConverter.finish().isEmpty)
    #expect(try identityConverter.finish().isEmpty)
}

@Test
func invalidRatesAndNonFiniteSamplesFailFast() throws {
    for rate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity, 44_100.5] {
        expectCanonicalAudioError(
            { if case .invalidSourceFormat = $0 { return true }; return false },
            operation: { _ = try CanonicalAudioResampler(sampleRate: rate) },
            message: "Invalid sample rate \(rate) must be rejected"
        )
    }

    let converter = try CanonicalAudioResampler(sampleRate: 48_000)
    for sample in [Float.nan, Float.infinity, -Float.infinity] {
        expectCanonicalAudioError(
            { if case .invalidSamples = $0 { return true }; return false },
            operation: { _ = try converter.convert(mono: [sample]) },
            message: "Non-finite PCM input must be rejected"
        )
    }
}

@Test
func downsamplingRejectsElevenKilohertzBeforeAliasing() throws {
    let sourceRate = 48_000.0
    let sourceFrameCount = 48_000
    func tone(frequency: Double) -> [Float] {
        (0..<sourceFrameCount).map { frame in
            Float(0.5 * sin(2 * Double.pi * frequency * Double(frame) / sourceRate))
        }
    }

    let referenceConverter = try CanonicalAudioResampler(sampleRate: sourceRate)
    var referenceOutput = try referenceConverter.convert(mono: tone(frequency: 1_000))
    referenceOutput += try referenceConverter.finish()

    let stopBandConverter = try CanonicalAudioResampler(sampleRate: sourceRate)
    var stopBandOutput = try stopBandConverter.convert(mono: tone(frequency: 11_000))
    stopBandOutput += try stopBandConverter.finish()

    try #require(referenceOutput.count == 16_000)
    try #require(stopBandOutput.count == 16_000)
    #expect(referenceOutput.allSatisfy { $0.isFinite })
    #expect(stopBandOutput.allSatisfy { $0.isFinite })

    func rms(_ samples: [Float]) -> Double {
        let interior = 128..<(samples.count - 128)
        let sumOfSquares = interior.reduce(0.0) { sum, frame in
            let sample = Double(samples[frame])
            return sum + sample * sample
        }
        return sqrt(sumOfSquares / Double(interior.count))
    }

    let referenceRMS = rms(referenceOutput)
    let stopBandRMS = rms(stopBandOutput)
    let rejection = 20 * log10(referenceRMS / stopBandRMS)

    #expect(referenceRMS > 0.3)
    #expect(stopBandRMS > 0)
    #expect(rejection.isFinite)
    #expect(rejection >= 30)
}
