import Synchronization
import MacAmbientJevCore
import MacAmbientJevPipeline

final class TestThermalMonitor: ThermalMonitoring {
    private let storage: Mutex<ThermalPressure>

    init(_ pressure: ThermalPressure) {
        storage = Mutex(pressure)
    }

    var pressure: ThermalPressure {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    var isCritical: Bool { pressure == .critical }

    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }
}
