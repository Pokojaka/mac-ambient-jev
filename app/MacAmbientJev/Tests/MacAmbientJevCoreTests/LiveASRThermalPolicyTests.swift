import Testing
@testable import MacAmbientJevCore

@Test
func liveASRThermalPolicyDoesNotDelayAtNormalPressure() {
    for pressure in [ThermalPressure.nominal, .fair] {
        #expect(
            LiveASRThermalPolicy.decision(
                pressure: pressure,
                pendingCount: 4,
                oldestPendingAge: 0
            ) == .processNow
        )
    }
}

@Test
func liveASRThermalPolicyOnlyWaitsBrieflyForFreshBacklog() {
    #expect(
        LiveASRThermalPolicy.decision(
            pressure: .serious,
            pendingCount: 1,
            oldestPendingAge: 3
        ) == .wait(.milliseconds(750))
    )
    #expect(
        LiveASRThermalPolicy.decision(
            pressure: .critical,
            pendingCount: 4,
            oldestPendingAge: 29
        ) == .wait(.seconds(2))
    )
}

@Test
func liveASRThermalPolicyDrainsOldBacklogWithoutWaiting() {
    for pressure in [ThermalPressure.serious, .critical] {
        #expect(
            LiveASRThermalPolicy.decision(
                pressure: pressure,
                pendingCount: 6,
                oldestPendingAge: 30
            ) == .processNow
        )
        #expect(
            LiveASRThermalPolicy.decision(
                pressure: pressure,
                pendingCount: 0,
                oldestPendingAge: 0
            ) == .processNow
        )
    }
}
