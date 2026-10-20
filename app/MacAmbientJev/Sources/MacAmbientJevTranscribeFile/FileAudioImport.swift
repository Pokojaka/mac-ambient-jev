import Foundation
import MacAmbientJevCore
#if os(Windows)
import MacAmbientJevWindowsSupport
#elseif os(Linux)
import CMiniaudio
#endif

private enum FileAudioImportError: LocalizedError {
    case unsupportedLinuxExtension(String)
    case linuxRequiresCanonicalAudio(sampleRate: UInt32, channels: UInt32)
    case invalidDecoderMetadata
    case decoderCreationFailed(Int32)
    case decoderReadFailed(Int32)
    case unexpectedNativeEOF(Int32)
    case prematureEOF(expected: Int64, actual: Int64)
    case excessFrames
    case invalidSamples
    case invalidTimeline

    var errorDescription: String? {
        switch self {
        case .unsupportedLinuxExtension(let fileExtension):
            let suffix = fileExtension.isEmpty ? "なし" : ".\(fileExtension)"
            return "Linux で対応していない音声ファイル形式です（拡張子: \(suffix)）。対応形式は WAV、FLAC、MP3 です。"
        case .linuxRequiresCanonicalAudio(let sampleRate, let channels):
            return "Linux の音声入力は既に 16 kHz・モノラルである必要があります（入力: \(sampleRate) Hz・\(channels) ch）。Linux ではサンプルレート変換やチャンネルミキシングを行いません。"
        case .invalidDecoderMetadata:
            return "音声デコーダーが不正な宣言フレーム数を返しました。"
        case .decoderCreationFailed(let code):
            return "音声デコーダーの作成に失敗しました（ネイティブエラーコード: \(code)）。"
        case .decoderReadFailed(let code):
            return "音声データの読み込みに失敗しました（ネイティブエラーコード: \(code)）。"
        case .unexpectedNativeEOF(let code):
            return "音声ファイルが宣言されたフレーム数より前に終了しました（ネイティブエラーコード: \(code)）。"
        case .prematureEOF(let expected, let actual):
            return "音声ファイルが宣言されたフレーム数より前に終了しました（宣言: \(expected)、読み込み済み: \(actual) フレーム）。"
        case .excessFrames:
            return "音声デコーダーが宣言フレーム数を超えるデータを返しました。"
        case .invalidSamples:
            return "音声デコーダーが有限値ではないサンプルを返しました。"
        case .invalidTimeline:
            return "処理用音声の長さまたは形式が正しくありません。"
        }
    }
}

/// Imports a pinned source file and builds its canonical processing timeline.
enum FileAudioImport {
    static func open(inputURL: URL, sessionURL: URL) async throws -> ProcessingTimelineReader {
        let imported = try AudioImporter().importFile(inputURL, into: sessionURL)
        let processingDirectory = sessionURL.appending(path: "processing", directoryHint: .isDirectory)

        #if os(Windows)
        let checkpoint = try await AudioFileTimelineBuilder(readFrameCount: 8_192).build(
            from: imported.originalURL,
            into: processingDirectory,
            sessionURL: sessionURL
        )
        return try validatedReader(
            directory: processingDirectory,
            checkpoint: checkpoint,
            sessionURL: sessionURL
        )
        #elseif os(Linux)
        let result = try await buildLinuxTimeline(
            from: imported.originalURL,
            into: processingDirectory,
            sessionURL: sessionURL
        )
        let reader = try validatedReader(
            directory: processingDirectory,
            checkpoint: result.checkpoint,
            sessionURL: sessionURL
        )
        guard reader.info.committedFrames == result.decodedFrames else {
            throw FileAudioImportError.invalidTimeline
        }
        return reader
        #endif
    }

