import Foundation
import Testing

@Suite
struct ClauseTaggerParityFixtureTests {
    @Test(.enabled(if: ClauseTaggerParityFixtureSupport.testIsEnabled))
    func capturesOrChecksRealMacGoldenFixturesWhenEnabled() async throws {
        try await ClauseTaggerParityFixtureSupport.run()
    }

}
