import Foundation

public enum ClauseValidationError: LocalizedError, Sendable {
    case invalidReference, invalidCandidate, invalidNextHead, invalidProbability, invalidMetadata, invalidTargets

    public var errorDescription: String? { "Jev 判定データが不正です" }
}

private func isNonblank(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func isRequestLocalKey(_ key: String, prefix: Character) -> Bool {
    let bytes = key.utf8
    return bytes.count == 5 && key.first == prefix && bytes.dropFirst().allSatisfy { (48...57).contains($0) }
        && key.dropFirst() != "0000"
}

func isValidProbability(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }

// Two-decimal documentation examples allow 0.005 rounding per reported value.
// The API does not promise a precision; these are local acceptance limits.
private let choiceSumTolerance = 0.01 + 1e-12
private let choiceConfidenceTolerance = 0.015 + 1e-12

public struct SegmentTextReference: Codable, Sendable, Hashable {
    public let segmentationRunID: String
    public let segmentID: String
    public let asrRunID: String
    public let asrEventSeq: UInt64

    public init(segmentationRunID: String, segmentID: String, asrRunID: String, asrEventSeq: UInt64) throws {
        guard [segmentationRunID, segmentID, asrRunID].allSatisfy(isNonblank) else { throw ClauseValidationError.invalidReference }
        self.segmentationRunID = segmentationRunID
        self.segmentID = segmentID
        self.asrRunID = asrRunID
        self.asrEventSeq = asrEventSeq
    }

    enum CodingKeys: String, CodingKey {
        case segmentationRunID = "segmentation_run_id", segmentID = "segment_id", asrRunID = "asr_run_id", asrEventSeq = "asr_event_seq"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(segmentationRunID: c.decode(String.self, forKey: .segmentationRunID), segmentID: c.decode(String.self, forKey: .segmentID), asrRunID: c.decode(String.self, forKey: .asrRunID), asrEventSeq: c.decode(UInt64.self, forKey: .asrEventSeq))
    }
}

public struct ClauseBoundaryCandidate: Codable, Sendable, Equatable {
    public let id: String
    public let offsetUTF16: Int

    public init(id: String, offsetUTF16: Int) throws {
        let digits = id.utf8.dropFirst()
        guard id.first == "b", digits.count >= 4,
              digits.allSatisfy({ (48...57).contains($0) }),
              digits.contains(where: { $0 != 48 }),
              (digits.count == 4 || digits.first != 48),
              offsetUTF16 > 0 else { throw ClauseValidationError.invalidCandidate }
        self.id = id
        self.offsetUTF16 = offsetUTF16
    }
    public static func candidates(in text: String) throws -> [Self] {
        var result: [Self] = []
        var offset = 0
        let end = text.utf16.count
        for character in text {
            offset += character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
            if "、。？！?!".contains(character), offset < end {
                result.append(try Self(id: String(format: "b%04d", result.count + 1), offsetUTF16: offset))
            }
        }
        return result
    }
    enum CodingKeys: String, CodingKey { case id, offsetUTF16 = "offset_utf16" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), offsetUTF16: c.decode(Int.self, forKey: .offsetUTF16))
    }
}

public struct NextSegmentHead: Codable, Sendable, Equatable {
    public let source: SegmentTextReference
    public let text: String
    /// Seconds of silence from the end of the current segment to the start of this one, from `silenceSeconds`.
    public let silenceBeforeSeconds: Double

    /// Silence between two segments in seconds, rounded to one decimal; overlapping segments have none.
    public static func silenceSeconds(currentEndFrame: Int64, nextStartFrame: Int64) -> Double {
        (Double(max(0, nextStartFrame - currentEndFrame)) / CanonicalAudio.sampleRate * 10).rounded() / 10
    }

    public init(source: SegmentTextReference, text: String, silenceBeforeSeconds: Double) throws {
        guard !text.isEmpty, text.count <= ClauseBoundaryPolicy.nextHeadCharacterLimit,
              silenceBeforeSeconds.isFinite, silenceBeforeSeconds >= 0 else { throw ClauseValidationError.invalidNextHead }
        self.source = source
        self.text = text
        self.silenceBeforeSeconds = silenceBeforeSeconds
    }
    enum CodingKeys: String, CodingKey {
        case source, text, silenceBeforeSeconds = "silence_before_seconds"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            source: c.decode(SegmentTextReference.self, forKey: .source),
            text: c.decode(String.self, forKey: .text),
            silenceBeforeSeconds: c.decode(Double.self, forKey: .silenceBeforeSeconds)
        )
    }
}

