import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

public struct MacThermalMonitor: ThermalMonitoring {
    public init() {}

    public var state: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    public var pressure: ThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default:
            // Unknown thermal states are critical for live operation.
            return .critical
        }
    }

    public var isCritical: Bool {
        state == .critical
    }

    public var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }
}

public final class MacThermalStateObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    public init(center: NotificationCenter, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        // Apple requires reading thermalState before registering for thermalStateDidChangeNotification.
        _ = ProcessInfo.processInfo.thermalState
        token = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in onChange() }
    }

    deinit { center.removeObserver(token) }
}
