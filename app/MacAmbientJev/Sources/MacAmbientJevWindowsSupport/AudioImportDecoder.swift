import CMiniaudio
import CWindowsAudio
import Foundation
import MacAmbientJevCore
import WinSDK
import ucrt

public enum AudioImportError: LocalizedError {
    case unsupportedExtension(String)
    case decoderFailed(String)
    case unexpectedEOF
    case missingTotalSampleCount
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let fileExtension):
            let extensionDescription = fileExtension.isEmpty ? "なし" : ".\(fileExtension)"
            return "対応していない音声ファイル形式です（拡張子: \(extensionDescription)）。対応形式は WAV、FLAC、MP3、M4A、AAC です。"
        case .decoderFailed(let context):
            return "音声ファイルのデコードに失敗しました: \(context)"
        case .unexpectedEOF:
            return "音声ファイルが宣言されたフレーム数より前に終了しました。"
        case .missingTotalSampleCount:
            return "FLAC の総サンプル数が記録されていません。"
        case .emptyAudio:
            return "音声ファイルにデコード可能な音声データがありません。"
        }
    }
}

/// Decodes bounded interleaved-float chunks from a session-pinned source handle.
/// Native formats use miniaudio 0.11.23: https://github.com/mackron/miniaudio/releases/tag/0.11.23
final class AudioImportDecoder {
    private enum Format {
        case miniaudio(mja_decoder_format)
        case mediaFoundation(isADTS: Int32)
    }

    private enum Backend {
        case miniaudio(OpaquePointer, frameCount: Int64)
        case mediaFoundation(OpaquePointer)
    }

    let sampleRate: Double
    let channelCount: Int

    private let handle: FileHandle
    private let descriptor: Int32
    private let backend: Backend
    private var decodedFrameCount: Int64 = 0
    private var reachedEOF = false
    private var terminalError: (any Error)?
    /// Keeps the decoded-frame range named by an M4A's edit list or `iTunSMPB`; without a window it keeps every frame.
    private var trimCursor: AACTrimCursor

