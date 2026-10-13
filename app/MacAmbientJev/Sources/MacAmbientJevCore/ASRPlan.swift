import Foundation

public struct ASRPlanSpeaker: Codable, Sendable, Equatable {
    public let speakerID: String
    public let startSample: Int64
    public let endSample: Int64

    private enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id", startSample = "start_sample", endSample = "end_sample"
    }
}

public struct ASRPlanRequest: Codable, Sendable, Equatable {
    public let id: String
    public let startSample: Int64
    public let endSample: Int64
    public let language: String?
    /// Diarization spans overlapping the request, clipped to its sample range.
    public let speakers: [ASRPlanSpeaker]

    private enum CodingKeys: String, CodingKey {
        case id, language, speakers
        case startSample = "start_sample", endSample = "end_sample"
    }

    public var clipRelativePath: String { "clips/\(id).flac" }
}

public enum ASRPlanError: Error, LocalizedError, Equatable {
    case unreadablePlan(String)
    case unreadableTexts(String)
    case invalidTextLine(line: Int)
    case duplicateTextID(String)
    case missingTextIDs([String])
    case extraTextIDs([String])
    case planMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unreadablePlan(let reason):
            "ASR プランを読めません: \(reason)"
        case .unreadableTexts(let reason):
            "ASR テキストを読めません: \(reason)"
        case .invalidTextLine(let line):
            "ASR テキストの \(line) 行目が {\"id\": 文字列, \"text\": 文字列} の JSON ではありません"
        case .duplicateTextID(let id):
            "ASR テキストに id \(id) が重複しています"
        case .missingTextIDs(let ids):
            "ASR テキストに plan の id がありません: \(Self.preview(ids))"
        case .extraTextIDs(let ids):
            "ASR テキストに plan にない id があります: \(Self.preview(ids))"
        case .planMismatch(let detail):
            "再計算した ASR プランが plan.json と一致しません: \(detail)"
        }
    }

    private static func preview(_ ids: [String]) -> String {
        let shown = ids.prefix(5).joined(separator: ", ")
        return ids.count > 5 ? "\(shown) ほか \(ids.count - 5) 件" : shown
    }
}

/// Every ASR request of one recording, in transcription order. Requests shorter than the ASR
/// minimum are absent because engines answer them with empty text without recognizing them.
public struct ASRPlan: Codable, Sendable, Equatable {
    public static let fileName = "plan.json"

    public let sampleRate: Int
    public let bitDepth: Int
    public let requests: [ASRPlanRequest]

    private enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate", bitDepth = "bit_depth", requests
    }

    public init(
        segments: [SegmentReference],
        speakerSpans: [SpeakerSpan],
        sampleRate: Int,
        bitDepth: Int,
        language: String?
    ) {
        let minimum = Int64(ASRAudioInput.minimumSampleCount(sampleRate: sampleRate))
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.requests = segments.filter { $0.endFrame - $0.startFrame >= minimum }.map { segment in
            ASRPlanRequest(
                id: segment.segmentID,
                startSample: segment.startFrame,
                endSample: segment.endFrame,
                language: language,
                speakers: speakerSpans.compactMap { span in
                    let start = max(span.startFrame, segment.startFrame)
                    let end = min(span.endFrame, segment.endFrame)
                    return start < end
                        ? ASRPlanSpeaker(speakerID: span.speakerID, startSample: start, endSample: end)
                        : nil
                }
            )
        }
    }

    public static func load(directory: URL) throws -> ASRPlan {
        do {
            return try JSONDecoder().decode(
                ASRPlan.self, from: Data(contentsOf: directory.appending(path: fileName))
            )
        } catch {
            throw ASRPlanError.unreadablePlan(error.localizedDescription)
        }
    }

    public func write(directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }

    /// Throws `planMismatch` naming the first difference between `self` (the stored plan) and `recomputed`.
    public func requireEqual(to recomputed: ASRPlan) throws {
        guard self != recomputed else { return }
        if sampleRate != recomputed.sampleRate || bitDepth != recomputed.bitDepth {
            throw ASRPlanError.planMismatch(
                "形式が違います（plan.json: \(sampleRate) Hz / \(bitDepth) bit、再計算: \(recomputed.sampleRate) Hz / \(recomputed.bitDepth) bit）"
            )
        }
        guard requests.count == recomputed.requests.count else {
            throw ASRPlanError.planMismatch(
                "リクエスト数が違います（plan.json: \(requests.count)、再計算: \(recomputed.requests.count)）"
            )
        }
        for (index, (stored, fresh)) in zip(requests, recomputed.requests).enumerated() where stored != fresh {
            throw ASRPlanError.planMismatch(
                "\(index + 1) 番目が違います（plan.json: \(stored.id) \(stored.startSample)..<\(stored.endSample)、再計算: \(fresh.id) \(fresh.startSample)..<\(fresh.endSample)）"
            )
        }
    }
}

/// External recognition results for a plan: one `{"id": ..., "text": ...}` object per line.
public struct ASRTexts: Sendable, Equatable {
    public let textByID: [String: String]

    private struct Line: Decodable {
        let id: String
        let text: String
    }

    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ASRPlanError.unreadableTexts(error.localizedDescription)
        }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var textByID: [String: String] = [:]
        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            guard let parsed = try? decoder.decode(Line.self, from: Data(line)) else {
                throw ASRPlanError.invalidTextLine(line: index + 1)
            }
            guard textByID.updateValue(parsed.text, forKey: parsed.id) == nil else {
                throw ASRPlanError.duplicateTextID(parsed.id)
            }
        }
        self.textByID = textByID
    }

    /// Requires exactly the plan's ids.
    public func requireIDs(of plan: ASRPlan) throws {
        let planned = Set(plan.requests.map(\.id))
        let missing = plan.requests.map(\.id).filter { textByID[$0] == nil }
        guard missing.isEmpty else { throw ASRPlanError.missingTextIDs(missing) }
        let extra = textByID.keys.filter { !planned.contains($0) }.sorted()
        guard extra.isEmpty else { throw ASRPlanError.extraTextIDs(extra) }
    }
}
