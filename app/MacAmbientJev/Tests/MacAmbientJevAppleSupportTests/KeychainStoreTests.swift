import Foundation
import Testing
@testable import MacAmbientJevAppleSupport

@Test(.enabled(
    if: ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1",
    "Set RUN_KEYCHAIN_TESTS=1 to run the real-Keychain integration test."
))
func keychainStoreRoundTripsAndDeletesValue() throws {
    let service = "mac-ambient-jev-tests-\(UUID().uuidString)"
    let account = "jev-api-key"
    let store = KeychainStore(service: service)

    defer {
        try? store.delete(account: account)
    }

    try store.save("test-value", account: account)
    #expect(try store.load(account: account) == "test-value")

    try store.delete(account: account)
    #expect(try store.load(account: account) == nil)
}
