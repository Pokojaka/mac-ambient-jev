import AVFoundation
import Foundation
import Testing
@testable import MacAmbientJevAppleSupport
import MacAmbientJevCore

private func makeASRClipDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Reads bits per sample from the FLAC STREAMINFO block, which AVAudioFile does not report.
private func flacBitsPerSample(_ url: URL) throws -> Int {
    let bytes = [UInt8](try Data(contentsOf: url).prefix(22))
    #expect(Array(bytes.prefix(4)) == Array("fLaC".utf8))
    return Int(bytes[20] & 1) << 4 | Int(bytes[21] >> 4) + 1
}

@Test(arguments: [320, 4_095, 4_096, 4_097, 16_001])
func asrClipFLACHasExactLengthAndQuantizedSamples(frameCount: Int) throws {
    let directory = try makeASRClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "clip.flac")
    let samples = (0..<frameCount).map { sin(Float($0) * 0.013) * 0.8 }

    try RecordingFLAC.writeASRClip(
        ASRAudioInput(samples: samples, sampleRate: Int(CanonicalAudio.sampleRate)),
        to: url, directory: directory
    )

    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    #expect(file.length == Int64(frameCount))
    #expect(file.fileFormat.sampleRate == CanonicalAudio.sampleRate)
    #expect(file.fileFormat.channelCount == CanonicalAudio.channelCount)
    #expect(try flacBitsPerSample(url) == RecordingFLAC.asrClipBitDepth)
    #expect(RecordingFLAC.asrClipBitDepth == 16)

    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)
    ))
    try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
    let decoded = Array(UnsafeBufferPointer(
        start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)
    ))
    let expected = samples.map { Float(RecordingFLAC.quantize16($0)!) / 32_768 }
    #expect(decoded.count == frameCount)
    #expect(decoded == expected)
}

@Test
func asrClipFLACRejectsNoncanonicalSampleRate() throws {
    let directory = try makeASRClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: RecordingFLACError.noncanonicalASRClipSampleRate(8_000)) {
        try RecordingFLAC.writeASRClip(
            ASRAudioInput(samples: [Float](repeating: 0.25, count: 320), sampleRate: 8_000),
            to: directory.appending(path: "clip.flac"), directory: directory
        )
    }
}

@Test
func asrClipFLACRejectsClipsShorterThanTheASRMinimumWithLocalizedError() throws {
    let directory = try makeASRClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let error = RecordingFLACError.asrClipTooShort(sampleCount: 319, minimum: 320)
    #expect(error.errorDescription?.contains("最低 320 サンプル") == true)

    #expect(throws: RecordingFLACError.asrClipTooShort(sampleCount: 319, minimum: 320)) {
        try RecordingFLAC.writeASRClip(
            ASRAudioInput(samples: [Float](repeating: 0.25, count: 319), sampleRate: 16_000),
            to: directory.appending(path: "clip.flac"), directory: directory
        )
    }
}

@Test
func asrClipFLACRejectsNonfiniteSamples() throws {
    let directory = try makeASRClipDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var samples = [Float](repeating: 0.25, count: 320)
    samples[3] = .nan

    #expect(throws: RecordingFLACError.nonFiniteSample(frame: 3)) {
        try RecordingFLAC.writeASRClip(
            ASRAudioInput(samples: samples, sampleRate: 16_000),
            to: directory.appending(path: "clip.flac"), directory: directory
        )
    }
}
