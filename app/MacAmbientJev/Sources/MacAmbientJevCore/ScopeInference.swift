import Foundation

public enum ProximityDistanceHint: String, Codable, Sendable, Equatable {
    case near
    case distant
    case unknown
}

public struct ProximityEvidence: Codable, Sendable, Equatable {
    public let distanceHint: ProximityDistanceHint
    public let levelConfidence: Double?
    public let spectralConfidence: Double?

    public init(
        distanceHint: ProximityDistanceHint = .unknown,
        levelConfidence: Double? = nil,
        spectralConfidence: Double? = nil
    ) {
        self.distanceHint = distanceHint
        self.levelConfidence = levelConfidence
        self.spectralConfidence = spectralConfidence
    }

    public static let near = ProximityEvidence(
        distanceHint: .near,
        levelConfidence: 1,
        spectralConfidence: 1
    )

    public static let distant = ProximityEvidence(
        distanceHint: .distant
    )

    public static let unknown = ProximityEvidence()
}

public struct ScopeClassification: Sendable, Equatable {
    public let scope: AcousticScope
    public let confidence: Double

    public init(scope: AcousticScope, confidence: Double) {
        self.scope = scope
        self.confidence = confidence
    }
}

public struct ScopeClassifier: Sendable {
    public init() {}

    public func classify(
        evidence: ProximityEvidence,
        scene: SceneState
    ) -> ScopeClassification {
        let level = evidence.levelConfidence
        let spectral = evidence.spectralConfidence
        let combined = [level, spectral].compactMap { $0 }

        switch evidence.distanceHint {
        case .near:
            guard !combined.isEmpty else {
                return ScopeClassification(scope: .unknown, confidence: 0.4)
            }
            let confidence = combined.reduce(0, +) / Double(combined.count)
            return ScopeClassification(
                scope: confidence >= 0.6 ? .near : .unknown,
                confidence: confidence
            )

        case .distant:
            // Lecture mode is intentionally conservative: distance alone cannot
            // demote speech that may belong to the lecturer or classroom.
            guard scene == .discussion else {
                return ScopeClassification(scope: .unknown, confidence: 0.4)
            }
            guard level != nil, spectral != nil else {
                return ScopeClassification(scope: .unknown, confidence: 0.4)
            }

            let confidence = combined.reduce(0, +) / Double(combined.count)
            return ScopeClassification(
                scope: confidence >= 0.75 ? .background : .unknown,
                confidence: confidence
            )

        case .unknown:
            return ScopeClassification(scope: .unknown, confidence: 0)
        }
    }
}
