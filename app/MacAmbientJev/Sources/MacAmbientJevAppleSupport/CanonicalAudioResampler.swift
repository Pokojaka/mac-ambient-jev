import AVFoundation
import MacAmbientJevCore

/// Stateful sample-rate conversion. The serialized ingress owner is the only caller.
public final class CanonicalAudioResampler: CanonicalAudioConverting, @unchecked Sendable {
    public let sourceSampleRate: Double
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let output: AVAudioPCMBuffer
    private var input: AVAudioPCMBuffer?
    private var ended = false
    private var failure: Error?
    private var sourceFrames: Int64 = 0
    private var outputFrames: Int64 = 0

    public init(sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let source = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: CanonicalAudio.sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw CanonicalAudioError.invalidSourceFormat
        }
        sourceSampleRate = sampleRate
        sourceFormat = source
        self.output = output
        if sampleRate == CanonicalAudio.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else {
                throw CanonicalAudioError.invalidSourceFormat
            }
            // Normal priming compensates the filter delay; EOS drains its trailing state.
            converter.primeMethod = .normal
            self.converter = converter
        }
    }

    public func convert(mono: [Float]) throws -> [Float] {
        if let failure { throw failure }
        guard !ended else { throw CanonicalAudioError.alreadyFinished }
        guard mono.allSatisfy(\.isFinite), mono.count <= Int(UInt32.max) else {
            throw CanonicalAudioError.invalidSamples
        }
        guard !mono.isEmpty else { return [] }
        let (total, overflow) = sourceFrames.addingReportingOverflow(Int64(mono.count))
        guard !overflow else { throw CanonicalAudioError.invalidSamples }
        sourceFrames = total
        guard converter != nil else {
            outputFrames += Int64(mono.count)
            return mono
        }
        if input == nil || input!.frameCapacity < mono.count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)) else {
                throw CanonicalAudioError.invalidSourceFormat
            }
            input = buffer
        }
        let buffer = input!
        buffer.frameLength = AVAudioFrameCount(mono.count)
        guard let channels = buffer.floatChannelData else { throw CanonicalAudioError.invalidSamples }
        mono.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: mono.count) }
        do { return try pull(input: buffer, eos: false) }
        catch { failure = error; throw error }
    }

    public func finish() throws -> [Float] {
        if let failure { throw failure }
        guard !ended else { return [] }
        do {
            let tail = try converter == nil ? [] : pull(input: nil, eos: true)
            // AVAudioConverter ends the stream at its filter phase: the floor or the ceiling
            // of the exact length, independent of block sizes. Keep every output frame.
            let exact = Double(sourceFrames) * CanonicalAudio.sampleRate / sourceSampleRate
            guard Double(outputFrames) >= exact.rounded(.down), Double(outputFrames) <= exact.rounded(.up) else {
                throw CanonicalAudioError.frameCountMismatch(
                    expected: try CanonicalAudio.boundary(sourceFrames, sampleRate: sourceSampleRate), actual: outputFrames
                )
            }
            ended = true
            return tail
        } catch { failure = error; throw error }
    }

    private func pull(input: AVAudioPCMBuffer?, eos: Bool) throws -> [Float] {
        guard let converter else { throw CanonicalAudioError.invalidSourceFormat }
        var supplied = false
        var result: [Float] = []
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if let input, !supplied {
                    supplied = true
                    status.pointee = .haveData
                    return input
                }
                status.pointee = eos ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            guard status != .error else { throw CanonicalAudioError.conversionFailed("AVAudioConverter returned error") }
            guard let channels = output.floatChannelData else { throw CanonicalAudioError.invalidSamples }
            let samples = UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength))
            guard samples.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
            result.append(contentsOf: samples)
            outputFrames += Int64(samples.count)
            if status == .endOfStream { return result }
            if status == .inputRanDry {
                guard !eos else { throw CanonicalAudioError.conversionFailed("EOS did not terminate conversion") }
                return result
            }
            guard !samples.isEmpty else { throw CanonicalAudioError.conversionFailed("Converter made no progress") }
        }
    }
}
