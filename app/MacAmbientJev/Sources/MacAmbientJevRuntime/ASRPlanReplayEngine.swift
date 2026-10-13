import Foundation
import MacAmbientJevCore

public enum ASRPlanReplayError: Error, LocalizedError, Equatable {
    case beginNotCalled
    case requestOutOfOrder(expectedID: String, sampleCount: Int, expectedSampleCount: Int)
    case tooManyRequests

    public var errorDescription: String? {
        switch self {
        case .beginNotCalled:
            "ASR プランの照合前に文字起こしが呼ばれました"
        case .requestOutOfOrder(let id, let count, let expected):
            "ASR リクエストが plan の順序と一致しません（次の id: \(id)、期待 \(expected) サンプル、入力 \(count) サンプル）"
        case .tooManyRequests:
            "plan にある数を超える ASR リクエストが来ました"
        }
    }
}

/// Answers each request with the text an external recognizer produced for the same plan.
public actor ASRPlanReplayEngine: ASREngine {
    nonisolated public let language: String? = ASRLanguage.japanese
    nonisolated public var provenance: RunProvenance {
        RunProvenance(engine: "asr-text-replay", model: nil, version: "1", configuration: [:])
    }

    private let plan: ASRPlan
    private let texts: ASRTexts
    private var verified = false
    private var nextIndex = 0

    /// - Throws: `ASRPlanError` when the texts' ids are not exactly the plan's ids.
    public init(planDirectory: URL, textsURL: URL) throws {
        let plan = try ASRPlan.load(directory: planDirectory)
        let texts = try ASRTexts(contentsOf: textsURL)
        try texts.requireIDs(of: plan)
        self.plan = plan
        self.texts = texts
    }

    public func prepare() async throws {}

    public func begin(plan recomputed: ASRPlan, audio: ASRAudioLoader) async throws {
        try plan.requireEqual(to: recomputed)
        verified = true
    }

    public func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard verified else { throw ASRPlanReplayError.beginNotCalled }
        guard !input.isShorterThanMinimumASRDuration else {
            return ASRResult(text: "", detectedLanguage: nil)
        }
        guard nextIndex < plan.requests.count else { throw ASRPlanReplayError.tooManyRequests }
        let request = plan.requests[nextIndex]
        let expected = Int(request.endSample - request.startSample)
        guard input.samples.count == expected else {
            throw ASRPlanReplayError.requestOutOfOrder(
                expectedID: request.id, sampleCount: input.samples.count, expectedSampleCount: expected
            )
        }
        nextIndex += 1
        guard let text = texts.textByID[request.id] else {
            preconditionFailure("every plan id has a text after init")
        }
        return ASRResult(text: text, detectedLanguage: nil)
    }

    public func unload() async {}
}
