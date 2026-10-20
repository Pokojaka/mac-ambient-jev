import Foundation
import Testing
@testable import MacAmbientJevWindowsSupport
import CMiniaudio
import MacAmbientJevCore
import WinSDK
import ucrt

private func duplicateCRTDescriptor(from handle: HANDLE, flags: Int32) throws -> Int32 {
    var duplicate: HANDLE?
    guard DuplicateHandle(
        GetCurrentProcess(),
        handle,
        GetCurrentProcess(),
        &duplicate,
        0,
        false,
        DWORD(DUPLICATE_SAME_ACCESS)
    ), let duplicate else {
        let code = GetLastError()
        throw NSError(
            domain: "AudioFileTimelineBuilderTests",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Windows ハンドルの複製に失敗しました（エラーコード: \(code)）。"]
        )
    }

    let descriptor = _open_osfhandle(Int(bitPattern: duplicate), flags)
    guard descriptor >= 0 else {
        let code = errno
        _ = CloseHandle(duplicate)
        throw NSError(
            domain: "AudioFileTimelineBuilderTests",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Windows ハンドルから CRT ファイル記述子への変換に失敗しました（errno: \(code)）。"]
        )
    }
    return descriptor
}

private struct ImportTestDirectories {
    let root: URL
    let sessionURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        sessionURL = root.appending(path: "session", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func replaceUInt32LE(_ value: UInt32, at offset: Int, in data: inout Data) {
    var encoded = Data()
    appendUInt32LE(value, to: &encoded)
    data.replaceSubrange(offset..<(offset + 4), with: encoded)
}

private func appendUInt64LE(_ value: UInt64, to data: inout Data) {
    appendUInt32LE(UInt32(truncatingIfNeeded: value), to: &data)
    appendUInt32LE(UInt32(truncatingIfNeeded: value >> 32), to: &data)
}

private func appendASCII(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

private func waveHeader(sampleRate: Int, channelCount: Int, frameCount: Int) throws -> Data {
    let payloadByteCount = frameCount * channelCount * MemoryLayout<Int16>.size
    guard let payloadBytes = UInt32(exactly: payloadByteCount),
          let rate = UInt32(exactly: sampleRate),
          let channels = UInt16(exactly: channelCount),
          let blockAlign = UInt16(exactly: channelCount * MemoryLayout<Int16>.size),
          let byteRate = UInt32(exactly: sampleRate * channelCount * MemoryLayout<Int16>.size),
          let riffBytes = UInt32(exactly: 36 + payloadByteCount) else {
        throw CocoaError(.fileWriteUnknown)
    }

    var header = Data()
    appendASCII("RIFF", to: &header)
    appendUInt32LE(riffBytes, to: &header)
    appendASCII("WAVE", to: &header)
    appendASCII("fmt ", to: &header)
    appendUInt32LE(16, to: &header)
    appendUInt16LE(1, to: &header)
    appendUInt16LE(channels, to: &header)
    appendUInt32LE(rate, to: &header)
    appendUInt32LE(byteRate, to: &header)
    appendUInt16LE(blockAlign, to: &header)
    appendUInt16LE(16, to: &header)
    appendASCII("data", to: &header)
    appendUInt32LE(payloadBytes, to: &header)
    return header
}

private func pcm16Payload(
    sampleRate: Int,
    channelCount: Int,
    frames: Range<Int>
) -> Data {
    var payload = Data()
    payload.reserveCapacity(frames.count * channelCount * MemoryLayout<Int16>.size)
    for frame in frames {
        let wave = sin(2 * Double.pi * 375 * Double(frame) / Double(sampleRate))
        for channel in 0..<channelCount {
            let gain = Double(channel + 1) * 0.5 / Double(channelCount)
            let quantized = (wave * gain * 32_768).rounded(.toNearestOrAwayFromZero)
            let sample = Int16(quantized)
            appendUInt16LE(UInt16(bitPattern: sample), to: &payload)
        }
    }
    return payload
}

private func writePCM16Wave(
    to url: URL,
    sampleRate: Int,
    channelCount: Int,
    frameCount: Int,
    writeChunkFrames: Int = 4_096
) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: waveHeader(
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCount: frameCount
    ))
    var start = 0
    while start < frameCount {
        let end = min(start + writeChunkFrames, frameCount)
        try handle.write(contentsOf: pcm16Payload(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frames: start..<end
        ))
        start = end
    }
}

private func writeTruncatedRF64(to url: URL) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }

    var header = Data()
    appendASCII("RF64", to: &header)
    appendUInt32LE(UInt32.max, to: &header)
    appendASCII("WAVE", to: &header)
    appendASCII("ds64", to: &header)
    appendUInt32LE(28, to: &header)
    appendUInt64LE(UInt64(72 + 288_000 * 2), to: &header)
    appendUInt64LE(UInt64(288_000 * 2), to: &header)
    appendUInt64LE(288_000, to: &header)
    appendUInt32LE(0, to: &header)
    appendASCII("fmt ", to: &header)
    appendUInt32LE(16, to: &header)
    appendUInt16LE(1, to: &header)
    appendUInt16LE(1, to: &header)
    appendUInt32LE(48_000, to: &header)
    appendUInt32LE(96_000, to: &header)
    appendUInt16LE(2, to: &header)
    appendUInt16LE(16, to: &header)
    appendASCII("data", to: &header)
    appendUInt32LE(UInt32.max, to: &header)
    try handle.write(contentsOf: header)

    let frameCount = 144_000
    var start = 0
    while start < frameCount {
        let end = min(start + 4_096, frameCount)
        try handle.write(contentsOf: pcm16Payload(
            sampleRate: 48_000,
            channelCount: 1,
            frames: start..<end
        ))
        start = end
    }
}