    init(url: URL, sessionURL: URL) throws {
        let fileExtension = url.pathExtension.lowercased()
        let format: Format
        switch fileExtension {
        case "wav": format = .miniaudio(MJA_DECODER_FORMAT_WAV)
        case "flac": format = .miniaudio(MJA_DECODER_FORMAT_FLAC)
        case "mp3": format = .miniaudio(MJA_DECODER_FORMAT_MP3)
        case "m4a": format = .mediaFoundation(isADTS: 0)
        case "aac": format = .mediaFoundation(isADTS: 1)
        default: throw AudioImportError.unsupportedExtension(fileExtension)
        }

        let priming: MP4Priming
        if case .mediaFoundation(isADTS: 0) = format {
            // A separate handle: the decoder's stream and this parser must not share a file position.
            let primingHandle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
            defer { try? primingHandle.close() }
            do {
                priming = try MP4PrimingParser.parse(MP4FileHandleSource(handle: primingHandle))
            } catch let error as MP4PrimingError {
                throw AudioImportError.decoderFailed(error.localizedDescription)
            }
        } else {
            priming = .none
        }

        let openedHandle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
        var keepHandle = false
        var ownedDescriptor: Int32? = nil
        defer {
            if !keepHandle {
                if let ownedDescriptor { _close(ownedDescriptor) }
                try? openedHandle.close()
            }
        }

        var duplicate: HANDLE? = nil
        guard DuplicateHandle(
            GetCurrentProcess(),
            openedHandle._handle,
            GetCurrentProcess(),
            &duplicate,
            0,
            false,
            DWORD(DUPLICATE_SAME_ACCESS)
        ), let duplicate else {
            throw AudioImportError.decoderFailed(
                "Windows ハンドルの複製に失敗しました（エラーコード: \(GetLastError())）。"
            )
        }

        let decoderDescriptor = _open_osfhandle(Int(bitPattern: duplicate), _O_BINARY | _O_RDONLY)
        guard decoderDescriptor >= 0 else {
            let code = errno
            _ = CloseHandle(duplicate)
            throw AudioImportError.decoderFailed(
                "Windows ハンドルから CRT ファイル記述子への変換に失敗しました（errno: \(code)）。"
            )
        }
        ownedDescriptor = decoderDescriptor

        switch format {
        case .miniaudio(let nativeFormat):
            var createdDecoder: OpaquePointer?
            var rate: UInt32 = 0
            var channels: UInt32 = 0
            var length: UInt64 = 0
            let result = mja_decoder_create(
                decoderDescriptor,
                nativeFormat,
                &createdDecoder,
                &rate,
                &channels,
                &length
            )
            if result == MJA_DECODER_MISSING_TOTAL_SAMPLE_COUNT {
                if let createdDecoder { mja_decoder_destroy(createdDecoder) }
                throw AudioImportError.missingTotalSampleCount
            }
            if result == MJA_DECODER_UNEXPECTED_EOF {
                if let createdDecoder { mja_decoder_destroy(createdDecoder) }
                throw AudioImportError.unexpectedEOF
            }
            guard result == 0, let createdDecoder else {
                if let createdDecoder { mja_decoder_destroy(createdDecoder) }
                throw AudioImportError.decoderFailed("miniaudio のデコーダー作成に失敗しました（エラーコード: \(result)）。")
            }
            guard rate > 0, channels > 0, channels <= 254,
                  length > 0, length <= UInt64(Int64.max) else {
                mja_decoder_destroy(createdDecoder)
                throw AudioImportError.decoderFailed("miniaudio が不正なサンプルレート、チャンネル数、または宣言フレーム数を返しました。")
            }

            self.trimCursor = AACTrimCursor(window: nil)
            self.sampleRate = Double(rate)
            self.channelCount = Int(channels)
            self.backend = .miniaudio(createdDecoder, frameCount: Int64(length))

        case .mediaFoundation(let isADTS):
            var createdDecoder: OpaquePointer?
            var rate: UInt32 = 0
            var channels: UInt32 = 0
            let result = mja_mf_decoder_create(
                decoderDescriptor,
                isADTS,
                &createdDecoder,
                &rate,
                &channels
            )
            guard result == 0, let createdDecoder else {
                if let createdDecoder { mja_mf_decoder_destroy(createdDecoder) }
                throw AudioImportError.decoderFailed("Media Foundation の AAC デコーダー作成に失敗しました（HRESULT: \(result)）。")
            }
            guard rate > 0, channels > 0, channels <= 254 else {
                mja_mf_decoder_destroy(createdDecoder)
                throw AudioImportError.decoderFailed("Media Foundation が不正なサンプルレートまたはチャンネル数を返しました。")
            }

            do {
                self.trimCursor = AACTrimCursor(window: try priming.window(sampleRate: rate))
            } catch let error as MP4PrimingError {
                mja_mf_decoder_destroy(createdDecoder)
                throw AudioImportError.decoderFailed(error.localizedDescription)
            }
            self.sampleRate = Double(rate)
            self.channelCount = Int(channels)
            self.backend = .mediaFoundation(createdDecoder)
        }

        self.handle = openedHandle
        self.descriptor = decoderDescriptor
        keepHandle = true
    }

    deinit {
        switch backend {
        case .miniaudio(let decoder, frameCount: _): mja_decoder_destroy(decoder)
        case .mediaFoundation(let decoder): mja_mf_decoder_destroy(decoder)
        }
        _close(descriptor)
        try? handle.close()
    }

    func readMono(frameCount: Int) throws -> [Float] {
        if let terminalError { throw terminalError }
        guard (1...8_192).contains(frameCount) else {
            throw CanonicalAudioError.invalidSourceFormat
        }
        if reachedEOF { return [] }

        do {
            let (sampleCapacity, capacityOverflow) = frameCount.multipliedReportingOverflow(by: channelCount)
            guard !capacityOverflow else {
                throw AudioImportError.decoderFailed("デコード用バッファのサイズが上限を超えました。")
            }
            var interleaved = [Float](repeating: 0, count: sampleCapacity)

            switch backend {
            case .miniaudio(let decoder, frameCount: let expectedFrameCount):
                return try readMiniaudio(
                    decoder,
                    frameCount: expectedFrameCount,
                    into: &interleaved,
                    requestedFrameCount: frameCount
                )
            case .mediaFoundation(let decoder):
                return try readMediaFoundation(
                    decoder,
                    into: &interleaved,
                    requestedFrameCount: frameCount
                )
            }
        } catch {
            terminalError = error
            throw error
        }
    }

