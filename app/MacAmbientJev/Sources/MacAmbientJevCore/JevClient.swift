import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JevClientError: LocalizedError, Sendable {
    case invalidResponse
    case invalidRequest
    case httpStatus(Int)
    case missingAnswer
    case invalidChoice
    case unexpectedAnswers

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Jev から有効な応答を受信できませんでした"
        case .invalidRequest: "Jev 判定リクエストが不正です"
        case .httpStatus(let status): "Jev API が HTTP \(status) を返しました"
        case .missingAnswer: "Jev の応答に必要な判定結果がありません"
        case .invalidChoice: "Jev の応答に未対応の選択肢が含まれています"
        case .unexpectedAnswers: "Jev の応答の判定対象が一致しません"
        }
    }
}

public protocol JevHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionJevHTTPTransport: JevHTTPTransport {
    private let session: URLSession
    public init(session: URLSession) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevClientError.invalidResponse }
        return (data, http)
    }
}

private struct JevQuestion: Encodable {
    let type: String
    let instructions: String
    let criteria: [String: String]
}

private struct JevRequest<State: Encodable>: Encodable {
    let model: String
    let state: State
    let questions: [String: JevQuestion]
}

private struct BoundaryState: Encodable {
    let text: String
    let nextText: String?
    let silenceBeforeNext: String?
    enum CodingKeys: String, CodingKey {
        case text, nextText = "next_text", silenceBeforeNext = "silence_before_next"
    }
}

private struct NoulAnswer: Decodable {
    let noul: Double
    enum CodingKeys: String, CodingKey { case type, noul }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "noul" else { throw JevClientError.invalidResponse }
        noul = try c.decode(Double.self, forKey: .noul)
        guard isValidProbability(noul) else { throw JevClientError.invalidResponse }
    }
}

private struct ChoiceAnswer: Decodable {
    let decision: ContentPriorityDecision
    enum CodingKeys: String, CodingKey { case type, choice, confidence, probabilities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "choice" else { throw JevClientError.invalidResponse }
        let priority: ContentPriority
        switch try c.decode(String.self, forKey: .choice) {
        case "PRIMARY": priority = .primary
        case "LOW_PRIORITY": priority = .lowPriority
        default: throw JevClientError.invalidChoice
        }
        decision = try ContentPriorityDecision(priority: priority, confidence: c.decode(Double.self, forKey: .confidence), probabilities: c.decode([String: Double].self, forKey: .probabilities))
    }
}

private struct JevUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
}

private struct JevEnvelope<Answer: Decodable>: Decodable {
    let answers: [String: Answer]
    let metadata: JevResponseMetadata
    enum CodingKeys: String, CodingKey { case model, answers, usage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let usage = try c.decode(JevUsage.self, forKey: .usage)
        metadata = try JevResponseMetadata(model: c.decode(String.self, forKey: .model), inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
        answers = try c.decode([String: Answer].self, forKey: .answers)
    }
}

public struct JevClient: DecisionProvider, Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let requestTimeout: TimeInterval = 15
    public static let model = "jev-latest"
    public static let priorityPromptRevision = "2"
    private let apiKey: String
    private let transport: any JevHTTPTransport

