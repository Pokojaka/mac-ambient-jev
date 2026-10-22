import Foundation

public enum ClauseTaggerModelError: LocalizedError, Sendable {
    case unavailable(String)
    case invalidModel(String)
    case invalidInput
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "ローカル発話文モデルを利用できません: \(detail)"
        case .invalidModel(let detail):
            return "ローカル発話文モデルが不正です: \(detail)"
        case .invalidInput:
            return "ローカル発話文モデルへの入力が不正です。"
        case .invalidOutput:
            return "ローカル発話文モデルの出力が不正です。"
        }
    }
}

public struct ClauseTaggerModelIdentity: Sendable, Equatable {
    public let decisionIdentity: DecisionModelIdentity
    public let tokenizerSHA256: String

    public var modelID: String { decisionIdentity.model }
    public var revision: String { decisionIdentity.modelRevision }

    public init(modelID: String, revision: String, tokenizerSHA256: String) throws {
        let decisionIdentity: DecisionModelIdentity
        do {
            decisionIdentity = try DecisionModelIdentity(model: modelID, modelRevision: revision)
        } catch ClauseValidationError.invalidMetadata {
            throw ClauseTaggerModelError.invalidModel("モデルメタデータが発話文モデルの仕様に一致しません。")
        }
        self.decisionIdentity = decisionIdentity
        self.tokenizerSHA256 = tokenizerSHA256
    }
}

public struct ClauseTaggerPrediction: Sendable {
    public let boundaryProbabilities: [[Double]]
    public let spanProbabilities: [[Double]]
    public let priorityProbabilities: [Double]

    public init(
        boundaryProbabilities: [[Double]],
        spanProbabilities: [[Double]],
        priorityProbabilities: [Double]
    ) {
        self.boundaryProbabilities = boundaryProbabilities
        self.spanProbabilities = spanProbabilities
        self.priorityProbabilities = priorityProbabilities
    }
}
