import MacAmbientJevCore

public extension InferenceHoldReason {
    var liveExplanation: String {
        switch self {
        case .thermal: UserFacingStatus.liveTranscriptionThermalSuspended.text
        case .resourcePressure: "メモリ不足のためライブ認識を停止しました。録音は継続しています"
        case .monitorFailed: "リソース監視に失敗したためライブ認識を停止しました。録音は継続しています"
        }
    }

    var finalizationExplanation: String {
        switch self {
        case .thermal: UserFacingStatus.finalizationPausedForHeat.text
        case .resourcePressure: "メモリ不足のため確定処理を一時停止中"
        case .monitorFailed: "リソース監視に失敗したため確定処理を一時停止中"
        }
    }
}

public enum InferenceResourceSignal: Sendable, Equatable {
    case healthy, pressure, monitorFailed(String)

    public var holdReason: InferenceHoldReason? {
        switch self {
        case .healthy: nil
        case .pressure: .resourcePressure
        case .monitorFailed(_): .monitorFailed
        }
    }
}

public protocol InferenceResourceObservation: AnyObject {}

public protocol InferenceResourceMonitoring: Sendable {
    var signal: InferenceResourceSignal { get }
    @MainActor func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any InferenceResourceObservation
}

public struct InferenceMemoryFacts: Sendable, Equatable {
    public let physicalMemoryBytes: UInt64
    public let freePhysicalMemoryBytes: UInt64
    public let commitHeadroomBytes: UInt64
    public let lowMemorySignal: Bool

    public init(
        physicalMemoryBytes: UInt64,
        freePhysicalMemoryBytes: UInt64,
        commitHeadroomBytes: UInt64,
        lowMemorySignal: Bool
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.freePhysicalMemoryBytes = freePhysicalMemoryBytes
        self.commitHeadroomBytes = commitHeadroomBytes
        self.lowMemorySignal = lowMemorySignal
    }
}

public protocol InferenceMemoryProbing: Sendable {
    func memoryFacts() throws -> InferenceMemoryFacts
}
