import Foundation

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

    public init(session: URLSession = .shared) {
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

private struct JevPriorityRequest: Encodable {
    let model: String
    let state: String
    let questions: [String: JevChoiceQuestion]
}

private struct JevSceneStatePayload: Encodable {
    let currentText: String
    let previousTexts: [String]
    let currentScene: String

    enum CodingKeys: String, CodingKey {
        case currentText = "current_text"
        case previousTexts = "previous_texts"
        case currentScene = "current_scene"
    }
}

private struct JevSceneRequest: Encodable {
    let model: String
    let state: JevSceneStatePayload
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

    private let apiKey: String
    private let model: String
    private let transport: any JevHTTPTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        apiKey: String,
        model: String = "jev-latest",
        transport: any JevHTTPTransport = URLSessionJevHTTPTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func classifyPriority(text: String) async throws -> ContentPriorityDecision {
        let body = JevPriorityRequest(
            model: model,
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

    public func classifySceneCue(
        currentText: String,
        previousTexts: [String],
        currentScene: SceneState
    ) async throws -> SemanticSceneDecision {
        let body = JevSceneRequest(
            model: model,
            state: JevSceneStatePayload(
                currentText: currentText,
                previousTexts: Array(previousTexts.suffix(3)),
                currentScene: currentScene.rawValue
            ),
            questions: [
                "scene_cue": JevChoiceQuestion(
                    instructions: "発話内容から場面転換の補助 cue を判定してください。音響判定を置き換えず、明示的な転換だけを選んでください。",
                    criteria: [
                        "discussion_start": "講義から複数人の議論や質疑へ移ることを明示している",
                        "discussion_end": "議論や質疑を終えて講義へ戻ることを明示している",
                        "none": "場面転換を明示していない、または判断できない"
                    ]
                )
            ]
        )

        let response = try await perform(body)
        guard let answer = response.answers["scene_cue"] else {
            throw JevClientError.missingAnswer("scene_cue")
        }
        guard let cue = SemanticSceneCue(rawValue: answer.choice) else {
            throw JevClientError.invalidChoice("scene_cue")
        }

        return SemanticSceneDecision(
            cue: cue,
            confidence: answer.confidence,
            model: response.model,
            inputTokens: response.usage?.inputTokens
        )
    }

    private func perform<Body: Encodable & Sendable>(
        _ body: Body
    ) async throws -> JevChoiceResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw JevClientError.httpStatus(response.statusCode)
        }

        return try decoder.decode(JevChoiceResponse.self, from: data)
    }
}