private func meanChannelGain(_ channelCount: Int) -> Double {
    (0..<channelCount).reduce(0.0) { sum, channel in
        sum + Double(channel + 1) * 0.5 / Double(channelCount)
    } / Double(channelCount)
}

private func importFile(_ sourceURL: URL, into directories: ImportTestDirectories) throws -> ImportedAudio {
    try AudioImporter().importFile(sourceURL, into: directories.sessionURL)
}

private func processingDirectory(for directories: ImportTestDirectories) -> URL {
    directories.sessionURL
        .appending(path: "audio", directoryHint: .isDirectory)
        .appending(path: "processing", directoryHint: .isDirectory)
}

private func storageStore(for directories: ImportTestDirectories) -> SessionAudioStorageStore {
    SessionAudioStorageStore(layout: SessionLayout(sessionURL: directories.sessionURL))
}

private func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
}

private func fileDigest(_ url: URL) throws -> UInt64 {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash: UInt64 = 14_695_981_039_346_656_037
    while let data = try handle.read(upToCount: 8_192), !data.isEmpty {
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
    }
    return hash
}

private func decodedNativeFrameExtent(
    from url: URL,
    sessionURL: URL
) throws -> (sampleRate: Double, frameCount: Int64, signalOnset: Int64?) {
    let decoder = try AudioImportDecoder(url: url, sessionURL: sessionURL)
    let sampleRate = decoder.sampleRate
    var frameCount: Int64 = 0
    var signalOnset: Int64?
    while true {
        let samples = try decoder.readMono(frameCount: 97)
        if samples.isEmpty { break }
        if signalOnset == nil,
           let firstSignalFrame = samples.firstIndex(where: { abs($0) > 0.05 }) {
            signalOnset = frameCount + Int64(firstSignalFrame)
        }
        frameCount += Int64(samples.count)
    }
    return (sampleRate, frameCount, signalOnset)
}

@Test(arguments: [
    (8_000, 1),
    (16_000, 1),
    (22_050, 2),
    (44_100, 2),
    (48_000, 1),
    (48_000, 4),
    (96_000, 2),
])
func generatedPCM16WavesBuildCanonicalTimelines(sampleRate: Int, channelCount: Int) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceFrameCount = sampleRate / 4 + 17
    let sourceURL = directories.root.appending(path: "source.wav")
    try writePCM16Wave(
        to: sourceURL,
        sampleRate: sampleRate,
        channelCount: channelCount,
        frameCount: sourceFrameCount
    )
    let originalBytes = try Data(contentsOf: sourceURL)

    let storage = storageStore(for: directories)
    try storage.save(.importedOriginal(nil))
    let imported = try importFile(sourceURL, into: directories)
    #expect(imported.originalURL.path != sourceURL.path)
    #expect(try Data(contentsOf: imported.originalURL) == originalBytes)

    let processing = processingDirectory(for: directories)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 257).build(
        from: imported.originalURL,
        into: processing,
        sessionURL: directories.sessionURL
    )
    let expectedFrames = try CanonicalAudio.boundary(Int64(sourceFrameCount), sampleRate: Double(sampleRate))
    #expect(checkpoint.committedFrames == expectedFrames)
    #expect(checkpoint.sampleRate == CanonicalAudio.sampleRate)
    #expect(checkpoint.channelCount == CanonicalAudio.channelCount)
    #expect(checkpoint.sampleFormat == CanonicalAudio.sampleFormat)
    #expect(checkpoint.gapEvents.isEmpty)
    #expect(checkpoint.chunkFrameCounts.reduce(Int64.zero) { $0 + Int64($1) } == checkpoint.committedFrames)
    #expect(try AudioCheckpoint.loadRecovered(from: processing, relativeTo: directories.sessionURL) == checkpoint)

    let reader = try ProcessingTimelineReader(
        directory: processing,
        checkpoint: checkpoint,
        sessionURL: directories.sessionURL
    )
    let samples = try reader.readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(samples.count == Int(checkpoint.committedFrames))
    #expect(samples.allSatisfy { $0.isFinite })
    let interior = 128..<(samples.count - 128)
    let averageGain = meanChannelGain(channelCount)
    let maximumSineError = interior.reduce(Float.zero) { largest, frame in
        let expected = Float(averageGain * sin(2 * Double.pi * 375 * Double(frame) / CanonicalAudio.sampleRate))
        return max(largest, abs(samples[frame] - expected))
    }
    #expect(maximumSineError < 0.025)

    let rebuiltCheckpoint = try await AudioFileTimelineBuilder(readFrameCount: 8_192).build(
        from: imported.originalURL,
        into: processing,
        sessionURL: directories.sessionURL
    )
    let rebuiltSamples = try ProcessingTimelineReader(
        directory: processing,
        checkpoint: rebuiltCheckpoint,
        sessionURL: directories.sessionURL
    ).readSamples(frameRange: 0..<rebuiltCheckpoint.committedFrames)
    #expect(rebuiltCheckpoint.committedFrames == checkpoint.committedFrames)
    #expect(rebuiltSamples.count == samples.count)
    #expect(maximumDifference(samples, rebuiltSamples) < 0.000001)
    #expect(try Data(contentsOf: sourceURL) == originalBytes)
    #expect(try Data(contentsOf: imported.originalURL) == originalBytes)

    #expect(try storage.load() == .importedOriginal(nil))
    let publishedInfo = try TimelineAudioInfo(
        committedFrames: checkpoint.committedFrames,
        gapEvents: checkpoint.gapEvents
    )
    try storage.save(.importedOriginal(publishedInfo))
    #expect(try storage.load() == .importedOriginal(publishedInfo))
}