    public init(apiKey: String, transport: any JevHTTPTransport) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        guard !request.candidates.isEmpty || request.next != nil else { throw JevClientError.invalidRequest }
        // A frame absent from both raw inputs distinguishes inserted markers from spoken text.
        var frame = "⟨"
        while request.text.contains(frame) || request.next?.text.contains(frame) == true { frame += "⟨" }
        var marked = ""
        var questions: [String: JevQuestion] = [:]
        var previousOffset = 0
        var cursor = request.text.startIndex
        for (candidateIndex, candidate) in request.candidates.enumerated() {
            let endUTF16 = request.text.utf16.index(cursor, offsetBy: candidate.offsetUTF16 - previousOffset)
            guard let end = String.Index(endUTF16, within: request.text) else { throw JevClientError.invalidRequest }
            marked.append(contentsOf: request.text[cursor..<end])
            let marker = "\(frame)\(candidateIndex + 1)⟩"
            marked += marker
            questions[candidate.id] = JevQuestion(type: "noul", instructions: "`text` は講義などの話し言葉の文字起こしで、候補位置に印がある。印 `\(marker)` の直前で、文または独立した節が終わっていますか？判定対象は `text` だけで、`next_text` は継続質問専用。", criteria: [
                "true": "印の直前で文が終わる（「です」「ます」「ですね」「でしょうか」「わけです」などの文末）、または「けど」「が」「し」などで前の節が完結し、後ろが新しい文・節として始まる",
                "false": "文の途中。主語や目的語の後、連用・連体修飾、テ接続・条件・理由・引用の途中、言いよどみや言い直しの途中"
            ])
            previousOffset = candidate.offsetUTF16
            cursor = end
        }
        marked.append(contentsOf: request.text[cursor...])
        if request.next != nil {
            questions["continuation"] = JevQuestion(type: "noul", instructions: "`text` の末尾の部分と `next_text` の先頭は、録音の区切りで分かれた同じ節の続きですか？末尾の句点だけでは否定しない。「と。」「いうか」のように表現が続く可能性も判定してください。`silence_before_next` は `text` の末尾から `next_text` の先頭までの無音の秒数です。0 秒は、話し続けている途中を録音の長さ上限で機械的に区切ったことを示します。", criteria: [
                "true": "`text` の末尾は述語未完または表現の途中で、`next_text` の先頭がその節を継続する。`next_text` が「ですね」「ますので」「でしょうか」「ということです」のような語尾・助動詞・接続助詞から始まり、単独では文を始められない場合も、無音の長さにかかわらず継続",
                "false": "`text` の末尾で節が完結しており、`next_text` は主語・接続詞・フィラーなどから新しい節として始まる"
            ])
        }
        let body = JevRequest(model: Self.model, state: BoundaryState(
            text: marked,
            nextText: request.next?.text,
            silenceBeforeNext: request.next.map { String(format: "%.1f 秒", $0.silenceBeforeSeconds) }
        ), questions: questions)
        let response: JevEnvelope<NoulAnswer> = try await perform(body)
        var probabilities = response.answers.mapValues(\.noul)
        let continuation = probabilities.removeValue(forKey: "continuation")
        return ClauseBoundaryResponse(probabilities: probabilities, continuationProbability: continuation, metadata: response.metadata)
    }

    public func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        guard !targets.isEmpty, targets.count <= JevPriorityBatchPolicy.maximumTargets,
              Set(targets.map(\.key)).count == targets.count,
              targets.allSatisfy({ isRequestLocalKey($0.key, prefix: "u") && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw JevClientError.invalidRequest }
        var state: [String: String] = [:]
        var questions: [String: JevQuestion] = [:]
        for target in targets {
            state[target.key] = target.text
            questions["p" + target.key.dropFirst()] = JevQuestion(type: "choice", instructions: "`\(target.key)` について: この発話を文字起こし本文で通常表示する優先度として分類してください。他の key の本文は判定対象外です。", criteria: [
                "PRIMARY": "講義、議論、質問、回答、説明など、内容として保持すべき発話",
                "LOW_PRIORITY": "フィラー、相づち、言い直し断片など、意味内容が非常に小さい発話"
            ])
        }
        let response: JevEnvelope<ChoiceAnswer> = try await perform(JevRequest(model: Self.model, state: state, questions: questions))
        var decisions: [String: ContentPriorityDecision] = [:]
        for target in targets { decisions[target.key] = response.answers["p" + target.key.dropFirst()]!.decision }
        return PriorityBatchResponse(decisions: decisions, metadata: response.metadata)
    }

    private func perform<State: Encodable, Answer: Decodable>(_ body: JevRequest<State>) async throws -> JevEnvelope<Answer> {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw JevClientError.httpStatus(response.statusCode) }
        let decoded: JevEnvelope<Answer>
        do { decoded = try JSONDecoder().decode(JevEnvelope<Answer>.self, from: data) }
        catch let error as JevClientError { throw error }
        catch { throw JevClientError.invalidResponse }
        let requested = Set(body.questions.keys)
        let returned = Set(decoded.answers.keys)
        guard requested.isSubset(of: returned) else { throw JevClientError.missingAnswer }
        guard returned == requested else { throw JevClientError.unexpectedAnswers }
        return decoded
    }
}
