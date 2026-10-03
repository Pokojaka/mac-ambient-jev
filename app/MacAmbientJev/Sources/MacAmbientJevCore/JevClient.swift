import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JevClientError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case missingAnswer(String)
    case invalidChoice(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Jev から有効な応答を受信できませんでした"
        case .httpStatus(let status):
            "Jev API が HTTP \(status) を返しました"
        case .missingAnswer(let key):
            "Jev の応答に \(key) の判定結果がありません"
        case .invalidChoice(let key):
            "Jev の応答に含まれる \(key) の選択肢が未対応です"
        }
    }
}

public protocol JevHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionJevHTTPTransport: JevHTTPTransport {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JevClientError.invalidResponse
        }
        return (data, http)
    }
}

private struct JevChoiceQuestion: Encodable {
    let type = "choice"
    let instructions: String
    let criteria: [String: String]
}

private struct JevRequest: Encodable {
    let model: String
    let state: String
    let questions: [String: JevChoiceQuestion]
}

private struct JevChoiceAnswer: Decodable {
    let type: String
    let choice: String
    let confidence: Double
    let probabilities: [String: Double]?
}

private struct JevUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct JevChoiceResponse: Decodable {
    let model: String?
    let answers: [String: JevChoiceAnswer]
    let usage: JevUsage?
}

public struct JevClient: DecisionProvider, Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let requestTimeout: TimeInterval = 15
    public static let model = "jev-latest"

    private let apiKey: String
    private let transport: any JevHTTPTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        apiKey: String,
        transport: any JevHTTPTransport
    ) {
        self.apiKey = apiKey
        self.transport = transport
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        let body = JevRequest(
            model: Self.model,
            state: text,
            questions: [
                "content_priority": JevChoiceQuestion(
                    instructions: "この発話を文字起こし本文で通常表示する優先度として分類してください。",
                    criteria: [
                        "PRIMARY": "講義、議論、質問、回答、説明など、内容として保持すべき発話",
                        "LOW_PRIORITY": "フィラー、相づち、言い直し断片など、意味内容が非常に小さい発話"
                    ]
                )
            ]
        )

        let response = try await perform(body)
        guard let answer = response.answers["content_priority"] else {
            throw JevClientError.missingAnswer("content_priority")
        }

        let priority: ContentPriority
        switch answer.choice {
        case "PRIMARY":
            priority = .primary
        case "LOW_PRIORITY":
            priority = .lowPriority
        default:
            throw JevClientError.invalidChoice("content_priority")
        }

        return ContentPriorityDecision(
            priority: priority,
            confidence: answer.confidence,
            model: response.model,
            inputTokens: response.usage?.inputTokens
        )
    }

    private func perform(
        _ body: JevRequest
    ) async throws -> JevChoiceResponse {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw JevClientError.httpStatus(response.statusCode)
        }

        let decoded: JevChoiceResponse
        do {
            decoded = try decoder.decode(JevChoiceResponse.self, from: data)
        } catch is DecodingError {
            throw JevClientError.invalidResponse
        }
        if let inputTokens = decoded.usage?.inputTokens, inputTokens < 0 {
            throw JevClientError.invalidResponse
        }
        return decoded
    }
}
