import MacAmbientJevCore

public protocol ThermalStateObservation: AnyObject {}

public protocol ThermalMonitoring: Sendable {
    var isCritical: Bool { get }
    var liveASRDecision: LiveASRThermalDecision { get }
    @MainActor func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation
}

extension ThermalMonitoring {
    /// The thermal gate for each segment, for live and stored recognition alike. Critical returns `.thermal` at
    /// either point so the caller suspends or pauses; serious waits and rechecks only at dispatch.
    /// A cancelled wait throws `CancellationError`, and any other sleep error propagates.
    public func inferenceGate(
        at point: InferenceGatePoint, sleep: @Sendable (Duration) async throws -> Void
    ) async throws -> InferenceHoldReason? {
        switch liveASRDecision {
        case .processNow:
            return nil
        case .suspendUntilCooled:
            return .thermal
        case .wait(let delay):
            guard point == .dispatch else { return nil }
            try await sleep(delay)
            return liveASRDecision == .suspendUntilCooled ? .thermal : nil
        }
    }
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