@Test(arguments: ["streaming", "trailingChunk", "outerSize"])
func completePCM16WAVVariantsRetainTheirDecodedFrameBoundary(variant: String) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    var sourceBytes = try waveHeader(sampleRate: 48_000, channelCount: 1, frameCount: 12_288)
    sourceBytes.append(pcm16Payload(sampleRate: 48_000, channelCount: 1, frames: 0..<12_288))
    switch variant {
    case "streaming":
        replaceUInt32LE(UInt32.max, at: 4, in: &sourceBytes)
        replaceUInt32LE(UInt32.max, at: 40, in: &sourceBytes)
    case "trailingChunk":
        let trailingChunkDeclaredSize: UInt32 = 64
        let trailingChunkPayloadSize: UInt32 = 4
        appendASCII("LIST", to: &sourceBytes)
        appendUInt32LE(trailingChunkDeclaredSize, to: &sourceBytes)
        appendASCII("INFO", to: &sourceBytes)
        let riffSize = UInt32(sourceBytes.count - 8) + trailingChunkDeclaredSize - trailingChunkPayloadSize
        replaceUInt32LE(riffSize, at: 4, in: &sourceBytes)
    case "outerSize":
        replaceUInt32LE(UInt32(sourceBytes.count), at: 4, in: &sourceBytes)
    default:
        Issue.record("WAV のテスト形式が不正です: \(variant)")
        return
    }

    let sourceURL = directories.root.appending(path: "source.wav")
    try sourceBytes.write(to: sourceURL)
    try storageStore(for: directories).save(.importedOriginal(nil))
    let imported = try importFile(sourceURL, into: directories)
    #expect(try Data(contentsOf: imported.originalURL) == sourceBytes)

    let nativeExtent = try decodedNativeFrameExtent(
        from: imported.originalURL,
        sessionURL: directories.sessionURL
    )
    #expect(nativeExtent.frameCount == 12_288)

    let processing = processingDirectory(for: directories)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 257).build(
        from: imported.originalURL,
        into: processing,
        sessionURL: directories.sessionURL
    )
    #expect(checkpoint.committedFrames == 4_096)

    let samples = try ProcessingTimelineReader(
        directory: processing,
        checkpoint: checkpoint,
        sessionURL: directories.sessionURL
    ).readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(samples.count == 4_096)
    let interior = 128..<(samples.count - 128)
    let maximumSineError = interior.reduce(Float.zero) { largest, frame in
        let expected = Float(0.5 * sin(2 * Double.pi * 375 * Double(frame) / CanonicalAudio.sampleRate))
        return max(largest, abs(samples[frame] - expected))
    }
    #expect(maximumSineError < 0.025)
    #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    #expect(try Data(contentsOf: imported.originalURL) == sourceBytes)
}

@Test
func sixSecondImportCrossesTheFiveSecondStorageChunkBoundary() async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceURL = directories.root.appending(path: "long-source.wav")
    try writePCM16Wave(to: sourceURL, sampleRate: 48_000, channelCount: 1, frameCount: 288_000)
    let sourceDigest = try fileDigest(sourceURL)
    let sourceSize = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber
    #expect((sourceSize?.intValue ?? 0) > 64 * 1_024)

    let imported = try importFile(sourceURL, into: directories)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 8_192).build(
        from: imported.originalURL,
        into: processingDirectory(for: directories),
        sessionURL: directories.sessionURL
    )
    #expect(checkpoint.committedFrames == 96_000)
    #expect(checkpoint.chunkFrameCounts == [80_000, 16_000])
    #expect(checkpoint.chunkFrameCounts.reduce(Int64.zero) { $0 + Int64($1) } == checkpoint.committedFrames)
    #expect(try fileDigest(sourceURL) == sourceDigest)
    #expect(try fileDigest(imported.originalURL) == sourceDigest)
}

