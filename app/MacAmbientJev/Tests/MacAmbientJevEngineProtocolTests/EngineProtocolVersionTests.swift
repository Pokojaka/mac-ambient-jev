import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolVersionTests {
    @Test func currentVersionIsOne() {
        #expect(EngineProtocolVersion.current == 1)
    }
}
