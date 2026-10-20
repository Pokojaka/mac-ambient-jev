import Testing
import MacAmbientJevCore
import MacAmbientJevPipeline

private struct FixedThermalMonitor: ThermalMonitoring {
    let pressure: ThermalPressure

    var isCritical: Bool { pressure == .critical }
    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: pressure)
    }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        FixedThermalStateObservation()
    }
}

private final class FixedThermalStateObservation: ThermalStateObservation {}

@Test
func windowsThermalMonitoringIsExplicitlyUnavailable() {
    let monitor = WindowsNoThermalMonitoring()
    #expect(!monitor.isCritical)
    #expect(monitor.liveASRDecision == .processNow)
}

@Test(arguments: [ThermalPressure.nominal, .fair, .serious, .critical])
func monitoredThermalPolicyPreservesPressure(_ pressure: ThermalPressure) {
    let monitor = FixedThermalMonitor(pressure: pressure)
    #expect(monitor.pressure == pressure)
    #expect(monitor.isCritical == (pressure == .critical))
    #expect(monitor.liveASRDecision == LiveASRThermalPolicy.decision(pressure: pressure))
}
