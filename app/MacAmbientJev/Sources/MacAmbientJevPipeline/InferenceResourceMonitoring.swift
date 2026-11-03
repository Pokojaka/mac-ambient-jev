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

/// Memory-pressure holds for finalization: what to watch and how to free the models when a hold starts.
public struct InferenceResourceHolds: Sendable {
    public let monitor: any InferenceResourceMonitoring
    public let release: @Sendable () async -> Void

    public init(monitor: any InferenceResourceMonitoring, release: @escaping @Sendable () async -> Void) {
        self.monitor = monitor
        self.release = release
    }
}
