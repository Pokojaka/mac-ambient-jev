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
}

public enum LiveASRThermalPolicy {
    public static func decision(
        pressure: ThermalPressure,
        pendingCount: Int,
        oldestPendingAge: TimeInterval
    ) -> LiveASRThermalDecision {
        guard pendingCount > 0, oldestPendingAge < 30 else {
            return .processNow
        }

        switch pressure {
        case .nominal, .fair:
            return .processNow
        case .serious:
            return .wait(.milliseconds(750))
        case .critical:
            return .wait(.seconds(2))
        }
    }
}
