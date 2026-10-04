import AVFoundation
import Foundation
import FluidAudio
import MacAmbientJevCore

/// Random-access reads from the existing canonical CAF; no SRC or whole-audio copy.
final class CanonicalCAFAudioSource: AudioSampleSource, @unchecked Sendable {
    let sampleCount: Int
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()

    init(fileURL: URL) throws {
        guard fileURL.pathExtension.lowercased() == "caf" else { throw CanonicalAudioError.noncanonicalFormat }
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        try CanonicalAudio.validate(sampleRate: format.sampleRate, channelCount: Int(format.channelCount), sampleFormat: .float32LE)
        guard file.fileFormat.commonFormat == .pcmFormatFloat32,
              format.commonFormat == .pcmFormatFloat32,
              file.length <= Int.max,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        self.file = file
        self.buffer = buffer
        sampleCount = Int(file.length)
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard offset >= 0, count >= 0, offset <= sampleCount, count <= sampleCount - offset else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        lock.lock()
        defer { lock.unlock() }
        file.framePosition = Int64(offset)
        var copied = 0
        while copied < count {
            let requested = min(8192, count - copied)
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            guard buffer.frameLength == requested, let channels = buffer.floatChannelData else {
                throw CanonicalAudioError.conversionFailed("Unexpected EOF in canonical CAF")
            }
            let samples = UnsafeBufferPointer(start: channels[0], count: requested)
            guard samples.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
            destination.advanced(by: copied).update(from: channels[0], count: requested)
            copied += requested
        }
    }
}
