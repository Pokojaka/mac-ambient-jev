import Testing
@testable import MacAmbientJevCore

@Test
func liveASRThermalPolicyProcessesImmediatelyAtNormalPressure() {
    #expect(LiveASRThermalPolicy.decision(pressure: .nominal) == .processNow)
    #expect(LiveASRThermalPolicy.decision(pressure: .fair) == .processNow)
}

@Test
func liveASRThermalPolicyWaitsBrieflyAtSeriousPressure() {
    #expect(LiveASRThermalPolicy.decision(pressure: .serious) == .wait(.milliseconds(750)))
}

@Test
func liveASRThermalPolicySuspendsAtCriticalPressure() {
    #expect(LiveASRThermalPolicy.decision(pressure: .critical) == .suspendUntilCooled)
}