public struct ClauseBoundaryRequest: Sendable, Equatable {
    public let source: SegmentTextReference
    public let text: String
    public let candidates: [ClauseBoundaryCandidate]
    public let next: NextSegmentHead?
    public init(source: SegmentTextReference, text: String, candidates: [ClauseBoundaryCandidate], next: NextSegmentHead?) throws {
        guard candidates == (try ClauseBoundaryCandidate.candidates(in: text)) else { throw ClauseValidationError.invalidCandidate }
        try Self.validateNext(next, for: source)
        self.source = source
        self.text = text
        self.candidates = candidates
        self.next = next
    }
    public init(source: SegmentTextReference, text: String, next: NextSegmentHead?) throws {
        try Self.validateNext(next, for: source)
        self.source = source
        self.text = text
        self.candidates = try ClauseBoundaryCandidate.candidates(in: text)
        self.next = next
    }
    private static func validateNext(_ next: NextSegmentHead?, for source: SegmentTextReference) throws {
        if let next {
            guard next.source.segmentationRunID == source.segmentationRunID,
                  next.source.asrRunID == source.asrRunID,
                  next.source.segmentID != source.segmentID,
                  next.source.asrEventSeq > source.asrEventSeq else { throw ClauseValidationError.invalidReference }
        }
    }
}

public struct JevResponseMetadata: Codable, Sendable, Equatable {
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public init(model: String, inputTokens: Int?, outputTokens: Int?) throws {
        guard isNonblank(model), inputTokens.map({ $0 >= 0 }) ?? true, outputTokens.map({ $0 >= 0 }) ?? true else { throw ClauseValidationError.invalidMetadata }
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
    enum CodingKeys: String, CodingKey { case model, inputTokens = "input_tokens", outputTokens = "output_tokens" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(model: c.decode(String.self, forKey: .model), inputTokens: c.decodeIfPresent(Int.self, forKey: .inputTokens), outputTokens: c.decodeIfPresent(Int.self, forKey: .outputTokens))
    }
}

public struct ClauseBoundaryResponse: Sendable, Equatable {
    public let probabilities: [String: Double]
    public let continuationProbability: Double?
    public let metadata: JevResponseMetadata
    public init(probabilities: [String: Double], continuationProbability: Double?, metadata: JevResponseMetadata) {
        self.probabilities = probabilities
        self.continuationProbability = continuationProbability
        self.metadata = metadata
    }
}

public struct PriorityTextTarget: Sendable, Equatable {
    public let key: String
    public let text: String
    public init(key: String, text: String) { self.key = key; self.text = text }
}

public struct ContentPriorityDecision: Codable, Sendable, Equatable {
    public let priority: ContentPriority
    public let confidence: Double
    public let probabilities: [String: Double]
    public init(priority: ContentPriority, confidence: Double, probabilities: [String: Double]) throws {
        guard isValidProbability(confidence), probabilities.count == 2,
              let primary = probabilities["PRIMARY"], let low = probabilities["LOW_PRIORITY"],
              isValidProbability(primary), isValidProbability(low),
              abs(primary + low - 1) <= choiceSumTolerance else {
            throw ClauseValidationError.invalidProbability
        }
        let selected = priority == .primary ? primary : low
        let maximum = max(primary, low)
        guard selected == maximum,
              abs(confidence - (2 * maximum - 1)) <= choiceConfidenceTolerance else {
            throw ClauseValidationError.invalidProbability
        }
        self.priority = priority
        self.confidence = confidence
        self.probabilities = probabilities
    }
    enum CodingKeys: String, CodingKey { case priority, confidence, probabilities }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(priority: c.decode(ContentPriority.self, forKey: .priority), confidence: c.decode(Double.self, forKey: .confidence), probabilities: c.decode([String: Double].self, forKey: .probabilities))
    }
}

public struct PriorityBatchResponse: Sendable, Equatable {
    public let decisions: [String: ContentPriorityDecision]
    public let metadata: JevResponseMetadata
    public init(decisions: [String: ContentPriorityDecision], metadata: JevResponseMetadata) { self.decisions = decisions; self.metadata = metadata }
}

public protocol DecisionProvider: Sendable {
    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse
    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse
}

public enum ClauseBoundaryPolicy {
    public static let boundaryThreshold = 0.5
    public static let continuationThreshold = 0.5
    public static let nextHeadCharacterLimit = 60
    public static func acceptsBoundary(_ probability: Double) -> Bool { probability > boundaryThreshold }
    public static func acceptsContinuation(_ probability: Double) -> Bool { probability > continuationThreshold }
}

public enum JevPriorityBatchPolicy { public static let maximumTargets = 40 }
