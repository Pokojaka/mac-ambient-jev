import AVFoundation
import FluidAudio

/// macOS adapter from source-agnostic interleaved frames to FluidAudio's input format.
public final class VADResampler {
    private let sourceFormat: AVAudioFormat
    private let converter = AudioConverter()

    public init?(sampleRate: Double, channelCount: Int) {
        guard sampleRate > 0, channelCount > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount)
              ) else { return nil }
        sourceFormat = format
    }

    public func resample(interleaved: [Float], frameCount: Int) throws -> [Float] {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)
        ) else { throw VADResamplerError.invalidSourceFormat }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = buffer.floatChannelData else {
            throw VADResamplerError.missingChannelData
        }
        let count = Int(sourceFormat.channelCount)
        for frame in 0..<frameCount {
            let base = frame * count
            for channel in 0..<count {
                channels[channel][frame] = interleaved[base + channel]
            }
        }
        return try converter.resampleBuffer(buffer)
    }
}

public enum VADResamplerError: Error {
    case invalidSourceFormat
    case missingChannelData
}
