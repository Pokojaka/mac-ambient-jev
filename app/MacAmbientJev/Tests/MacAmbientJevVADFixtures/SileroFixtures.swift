import Foundation

public enum SileroFixtureError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        }
    }
}

/// Locations of the Silero test inputs, resolved from this file so every test target and
/// platform reads the same copies.
public enum SileroTestInputs {
    private static let testsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let speechClipURL = testsDirectory
        .appendingPathComponent("MacAmbientJevONNXTests", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("silero_speech.wav")

    public static let parityFixtureURL = testsDirectory
        .appendingPathComponent("MacAmbientJevVADFixtures", isDirectory: true)
        .appendingPathComponent("vad_parity.json")

    /// The pinned model, from the path `scripts/fetch_silero_vad.py` printed.
    public static func modelURL(environment: [String: String]) throws -> URL {
        guard let path = environment["MAC_AMBIENT_JEV_SILERO_MODEL"], !path.isEmpty else {
            throw modelPathError("環境変数MAC_AMBIENT_JEV_SILERO_MODELが未設定または空です。")
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw modelPathError("指定されたSilero VADモデルファイルが存在しないか、通常ファイルではありません: \(url.path)。")
        }
        return url
    }

    /// The 4.5 s speech recording as 16 kHz mono samples.
    public static func speechClipSamples() throws -> [Float] {
        let bytes = [UInt8](try Data(contentsOf: speechClipURL))
        guard bytes.count >= 44 else {
            throw SileroFixtureError.invalid("silero_speech.wavのRIFF/WAVEヘッダーが44バイト未満です。")
        }
        guard fourCC(bytes, at: 0) == "RIFF",
              littleEndianUInt32(bytes, at: 4) == UInt32(bytes.count - 8),
              fourCC(bytes, at: 8) == "WAVE",
              fourCC(bytes, at: 12) == "fmt ",
              littleEndianUInt32(bytes, at: 16) == 16,
              littleEndianUInt16(bytes, at: 20) == 1,
              littleEndianUInt16(bytes, at: 22) == 1,
              littleEndianUInt32(bytes, at: 24) == 16_000,
              littleEndianUInt32(bytes, at: 28) == 32_000,
              littleEndianUInt16(bytes, at: 32) == 2,
              littleEndianUInt16(bytes, at: 34) == 16,
              fourCC(bytes, at: 36) == "data" else {
            throw SileroFixtureError.invalid("silero_speech.wavは44バイトの標準PCM16・モノラル・16kHz WAVE形式ではありません。")
        }

        let payloadByteCount = Int(littleEndianUInt32(bytes, at: 40))
        guard payloadByteCount == bytes.count - 44, payloadByteCount.isMultiple(of: 2) else {
            throw SileroFixtureError.invalid("silero_speech.wavのdataサイズがヘッダーと一致しません。")
        }
        return (0..<(payloadByteCount / 2)).map { sampleIndex in
            let value = Int16(bitPattern: littleEndianUInt16(bytes, at: 44 + sampleIndex * 2))
            return Float(value) / 32_768
        }
    }

    private static func modelPathError(_ reason: String) -> SileroFixtureError {
        .invalid("\(reason) \(fetchCommand)を実行し、取得されたモデルの絶対パスを環境変数MAC_AMBIENT_JEV_SILERO_MODELに設定してください。")
    }

    private static var fetchCommand: String {
        #if os(Windows)
        "python scripts/fetch_silero_vad.py"
        #else
        "python3 scripts/fetch_silero_vad.py"
        #endif
    }

    private static func fourCC(_ bytes: [UInt8], at offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func littleEndianUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