    private func readMiniaudio(
        _ decoder: OpaquePointer,
        frameCount expectedFrameCount: Int64,
        into interleaved: inout [Float],
        requestedFrameCount: Int
    ) throws -> [Float] {
        let request: Int
        if decodedFrameCount < expectedFrameCount {
            request = min(requestedFrameCount, Int(expectedFrameCount - decodedFrameCount))
        } else {
            // Probe beyond the declared extent; miniaudio must report a clean zero-frame EOF.
            request = 1
        }

        var framesRead: UInt64 = 0
        let result = interleaved.withUnsafeMutableBufferPointer { output in
            mja_decoder_read(decoder, output.baseAddress, UInt64(request), &framesRead)
        }
        if result == MJA_DECODER_UNEXPECTED_EOF {
            throw AudioImportError.unexpectedEOF
        }
        guard result == 0 else {
            throw AudioImportError.decoderFailed("miniaudio の読み込みに失敗しました（エラーコード: \(result)）。")
        }
        guard framesRead <= UInt64(request) else {
            throw AudioImportError.decoderFailed("miniaudio が要求数を超えるフレームを返しました。")
        }

        if decodedFrameCount == expectedFrameCount {
            guard framesRead == 0 else {
                throw AudioImportError.decoderFailed("miniaudio が宣言フレーム数を超える音声データを返しました。")
            }
            reachedEOF = true
            return []
        }

        guard framesRead > 0 else { throw AudioImportError.unexpectedEOF }
        let (nextDecodedFrameCount, overflow) = decodedFrameCount.addingReportingOverflow(Int64(framesRead))
        guard !overflow, nextDecodedFrameCount <= expectedFrameCount else {
            throw AudioImportError.decoderFailed("miniaudio の累積フレーム数が宣言値を超えました。")
        }
        decodedFrameCount = nextDecodedFrameCount
        return try downmix(interleaved, frameCount: Int(framesRead))
    }

    private func readMediaFoundation(
        _ decoder: OpaquePointer,
        into interleaved: inout [Float],
        requestedFrameCount: Int
    ) throws -> [Float] {
        while true {
            var framesRead: UInt32 = 0
            let result = interleaved.withUnsafeMutableBufferPointer { output in
                mja_mf_decoder_read(
                    decoder,
                    output.baseAddress,
                    UInt32(requestedFrameCount),
                    &framesRead
                )
            }
            guard result == 0 else {
                throw AudioImportError.decoderFailed("Media Foundation の読み込みに失敗しました（HRESULT: \(result)）。")
            }
            guard framesRead <= UInt32(requestedFrameCount) else {
                throw AudioImportError.decoderFailed("Media Foundation が要求数を超えるフレームを返しました。")
            }

            guard framesRead > 0 else {
                if trimCursor.window != nil {
                    do {
                        try trimCursor.finish()
                    } catch let error as MP4PrimingError {
                        throw AudioImportError.decoderFailed(error.localizedDescription)
                    }
                } else {
                    guard decodedFrameCount > 0 else { throw AudioImportError.emptyAudio }
                }
                reachedEOF = true
                return []
            }
            let kept: Range<Int>
            do {
                kept = try trimCursor.accept(frameCount: Int(framesRead))
            } catch let error as MP4PrimingError {
                throw AudioImportError.decoderFailed(error.localizedDescription)
            }
            decodedFrameCount = trimCursor.decodedFrames
            if trimCursor.isComplete { reachedEOF = true }
            if !kept.isEmpty {
                return try downmix(
                    Array(interleaved[kept.lowerBound * channelCount..<kept.upperBound * channelCount]),
                    frameCount: kept.count
                )
            }
            if reachedEOF { return [] }
        }
    }

    private func downmix(_ interleaved: [Float], frameCount: Int) throws -> [Float] {
        try ImportedAudioPCM.downmix(
            frameCount: frameCount,
            channelCount: channelCount,
            sample: { frame, channel in interleaved[frame * channelCount + channel] }
        )
    }
}
