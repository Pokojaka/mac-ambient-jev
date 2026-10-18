/// Identity of the pinned model file. `scripts/fetch_silero_vad.py` downloads it and verifies
/// the SHA-256; `scripts/test_fetch_silero_vad.py` checks that these values equal the script's.
enum SileroVADModel {
    static let revision = "5cd7945676eb32225748052e2e6a0580e4686a08"
    static let filename = "silero_vad_16k_op15.onnx"
    static let sha256 = "7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49"
}
