import Testing
import MacAmbientJevEngineHost

struct EngineHostErrorTests {
    @Test func unavailableHasExplicitMessage() {
        #expect(EngineHostError.unavailable.errorDescription == "Engine host is not implemented.")
    }
}