@Test
func miniaudioReadIOFailureRemainsTerminalRatherThanEOF() throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceURL = directories.root.appending(path: "source.wav")
    try writePCM16Wave(to: sourceURL, sampleRate: 48_000, channelCount: 1, frameCount: 288_000)
    let sinkURL = directories.root.appending(path: "sink.bin")
    guard FileManager.default.createFile(atPath: sinkURL.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
    defer { try? sourceHandle.close() }
    let sinkHandle = try FileHandle(forWritingTo: sinkURL)
    defer { try? sinkHandle.close() }

    let readFD = try duplicateCRTDescriptor(from: sourceHandle._handle, flags: _O_BINARY | _O_RDONLY)
    defer { _ = _close(readFD) }
    let writeFD = try duplicateCRTDescriptor(from: sinkHandle._handle, flags: _O_BINARY | _O_WRONLY)
    defer { _ = _close(writeFD) }

    var ownedDecoder: OpaquePointer?
    defer {
        if let ownedDecoder { mja_decoder_destroy(ownedDecoder) }
    }
    var sampleRate: UInt32 = 0
    var channels: UInt32 = 0
    var length: UInt64 = 0
    let createResult = mja_decoder_create(readFD, MJA_DECODER_FORMAT_WAV, &ownedDecoder, &sampleRate, &channels, &length)
    guard createResult == 0, let decoder = ownedDecoder else {
        Issue.record("miniaudio decoder creation failed with result \(createResult)")
        return
    }

    #expect(sampleRate == 48_000)
    #expect(channels == 1)
    #expect(length == 288_000)

    guard _dup2(writeFD, readFD) == 0 else {
        let code = errno
        throw NSError(
            domain: "AudioFileTimelineBuilderTests",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "CRT ファイル記述子の置換に失敗しました（errno: \(code)）。"]
        )
    }

    let maxReadCalls = Int((length + 8_191) / 8_192) + 1
    var output = [Float](repeating: 0, count: 8_192)
    var observedFailure = false
    var observedEOF = false
    for _ in 0..<maxReadCalls {
        var framesRead: UInt64 = 0
        let result = output.withUnsafeMutableBufferPointer { buffer in
            mja_decoder_read(decoder, buffer.baseAddress, UInt64(buffer.count), &framesRead)
        }
        if result != 0 {
            // miniaudio 0.11.23 defines MA_IO_ERROR as -20.
            #expect(result == -20)
            #expect(framesRead == 0)

            var repeatedFramesRead: UInt64 = 0
            let repeatedResult = output.withUnsafeMutableBufferPointer { buffer in
                mja_decoder_read(decoder, buffer.baseAddress, UInt64(buffer.count), &repeatedFramesRead)
            }
            #expect(repeatedResult == result)
            #expect(repeatedFramesRead == 0)
            observedFailure = true
            break
        }
        if framesRead == 0 {
            Issue.record("miniaudio reported clean EOF instead of an I/O failure")
            observedEOF = true
            break
        }
    }
    if !observedFailure && !observedEOF {
        Issue.record("miniaudio did not report an I/O failure within the bounded read attempts")
    }
}

