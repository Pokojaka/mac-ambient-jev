import Foundation
import Testing
@testable import MacAmbientJevCore

@Test
func sessionDirectoryLivesUnderApplicationSupport() {
    let support = URL(fileURLWithPath: "/tmp/support")
    let cache = URL(fileURLWithPath: "/tmp/cache")
    let paths = AppPaths(applicationSupportURL: support, cacheURL: cache, sessionsRootOverride: nil)

    #expect(paths.sessionsRoot.path == "/tmp/support/mac-ambient-jev/sessions")
    #expect(paths.modelsRoot.path == "/tmp/support/mac-ambient-jev/models")
}
