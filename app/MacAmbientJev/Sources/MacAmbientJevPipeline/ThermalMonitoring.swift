import MacAmbientJevCore

public protocol ThermalStateObservation: AnyObject {}

public protocol ThermalMonitoring: Sendable {
    var isCritical: Bool { get }
    var liveASRDecision: LiveASRThermalDecision { get }
    @MainActor func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation
}

public struct WindowsNoThermalMonitoring: ThermalMonitoring {
    public init() {}

    public var isCritical: Bool { false }
    public var liveASRDecision: LiveASRThermalDecision { .processNow }

    @MainActor
    public func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        WindowsNoThermalStateObservation()
    }
}

private final class WindowsNoThermalStateObservation: ThermalStateObservation {}