@Test(arguments: ["riff", "rf64", "flac"])
func truncatedAudioFilesReportUnexpectedEOF(container: String) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceExtension = container == "flac" ? "flac" : "wav"
    let sourceURL = directories.root.appending(path: "source.\(sourceExtension)")
    switch container {
    case "riff":
        try writePCM16Wave(
            to: sourceURL,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 288_000
        )
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: UInt64(44 + 144_000 * 2))
        try handle.close()
    case "rf64":
        try writeTruncatedRF64(to: sourceURL)
    case "flac":
        let fixtureURL = try #require(Bundle.module.url(
            forResource: "windows_audio_fixture",
            withExtension: "flac",
            subdirectory: "Resources"
        ))
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        try #require(fixtureBytes.count > 10_000)
        try Data(fixtureBytes.dropLast(1_024)).write(to: sourceURL)
    default:
        throw AudioImportError.unsupportedExtension(container)
    }

    let imported = try importFile(sourceURL, into: directories)
    let expectedMessage = "音声ファイルが宣言されたフレーム数より前に終了しました。"

    if container == "riff" {
        do {
            _ = try AudioImportDecoder(url: imported.originalURL, sessionURL: directories.sessionURL)
            Issue.record("Truncated RIFF input must fail during decoder creation")
        } catch let error as AudioImportError {
            guard case .unexpectedEOF = error else {
                Issue.record("Truncated RIFF input returned the wrong creation error: \(error)")
                return
            }
            #expect(error.errorDescription == expectedMessage)
        } catch {
            Issue.record("Truncated RIFF input returned the wrong creation error type: \(error)")
            return
        }
    } else {
        let decoder = try AudioImportDecoder(url: imported.originalURL, sessionURL: directories.sessionURL)
        var observedUnexpectedEOF = false

        for _ in 0..<40 {
            do {
                let samples = try decoder.readMono(frameCount: 8_192)
                if samples.isEmpty {
                    Issue.record("Truncated \(container.uppercased()) input reported clean EOF")
                    break
                }
            } catch let error as AudioImportError {
                guard case .unexpectedEOF = error else {
                    Issue.record("Truncated \(container.uppercased()) input returned the wrong error: \(error)")
                    break
                }
                observedUnexpectedEOF = true
                #expect(error.errorDescription == expectedMessage)

                do {
                    _ = try decoder.readMono(frameCount: 8_192)
                    Issue.record("Repeated read of truncated \(container.uppercased()) input did not retain its error")
                } catch let repeatedError as AudioImportError {
                    guard case .unexpectedEOF = repeatedError else {
                        Issue.record("Repeated read of truncated \(container.uppercased()) input returned the wrong error: \(repeatedError)")
                        break
                    }
                    #expect(repeatedError.errorDescription == expectedMessage)
                    #expect(repeatedError.errorDescription == error.errorDescription)
                } catch {
                    Issue.record("Repeated read of truncated \(container.uppercased()) input returned the wrong error type: \(error)")
                }
                break
            } catch {
                Issue.record("Truncated \(container.uppercased()) input returned the wrong error type: \(error)")
                break
            }
        }
        #expect(observedUnexpectedEOF)
    }

    do {
        _ = try await AudioFileTimelineBuilder().build(
            from: imported.originalURL,
            into: processingDirectory(for: directories),
            sessionURL: directories.sessionURL
        )
        Issue.record("Truncated \(container.uppercased()) input must fail with unexpected EOF")
    } catch let error as AudioImportError {
        guard case .unexpectedEOF = error else {
            Issue.record("Truncated \(container.uppercased()) input returned the wrong builder error: \(error)")
            return
        }
        #expect(error.errorDescription == expectedMessage)
    } catch {
        Issue.record("Truncated \(container.uppercased()) input returned the wrong builder error type: \(error)")
    }
}

