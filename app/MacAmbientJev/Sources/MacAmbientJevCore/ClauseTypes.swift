import Foundation

public enum ClauseValidationError: LocalizedError, Sendable {
    case invalidReference, invalidCandidate, invalidNextHead, invalidProbability, invalidMetadata, invalidTargets

    public var errorDescription: String? { "発話文判定データが不正です" }
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

/// The clause tagger's float32 softmax outputs sum to 1 within this tolerance.
public let taggerProbabilitySumTolerance = 1e-5

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
        let punctuation = "、。？！?!"
        let utf16Length: (Character) -> Int = { character in
            character.unicodeScalars.reduce(0) { $0 + ($1.value > 0xFFFF ? 2 : 1) }
        }
        let end = text.utf16.count
        var trailingRunStart = end
        for character in text.reversed() {
            guard punctuation.contains(character) else { break }
            trailingRunStart -= utf16Length(character)
        }

        var result: [Self] = []
        var offset = 0
        for character in text {
            offset += utf16Length(character)
            if punctuation.contains(character), offset < end, offset <= trailingRunStart {
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
    public init(source: SegmentTextReference, text: String) throws {
        guard !text.isEmpty, text.count <= ClauseBoundaryPolicy.nextHeadCharacterLimit else { throw ClauseValidationError.invalidNextHead }
        self.source = source
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case source, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: c.decode(SegmentTextReference.self, forKey: .source), text: c.decode(String.self, forKey: .text))
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

/// The loaded clause tagger: its external model ID and the 64-digit lowercase hex state-hash revision.
public struct DecisionModelIdentity: Sendable, Equatable {
    public let model: String
    public let modelRevision: String

    public init(model: String, modelRevision: String) throws {
        let revisionBytes = modelRevision.utf8
        guard isNonblank(model), revisionBytes.count == 64,
              revisionBytes.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ClauseValidationError.invalidMetadata
        }
        self.model = model
        self.modelRevision = modelRevision
    }
}

public struct ClauseBoundaryResponse: Sendable, Equatable {
    public let probabilities: [String: Double]
    public let continuationProbability: Double?
    /// Raw UTF-16 removal ranges for fillers (F) and backchannels (B), stored as filler_ranges.
    public let fillerRanges: [TextUTF16Range]
    /// Token count of every sequence the model ran for this request.
    public let inputTokens: Int
    public init(
        probabilities: [String: Double],
        continuationProbability: Double?,
        fillerRanges: [TextUTF16Range],
        inputTokens: Int
    ) {
        self.probabilities = probabilities
        self.continuationProbability = continuationProbability
        self.fillerRanges = fillerRanges
        self.inputTokens = inputTokens
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
              abs(primary + low - 1) <= taggerProbabilitySumTolerance else {
            throw ClauseValidationError.invalidProbability
        }
        let selected = priority == .primary ? primary : low
        let maximum = max(primary, low)
        guard selected == maximum, confidence == 2 * maximum - 1 else {
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
    /// Token count of every sequence the model ran for this request.
    public let inputTokens: Int
    public init(decisions: [String: ContentPriorityDecision], inputTokens: Int) { self.decisions = decisions; self.inputTokens = inputTokens }
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

public enum PriorityBatchPolicy { public static let maximumTargets = 40 }
