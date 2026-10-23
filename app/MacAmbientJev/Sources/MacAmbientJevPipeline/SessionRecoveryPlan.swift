import Foundation
import MacAmbientJevCore

/// How a session's recovery inspection is acted on. The CLI inspect and resume operations and the coordinator's
/// launch recovery and decision retry all route through it.
public enum SessionRecoveryPlan: Sendable, Equatable {
    case none
    case finalize
    case recoverDecisionRun(boundarySegments: [SegmentTextReference], clauses: [ClauseReference])
    case retryContentPriority(boundarySegments: [SegmentTextReference], clauses: [ClauseReference])

    public init(_ action: RecoverableProcessingAction?) {
        switch action {
        case nil: self = .none
        case .finalize?: self = .finalize
        case .recoverDecisionRun(let boundarySegments, let clauses)?:
            self = .recoverDecisionRun(boundarySegments: boundarySegments, clauses: clauses)
        case .retryContentPriority(let boundarySegments, let clauses)?:
            self = .retryContentPriority(boundarySegments: boundarySegments, clauses: clauses)
        }
    }

    public var inspectionName: String {
        switch self {
        case .none: "none"
        case .finalize: "finalize"
        case .recoverDecisionRun: "recoverDecisionRun"
        case .retryContentPriority: "retryContentPriority"
        }
    }

    public func requiresInference(withDecisions: Bool) -> Bool {
        switch self {
        case .finalize: true
        case .recoverDecisionRun, .retryContentPriority: withDecisions
        case .none: false
        }
    }

    /// What launch recovery enqueues. A published snapshot with pending results waits for the user's retry.
    public func launchRecoveryRequest(sessionID: UUID) -> PendingProcessing? {
        switch self {
        case .finalize: .finalize(sessionID: sessionID, metadataPolicy: .reject)
        case .recoverDecisionRun: decisionRetryRequest(sessionID: sessionID)
        case .retryContentPriority, .none: nil
        }
    }

    /// What the user's decision retry enqueues.
    public func decisionRetryRequest(sessionID: UUID) -> PendingProcessing? {
        switch self {
        case .recoverDecisionRun(let boundarySegments, let clauses),
             .retryContentPriority(let boundarySegments, let clauses):
            .retryContentPriority(sessionID: sessionID, boundarySegments: boundarySegments, clauses: clauses)
        case .finalize, .none:
            nil
        }
    }
}
