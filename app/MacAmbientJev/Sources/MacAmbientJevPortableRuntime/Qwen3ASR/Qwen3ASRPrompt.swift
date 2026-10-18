/// Token ids of the Qwen3-ASR chat template that the decoder graph consumes.
enum Qwen3ASRToken {
    static let imStart: Int64 = 151644
    static let imEnd: Int64 = 151645
    static let endOfText: Int64 = 151643
    static let audioStart: Int64 = 151669
    static let audioEnd: Int64 = 151670
    static let audioPad: Int64 = 151676
    static let asrText: Int64 = 151704
    static let system: Int64 = 8948
    static let user: Int64 = 872
    static let assistant: Int64 = 77091
    static let newline: Int64 = 198
    static let languageWord: Int64 = 11528
    static let japaneseWord: Int64 = 11937

    static let stopTokens: Set<Int64> = [imEnd, endOfText]
}

enum Qwen3ASRError: Error, Equatable, CustomStringConvertible {
    case invalidAudioTokenCount(Int)
    case tokenizerFileUnreadable(String)
    case tokenizerMalformed(String)
    case tokenizerUnsupported(String)
    case duplicateTokenID(Int64)
    case unknownTokenID(Int64)
    case invalidUTF8

    var description: String {
        switch self {
        case let .invalidAudioTokenCount(count):
            "audio token count must be positive: \(count)"
        case let .tokenizerFileUnreadable(reason):
            "tokenizer.json cannot be read: \(reason)"
        case let .tokenizerMalformed(reason):
            "tokenizer.json is malformed: \(reason)"
        case let .tokenizerUnsupported(reason):
            "tokenizer.json is not supported: \(reason)"
        case let .duplicateTokenID(id):
            "tokenizer.json assigns token id \(id) more than once"
        case let .unknownTokenID(id):
            "token id \(id) is not in the tokenizer"
        case .invalidUTF8:
            "decoded token bytes are not valid UTF-8"
        }
    }
}

/// The Japanese transcription prompt the Mac engine builds: the audio span is a run of
/// `<|audio_pad|>` ids that the decoder graph replaces with the encoder output at `audioOffset`.
struct Qwen3ASRPrompt: Equatable {
    static let audioOffset: Int64 = 9

    let tokenIDs: [Int64]

    init(audioTokenCount: Int) throws {
        guard audioTokenCount > 0 else { throw Qwen3ASRError.invalidAudioTokenCount(audioTokenCount) }
        let head: [Int64] = [
            Qwen3ASRToken.imStart, Qwen3ASRToken.system, Qwen3ASRToken.newline,
            Qwen3ASRToken.imEnd, Qwen3ASRToken.newline,
            Qwen3ASRToken.imStart, Qwen3ASRToken.user, Qwen3ASRToken.newline,
            Qwen3ASRToken.audioStart,
        ]
        let tail: [Int64] = [
            Qwen3ASRToken.audioEnd, Qwen3ASRToken.imEnd, Qwen3ASRToken.newline,
            Qwen3ASRToken.imStart, Qwen3ASRToken.assistant, Qwen3ASRToken.newline,
            Qwen3ASRToken.languageWord, Qwen3ASRToken.japaneseWord, Qwen3ASRToken.asrText,
        ]
        precondition(head.count == Int(Self.audioOffset), "audio offset must follow the audio start token")
        tokenIDs = head + [Int64](repeating: Qwen3ASRToken.audioPad, count: audioTokenCount) + tail
    }
}
