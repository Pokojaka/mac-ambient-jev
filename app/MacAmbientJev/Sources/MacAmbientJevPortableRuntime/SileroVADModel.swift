import Foundation
import MacAmbientJevCore

/// Identity of the pinned model file. `scripts/fetch_silero_vad.py` downloads it and verifies
/// the SHA-256; `scripts/test_fetch_silero_vad.py` checks that these values equal the script's.
public enum SileroVADModel {
    static let revision = "5cd7945676eb32225748052e2e6a0580e4686a08"
    static let filename = "silero_vad_16k_op15.onnx"
    static let sha256 = "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"

    public static func validate(at modelURL: URL) throws {
        let actual: String
        do {
            actual = try FileSHA256.hexDigest(ofFileAt: modelURL)
        } catch {
            throw SileroVADModelValidationError.unreadable(
                path: modelURL.path,
                reason: error.localizedDescription
            )
        }
        guard actual == sha256 else {
            throw SileroVADModelValidationError.hashMismatch(expected: sha256, actual: actual)
        }
    }
}

enum SileroVADModelValidationError: Error, LocalizedError {
    case unreadable(path: String, reason: String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(path, reason):
            return "Silero モデルを読み込めません: \(path) (\(reason))"
        case let .hashMismatch(expected, actual):
            return "Silero モデルの SHA-256 が一致しません: expected=\(expected), actual=\(actual)"
        }
    }
}
