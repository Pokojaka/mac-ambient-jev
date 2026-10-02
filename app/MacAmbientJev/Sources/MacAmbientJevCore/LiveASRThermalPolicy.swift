import Foundation

public enum ThermalPressure: Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

public enum LiveASRThermalDecision: Sendable, Equatable {
    case processNow
    case wait(Duration)
    /// Live recognition stops; recording and segment registration continue, and finalization recognizes everything.
    case suspendUntilCooled
}

public enum LiveASRThermalPolicy {
    public static func decision(pressure: ThermalPressure) -> LiveASRThermalDecision {
        switch pressure {
        case .nominal, .fair:
            .processNow
        case .serious:
            .wait(.milliseconds(750))
        case .critical:
            .suspendUntilCooled
        }
    }
}