@Test
func middleFLACSubframeHeaderCorruptionReturnsInvalidDataBeforePhysicalEOF() async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let fixtureURL = try #require(Bundle.module.url(
        forResource: "windows_audio_fixture",
        withExtension: "flac",
        subdirectory: "Resources"
    ))
    let fixtureBytes = try Data(contentsOf: fixtureURL)
    #expect(fixtureBytes.count == 15_259)

    // ffprobe の packet 境界は [8,256, 10,877)、[10,877, 13,498)、[13,498, 15,259)。
    for frameOffset in [8_256, 10_877, 13_498] {
        #expect(fixtureBytes[frameOffset] == 0xFF)
        #expect(fixtureBytes[frameOffset + 1] == 0xF8)
    }

    let corruptedHeaderOffset = 10_883
    #expect(fixtureBytes[corruptedHeaderOffset] == 0x4E)
    var corruptedBytes = fixtureBytes
    corruptedBytes[corruptedHeaderOffset] = 0xFF
    #expect(corruptedBytes.count == fixtureBytes.count)
    #expect(corruptedBytes.prefix(corruptedHeaderOffset) == fixtureBytes.prefix(corruptedHeaderOffset))
    #expect(corruptedBytes.suffix(from: corruptedHeaderOffset + 1) == fixtureBytes.suffix(from: corruptedHeaderOffset + 1))

    let sourceURL = directories.root.appending(path: "corrupt-middle-frame.flac")
    try corruptedBytes.write(to: sourceURL)
    try storageStore(for: directories).save(.importedOriginal(nil))
    let imported = try importFile(sourceURL, into: directories)
    #expect(try Data(contentsOf: imported.originalURL) == corruptedBytes)

    let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
    defer { try? sourceHandle.close() }
    let readFD = try duplicateCRTDescriptor(from: sourceHandle._handle, flags: _O_BINARY | _O_RDONLY)
    defer { _ = _close(readFD) }

    var ownedDecoder: OpaquePointer?
    defer {
        if let ownedDecoder { mja_decoder_destroy(ownedDecoder) }
    }
    var sampleRate: UInt32 = 0
    var channels: UInt32 = 0
    var length: UInt64 = 0
    let createResult = mja_decoder_create(readFD, MJA_DECODER_FORMAT_FLAC, &ownedDecoder, &sampleRate, &channels, &length)
    guard createResult == 0, let decoder = ownedDecoder else {
        Issue.record("FLAC デコーダーの作成に失敗しました（エラーコード: \(createResult)）。")
        return
    }
    #expect(sampleRate == 48_000)
    #expect(channels == 2)
    #expect(length == 12_288)

    // 先頭 frame の 4,608 samples を読み、次の read で破損 frame を検出する。
    let frameCapacity: UInt64 = 4_608
    var output = [Float](repeating: 0, count: Int(frameCapacity) * Int(channels))
    var framesRead: UInt64 = 0
    let firstResult = output.withUnsafeMutableBufferPointer { buffer in
        mja_decoder_read(decoder, buffer.baseAddress, frameCapacity, &framesRead)
    }
    #expect(firstResult == 0)
    #expect(framesRead == frameCapacity)

    framesRead = 0
    let corruptFrameResult = output.withUnsafeMutableBufferPointer { buffer in
        mja_decoder_read(decoder, buffer.baseAddress, frameCapacity, &framesRead)
    }
    // miniaudio 0.11.23 の MA_INVALID_DATA は -33。
    #expect(corruptFrameResult == -33)
    #expect(framesRead == 0)
    let filePosition = _lseeki64(readFD, 0, SEEK_CUR)
    #expect(filePosition == 12_352)
    #expect(filePosition < Int64(corruptedBytes.count))

    let expectedReadError = "音声ファイルのデコードに失敗しました: miniaudio の読み込みに失敗しました（エラーコード: -33）。"
    let swiftDecoder = try AudioImportDecoder(url: imported.originalURL, sessionURL: directories.sessionURL)
    let initialSamples = try swiftDecoder.readMono(frameCount: 4_608)
    #expect(initialSamples.count == 4_608)
    var firstReadErrorDescription: String?
    do {
        _ = try swiftDecoder.readMono(frameCount: 4_608)
        Issue.record("破損した FLAC の 2 回目の読み込みがエラーになりませんでした。")
    } catch let error as AudioImportError {
        guard case .decoderFailed(let context) = error else {
            Issue.record("破損した FLAC の読み込みで想定外のエラーが発生しました: \(error)")
            return
        }
        #expect(context == "miniaudio の読み込みに失敗しました（エラーコード: -33）。")
        firstReadErrorDescription = error.errorDescription
        #expect(firstReadErrorDescription == expectedReadError)
    } catch {
        Issue.record("破損した FLAC の読み込みで想定外のエラー型が発生しました: \(error)")
        return
    }

    do {
        _ = try swiftDecoder.readMono(frameCount: 4_608)
        Issue.record("破損した FLAC の再読み込みで保存済みエラーが返りませんでした。")
    } catch let error as AudioImportError {
        guard case .decoderFailed(let context) = error else {
            Issue.record("破損した FLAC の再読み込みで想定外のエラーが発生しました: \(error)")
            return
        }
        #expect(context == "miniaudio の読み込みに失敗しました（エラーコード: -33）。")
        #expect(error.errorDescription == expectedReadError)
        #expect(error.errorDescription == firstReadErrorDescription)
    } catch {
        Issue.record("破損した FLAC の再読み込みで想定外のエラー型が発生しました: \(error)")
        return
    }

    do {
        _ = try await AudioFileTimelineBuilder(readFrameCount: 4_608).build(
            from: imported.originalURL,
            into: processingDirectory(for: directories),
            sessionURL: directories.sessionURL
        )
        Issue.record("破損した FLAC のタイムライン構築がエラーになりませんでした。")
    } catch let error as AudioImportError {
        guard case .decoderFailed(let context) = error else {
            Issue.record("破損した FLAC のタイムライン構築で想定外のエラーが発生しました: \(error)")
            return
        }
        #expect(context == "miniaudio の読み込みに失敗しました（エラーコード: -33）。")
        #expect(error.errorDescription == expectedReadError)
    } catch {
        Issue.record("破損した FLAC のタイムライン構築で想定外のエラー型が発生しました: \(error)")
    }
    #expect(try Data(contentsOf: fixtureURL) == fixtureBytes)
}

