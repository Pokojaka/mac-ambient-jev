import Foundation

public enum ClauseEventType {
    public static let boundaryAssessed = "clause_boundaries.assessed"
    public static let boundaryPending = "clause_boundaries.pending"
    public static let clauseClosed = "clauses.closed"
    public static let priorityAssigned = "content_priority.assigned"
}

/// What each decision run records about the clause tagger and policy.
public enum DecisionRunProvenance {
    private static let unitPolicy = "btsj-utterance-sentence"
    private static let encodingRevision = "1"
    private static let maximumTokens = "192"
    private static let computeUnits = "cpu-only"

    public static func boundary(identity: DecisionModelIdentity) -> RunProvenance {
        var configuration = commonConfiguration(identity: identity)
        configuration["candidate_characters"] = "、。？！?!"
        configuration["boundary_threshold"] = String(ClauseBoundaryPolicy.boundaryThreshold)
        configuration["continuation_threshold"] = String(ClauseBoundaryPolicy.continuationThreshold)
        configuration["next_head_character_limit"] = String(ClauseBoundaryPolicy.nextHeadCharacterLimit)
        configuration["window_content_tokens"] = "190"
        configuration["window_policy"] = "whole-piece-max-min-context"
        configuration["span_policy"] = "argmax-o-f-d-b-remove-f-b"
        configuration["span_window_policy"] = "whole-piece-max-min-context"
        configuration["text_policy"] = "neutral-punctuation-piecewise"
        return RunProvenance(engine: identity.backend, model: identity.model, version: identity.modelRevision, configuration: configuration)
    }

    public static func priority(identity: DecisionModelIdentity) -> RunProvenance {
        var configuration = commonConfiguration(identity: identity)
        configuration["minimum_demotion_confidence"] = String(ContentPriorityPolicy.minimumDemotionConfidence)
        configuration["maximum_targets"] = String(PriorityBatchPolicy.maximumTargets)
        configuration["text_policy"] = "filler-backchannel-removed-neutral-punctuation-piecewise"
        return RunProvenance(engine: identity.backend, model: identity.model, version: identity.modelRevision, configuration: configuration)
    }

    /// A run whose tagger could not be loaded.
    public static func unavailable() -> RunProvenance {
        RunProvenance(engine: "unavailable", model: nil, version: "1", configuration: [
            "unit_policy": unitPolicy,
        ])
    }

    private static func commonConfiguration(identity: DecisionModelIdentity) -> [String: String] {
        [
            "model_id": identity.model,
            "model_revision": identity.modelRevision,
            "unit_policy": unitPolicy,
            "encoding_revision": encodingRevision,
            "max_tokens": maximumTokens,
            "compute_units": computeUnits,
        ]
    }
}

/// One boundary request for one source, or the pending state when it cannot be sent.
public enum ClauseBoundaryStep {
    public static func assess(
        source: SegmentTextReference,
        text: String,
        next: NextSegmentHead?,
        decisions: DecisionCoordinator
    ) async throws -> ClauseBoundaryState {
        let request = try ClauseBoundaryRequest(source: source, text: text, next: next)
        switch await decisions.assessBoundaries(request) {
        case .answered(let response, let record):
            return .assessed(try ClauseBoundaryAssessment(
                source: source, candidates: request.candidates, probabilities: response.probabilities,
                nextHead: next, continuationProbability: response.continuationProbability,
                fillerRanges: response.fillerRanges, request: record, sourceDecision: .assessed
            ))
        case .failed(let message):
            return .pending(reason: .requestFailed, message: message)
        case .cancelled:
            throw CancellationError()
        }
    }
}

public enum DecisionEnrichmentError: LocalizedError, Sendable, Equatable {
    case missingPublishedTranscript
    case invalidSourceTimeline
    case retryRequestFailed(String)
    case retryFailedDurably(String)
    case retryCompletionPersistenceFailed(original: String, persistence: String)
    case selectionConflict
    case selectionOutcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .selectionConflict:
            "判定の選択が別の処理で変更されたため、再試行の結果は選択しませんでした"
        case .selectionOutcomeUnknown(let reason):
            "判定の選択を保存できたか確認できません。セッションを開き直してください（\(reason)）"
        case .missingPublishedTranscript:
            "確定済みの文字起こしがありません"
        case .invalidSourceTimeline:
            "音声認識の原文区間、範囲、または順序が不正です"
        case .retryRequestFailed(let message):
            message
        case .retryFailedDurably(let message):
            message
        case .retryCompletionPersistenceFailed(let original, let persistence):
            "再試行の終了記録を保存できませんでした（元のエラー: \(original)、保存エラー: \(persistence)）"
        }
    }
}
