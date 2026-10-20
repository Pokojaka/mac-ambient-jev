import MacAmbientJevCore

public protocol ThermalMonitoring: Sendable {
    var isCritical: Bool { get }
    var liveASRDecision: LiveASRThermalDecision { get }
}

public struct WindowsNoThermalMonitoring: ThermalMonitoring {
    public init() {}

    public var isCritical: Bool { false }
    public var liveASRDecision: LiveASRThermalDecision { .processNow }
}
