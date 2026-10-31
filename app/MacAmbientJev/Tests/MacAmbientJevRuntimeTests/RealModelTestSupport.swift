import Foundation
import MacAmbientJevCore
@testable import MacAmbientJevRuntime

/// Real-model tests run only with `RUN_MODEL_TESTS=1`. They read the pinned models from the
/// application-support directory named by `MAC_AMBIENT_JEV_TEST_APP_SUPPORT` (the models sit in its
/// `mac-ambient-jev/models`), or from the system one when the variable is unset.
let realModelTestsEnabled = ProcessInfo.processInfo.environment["RUN_MODEL_TESTS"] == "1"

func realModelStore() throws -> MacModelStore {
    let applicationSupport: URL
    if let path = ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_TEST_APP_SUPPORT"] {
        guard path.hasPrefix("/") else { throw RealModelTestError.relativeApplicationSupport(path) }
        applicationSupport = URL(fileURLWithPath: path, isDirectory: true)
    } else {
        applicationSupport = try AppPaths.systemDefault(fileManager: .default).applicationSupportURL
    }
    return try MacModelStore(paths: AppPaths(
        applicationSupportURL: applicationSupport, cacheURL: applicationSupport, sessionsRootOverride: nil
    ))
}

enum RealModelTestError: Error {
    case relativeApplicationSupport(String)
}
