import Testing
import MacAmbientJevPipeline

@Test
func windowsThermalMonitoringIsExplicitlyUnavailable() {
    let monitor = WindowsNoThermalMonitoring()
    #expect(!monitor.isCritical)
    #expect(monitor.liveASRDecision == .processNow)
}