@Test
func flacWithoutStreamInfoTotalSampleCountReportsLocalizedImportError() async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let fixtureURL = try #require(Bundle.module.url(
        forResource: "windows_audio_fixture",
        withExtension: "flac",
        subdirectory: "Resources"
    ))
    let fixtureBytes = try Data(contentsOf: fixtureURL)
    #expect(fixtureBytes.count > 26)
    #expect(Array(fixtureBytes.prefix(4)) == Array("fLaC".utf8))
    #expect(fixtureBytes[4] & 0x7F == 0)
    #expect(fixtureBytes[5] == 0)
    #expect(fixtureBytes[6] == 0)
    #expect(fixtureBytes[7] == 34)

    var unknownTotalSampleCountBytes = fixtureBytes
    unknownTotalSampleCountBytes[21] &= 0xF0
    unknownTotalSampleCountBytes.replaceSubrange(22..<26, with: repeatElement(UInt8.zero, count: 4))
    #expect(unknownTotalSampleCountBytes.count == fixtureBytes.count)
    #expect(unknownTotalSampleCountBytes[21] & 0x0F == 0)
    #expect(unknownTotalSampleCountBytes[22..<26].allSatisfy { $0 == 0 })
    #expect(unknownTotalSampleCountBytes.prefix(21) == fixtureBytes.prefix(21))
    #expect(unknownTotalSampleCountBytes.suffix(from: 26) == fixtureBytes.suffix(from: 26))

    let sourceURL = directories.root.appending(path: "unknown-total-sample-count.flac")
    try unknownTotalSampleCountBytes.write(to: sourceURL)
    try storageStore(for: directories).save(.importedOriginal(nil))
    let imported = try importFile(sourceURL, into: directories)
    #expect(try Data(contentsOf: imported.originalURL) == unknownTotalSampleCountBytes)

    let expectedMessage = "FLAC の総サンプル数が記録されていません。"
    do {
        _ = try AudioImportDecoder(url: imported.originalURL, sessionURL: directories.sessionURL)
        Issue.record("総サンプル数がない FLAC のデコーダー作成がエラーになりませんでした。")
    } catch let error as AudioImportError {
        guard case .missingTotalSampleCount = error else {
            Issue.record("総サンプル数がない FLAC のデコーダー作成で想定外のエラーが発生しました: \(error)")
            return
        }
        #expect(error.errorDescription == expectedMessage)
    } catch {
        Issue.record("総サンプル数がない FLAC のデコーダー作成で想定外のエラー型が発生しました: \(error)")
        return
    }

    do {
        _ = try await AudioFileTimelineBuilder().build(
            from: imported.originalURL,
            into: processingDirectory(for: directories),
            sessionURL: directories.sessionURL
        )
        Issue.record("総サンプル数がない FLAC のタイムライン構築がエラーになりませんでした。")
    } catch let error as AudioImportError {
        guard case .missingTotalSampleCount = error else {
            Issue.record("総サンプル数がない FLAC のタイムライン構築で想定外のエラーが発生しました: \(error)")
            return
        }
        #expect(error.errorDescription == expectedMessage)
    } catch {
        Issue.record("総サンプル数がない FLAC のタイムライン構築で想定外のエラー型が発生しました: \(error)")
    }
    #expect(try Data(contentsOf: fixtureURL) == fixtureBytes)
}

@Test(arguments: ["flac", "mp3", "m4a", "aac"])
func compressedFixturesBuildToTheirDecodedFrameBoundary(fileExtension: String) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let fixtureURL = try #require(Bundle.module.url(
        forResource: "windows_audio_fixture",
        withExtension: fileExtension,
        subdirectory: "Resources"
    ))
    let fixtureBytes = try Data(contentsOf: fixtureURL)
    try storageStore(for: directories).save(.importedOriginal(nil))
    let imported = try importFile(fixtureURL, into: directories)
    #expect(try Data(contentsOf: imported.originalURL) == fixtureBytes)

    let nativeExtent = try decodedNativeFrameExtent(
        from: imported.originalURL,
        sessionURL: directories.sessionURL
    )
    #expect(nativeExtent.frameCount > 0)
    if fileExtension == "flac" || fileExtension == "mp3" {
        #expect(nativeExtent.sampleRate == 48_000)
        #expect(nativeExtent.frameCount == 12_288)
    }
    if fileExtension == "m4a" || fileExtension == "aac" {
        #expect(nativeExtent.sampleRate == 48_000)
        #expect(nativeExtent.frameCount == 13_312)
        let nativeSignalOnset = try #require(nativeExtent.signalOnset)
        #expect(abs(nativeSignalOnset - 4_098) <= 4)
    }

    let processing = processingDirectory(for: directories)
    let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 97).build(
        from: imported.originalURL,
        into: processing,
        sessionURL: directories.sessionURL
    )
    let nativeBoundary = try CanonicalAudio.boundary(
        nativeExtent.frameCount,
        sampleRate: nativeExtent.sampleRate
    )
    #expect(checkpoint.committedFrames == nativeBoundary)
    if fileExtension == "flac" || fileExtension == "mp3" {
        #expect(checkpoint.committedFrames == 4_096)
    } else {
        #expect(checkpoint.committedFrames == 4_437)
    }
    #expect(checkpoint.sampleRate == CanonicalAudio.sampleRate)
    #expect(checkpoint.channelCount == CanonicalAudio.channelCount)
    #expect(checkpoint.sampleFormat == CanonicalAudio.sampleFormat)
    #expect(checkpoint.gapEvents.isEmpty)
    #expect(checkpoint.chunkFrameCounts.reduce(Int64.zero) { $0 + Int64($1) } == checkpoint.committedFrames)
    #expect(try AudioCheckpoint.loadRecovered(from: processing, relativeTo: directories.sessionURL) == checkpoint)

    let samples = try ProcessingTimelineReader(
        directory: processing,
        checkpoint: checkpoint,
        sessionURL: directories.sessionURL
    ).readSamples(frameRange: 0..<checkpoint.committedFrames)
    #expect(samples.allSatisfy { $0.isFinite })
    if fileExtension == "m4a" || fileExtension == "aac" {
        let nativeSignalOnset = try #require(nativeExtent.signalOnset)
        let canonicalSignalOnset = try #require(samples.firstIndex(where: { abs($0) > 0.05 }))
        #expect(abs(canonicalSignalOnset - 1_366) <= 2)
        print(
            "Measured .\(fileExtension) signal onsets: native=\(nativeSignalOnset), canonical=\(canonicalSignalOnset)"
        )
        let maximumSineError = (2_560..<4_096).reduce(Float.zero) { largest, frame in
            let sourceFrame = Double(frame) * 3 - 1_024
            let expected = Float(0.375 * sin(2 * Double.pi * 375 * sourceFrame / 48_000))
            return max(largest, abs(samples[frame] - expected))
        }
        #expect(maximumSineError < 0.06)
    } else {
        let interiorEnd = min(samples.count - 768, 4_096 - 768)
        #expect(interiorEnd > 768)
        let maximumSineError = (768..<interiorEnd).reduce(Float.zero) { largest, frame in
            let expected = Float(0.375 * sin(2 * Double.pi * 375 * Double(frame) / CanonicalAudio.sampleRate))
            return max(largest, abs(samples[frame] - expected))
        }
        #expect(maximumSineError < 0.06)
    }
    #expect(try Data(contentsOf: fixtureURL) == fixtureBytes)
    #expect(try Data(contentsOf: imported.originalURL) == fixtureBytes)
    #expect(try storageStore(for: directories).load() == .importedOriginal(nil))
}