    #if os(Linux)
    private static func buildLinuxTimeline(
        from sourceURL: URL,
        into processingDirectory: URL,
        sessionURL: URL
    ) async throws -> (checkpoint: AudioCheckpoint, decodedFrames: Int64) {
        let fileExtension = sourceURL.pathExtension.lowercased()
        let format: mja_decoder_format
        switch fileExtension {
        case "wav": format = MJA_DECODER_FORMAT_WAV
        case "flac": format = MJA_DECODER_FORMAT_FLAC
        case "mp3": format = MJA_DECODER_FORMAT_MP3
        default: throw FileAudioImportError.unsupportedLinuxExtension(fileExtension)
        }

        let handle = try SessionFileAccess.openHandle(sourceURL, relativeTo: sessionURL)
        var createdDecoder: OpaquePointer?
        var sampleRate: UInt32 = 0
        var channels: UInt32 = 0
        var declaredLength: UInt64 = 0
        let createResult = mja_decoder_create(
            handle.fileDescriptor,
            format,
            &createdDecoder,
            &sampleRate,
            &channels,
            &declaredLength
        )
        guard createResult == 0, let decoder = createdDecoder else {
            if let createdDecoder { mja_decoder_destroy(createdDecoder) }
            try? handle.close()
            throw FileAudioImportError.decoderCreationFailed(createResult)
        }
        // The decoder borrows this descriptor, so destroy it before closing the handle.
        defer {
            mja_decoder_destroy(decoder)
            try? handle.close()
        }

        guard declaredLength > 0, declaredLength <= UInt64(Int64.max) else {
            throw FileAudioImportError.invalidDecoderMetadata
        }
        guard sampleRate == 16_000, channels == 1 else {
            throw FileAudioImportError.linuxRequiresCanonicalAudio(
                sampleRate: sampleRate,
                channels: channels
            )
        }

        let expectedFrames = Int64(declaredLength)
        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            chunkDurationSeconds: 5,
            sessionURL: sessionURL
        )
        var decodedFrames: Int64 = 0
        var reachedEnd = false

        while !reachedEnd {
            var samples = [Float](repeating: 0, count: 8_192)
            var framesRead: UInt64 = 0
            let readResult = samples.withUnsafeMutableBufferPointer { buffer in
                mja_decoder_read(decoder, buffer.baseAddress, UInt64(buffer.count), &framesRead)
            }

            if readResult == MJA_DECODER_UNEXPECTED_EOF {
                throw FileAudioImportError.unexpectedNativeEOF(readResult)
            }
            guard readResult == 0 else {
                throw FileAudioImportError.decoderReadFailed(readResult)
            }
            guard framesRead <= UInt64(samples.count) else {
                throw FileAudioImportError.excessFrames
            }

            if framesRead == 0 {
                // The C wrapper normalizes MA_AT_END to success only at its declared length.
                guard decodedFrames == expectedFrames else {
                    throw FileAudioImportError.prematureEOF(
                        expected: expectedFrames,
                        actual: decodedFrames
                    )
                }
                reachedEnd = true
                continue
            }

            let readCount = Int(framesRead)
            guard samples[..<readCount].allSatisfy(\.isFinite) else {
                throw FileAudioImportError.invalidSamples
            }
            let (nextDecodedFrames, overflow) = decodedFrames.addingReportingOverflow(Int64(framesRead))
            guard !overflow else { throw FileAudioImportError.excessFrames }
            guard nextDecodedFrames <= expectedFrames else {
                throw FileAudioImportError.excessFrames
            }

            try await writer.append(samples: Array(samples[..<readCount]))
            decodedFrames = nextDecodedFrames
        }

        guard decodedFrames == expectedFrames else {
            throw FileAudioImportError.prematureEOF(expected: expectedFrames, actual: decodedFrames)
        }
        return (try await writer.finish(), decodedFrames)
    }
    #endif

    private static func validatedReader(
        directory: URL,
        checkpoint: AudioCheckpoint,
        sessionURL: URL
    ) throws -> ProcessingTimelineReader {
        let reader = try ProcessingTimelineReader(
            directory: directory,
            checkpoint: checkpoint,
            sessionURL: sessionURL
        )
        try reader.validateAudio()
        let info = reader.info
        guard info.committedFrames > 0,
              info.sampleRate == CanonicalAudio.sampleRate,
              info.channelCount == CanonicalAudio.channelCount else {
            throw FileAudioImportError.invalidTimeline
        }
        return reader
    }
}