@Test(arguments: ["ogg", ""])
func unsupportedExtensionsReportLocalizedImportErrors(fileExtension: String) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let filename = fileExtension.isEmpty ? "source-without-extension" : "source.\(fileExtension)"
    let sourceURL = directories.root.appending(path: filename)
    try Data("not audio".utf8).write(to: sourceURL)

    do {
        _ = try await AudioFileTimelineBuilder().build(
            from: sourceURL,
            into: processingDirectory(for: directories),
            sessionURL: directories.sessionURL
        )
        Issue.record("Unsupported extension \(fileExtension) must be rejected")
    } catch let error as AudioImportError {
        guard case .unsupportedExtension(let actualExtension) = error else {
            Issue.record("Unsupported input returned the wrong error case: \(error)")
            return
        }
        #expect(actualExtension == fileExtension)
        #expect(error.errorDescription?.contains("対応していない音声ファイル形式です") == true)
    } catch {
        Issue.record("Unsupported input returned the wrong error type: \(error)")
    }
}

@Test(arguments: ["wav", "flac", "mp3", "m4a", "aac"])
func corruptAudioFilesReportLocalizedDecoderErrors(fileExtension: String) async throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceURL = directories.root.appending(path: "corrupt.\(fileExtension)")
    try Data("corrupt audio bytes".utf8).write(to: sourceURL)
    let imported = try importFile(sourceURL, into: directories)

    do {
        _ = try await AudioFileTimelineBuilder().build(
            from: imported.originalURL,
            into: processingDirectory(for: directories),
            sessionURL: directories.sessionURL
        )
        Issue.record("Corrupt .\(fileExtension) input must fail decoding")
    } catch let error as AudioImportError {
        guard case .decoderFailed = error else {
            Issue.record("Corrupt .\(fileExtension) returned the wrong error case: \(error)")
            return
        }
        #expect(error.errorDescription?.contains("音声ファイルのデコードに失敗しました") == true)
    } catch {
        Issue.record("Corrupt .\(fileExtension) returned the wrong error type: \(error)")
    }
}

@Test
func decoderRejectsAnOriginalWhoseParentIsASymlink() throws {
    let directories = try ImportTestDirectories()
    defer { directories.cleanUp() }

    let sourceURL = directories.root.appending(path: "source.wav")
    try writePCM16Wave(to: sourceURL, sampleRate: 48_000, channelCount: 1, frameCount: 1_217)
    let originalBytes = try Data(contentsOf: sourceURL)
    let imported = try importFile(sourceURL, into: directories)

    let outsideAudioDirectory = directories.root
        .appending(path: "outside", directoryHint: .isDirectory)
        .appending(path: "audio", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outsideAudioDirectory, withIntermediateDirectories: true)
    let outsideOriginal = outsideAudioDirectory.appending(path: "original.wav")
    try originalBytes.write(to: outsideOriginal)

    let audioDirectory = directories.sessionURL.appending(path: "audio", directoryHint: .isDirectory)
    try FileManager.default.removeItem(at: audioDirectory)
    try FileManager.default.createSymbolicLink(at: audioDirectory, withDestinationURL: outsideAudioDirectory)

    let linkedOriginal = audioDirectory.appending(path: "original.wav")
    #expect(throws: CocoaError.self) {
        _ = try AudioImportDecoder(url: linkedOriginal, sessionURL: directories.sessionURL)
    }
    #expect(try Data(contentsOf: outsideOriginal) == originalBytes)
    #expect(imported.originalURL.lastPathComponent == linkedOriginal.lastPathComponent)
}
