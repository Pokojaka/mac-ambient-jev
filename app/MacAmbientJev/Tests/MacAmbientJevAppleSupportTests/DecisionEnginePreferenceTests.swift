import CoreFoundation
import Foundation
import Testing
import MacAmbientJevAppleSupport
import MacAmbientJevCore

@Suite
struct DecisionEnginePreferenceTests {
    @Test
    func missingValuesAreRejectedWithoutWritingDefaults() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expectPreferenceError(.invalidSelection) {
            _ = try DecisionEnginePreference.load(defaults: defaults)
        }
        #expect(defaults.object(forKey: DecisionEnginePreference.key) == nil)

        expectPreferenceError(.invalidPauseSetting) {
            _ = try DecisionEnginePreference.isPaused(defaults: defaults)
        }
        #expect(defaults.object(forKey: DecisionEnginePreference.pauseKey) == nil)
    }

    @Test
    func firstLaunchInitializationPersistsJevPaused() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try DecisionEnginePreference.initializeFirstLaunch(defaults: defaults)

        let persistentValues = try #require(defaults.persistentDomain(forName: suiteName))
        #expect(persistentValues[DecisionEnginePreference.key] as? String == DecisionEngineChoice.jev.rawValue)
        let pause = try #require(persistentValues[DecisionEnginePreference.pauseKey] as? NSNumber)
        #expect(CFGetTypeID(pause) == CFBooleanGetTypeID())
        #expect(pause.boolValue)
        #expect(persistentValues.count == 2)
    }

    @Test
    func repeatedInitializationPreservesSelectedEngineAndResumedState() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try DecisionEnginePreference.initializeFirstLaunch(defaults: defaults)
        defaults.set(DecisionEngineChoice.localModel.rawValue, forKey: DecisionEnginePreference.key)
        defaults.set(false, forKey: DecisionEnginePreference.pauseKey)

        try DecisionEnginePreference.initializeFirstLaunch(defaults: defaults)

        #expect(try DecisionEnginePreference.load(defaults: defaults) == .localModel)
        #expect(try DecisionEnginePreference.isPaused(defaults: defaults) == false)
    }

    @Test
    func exactlyOnePresentKeyIsRejectedWithoutChanges() throws {
        let (engineDefaults, engineSuite) = try isolatedDefaults()
        defer { engineDefaults.removePersistentDomain(forName: engineSuite) }
        engineDefaults.set(DecisionEngineChoice.localModel.rawValue, forKey: DecisionEnginePreference.key)

        expectPreferenceError(.invalidInitialization) {
            try DecisionEnginePreference.initializeFirstLaunch(defaults: engineDefaults)
        }
        #expect(engineDefaults.object(forKey: DecisionEnginePreference.key) as? String == DecisionEngineChoice.localModel.rawValue)
        #expect(engineDefaults.object(forKey: DecisionEnginePreference.pauseKey) == nil)

        let (pauseDefaults, pauseSuite) = try isolatedDefaults()
        defer { pauseDefaults.removePersistentDomain(forName: pauseSuite) }
        pauseDefaults.set(false, forKey: DecisionEnginePreference.pauseKey)

        expectPreferenceError(.invalidInitialization) {
            try DecisionEnginePreference.initializeFirstLaunch(defaults: pauseDefaults)
        }
        #expect(pauseDefaults.object(forKey: DecisionEnginePreference.key) == nil)
        #expect((pauseDefaults.object(forKey: DecisionEnginePreference.pauseKey) as? NSNumber)?.boolValue == false)
    }

    @Test
    func invalidExistingValuesAreRejectedAndPreserved() throws {
        let (engineDefaults, engineSuite) = try isolatedDefaults()
        defer { engineDefaults.removePersistentDomain(forName: engineSuite) }
        engineDefaults.set("unknown-engine", forKey: DecisionEnginePreference.key)
        engineDefaults.set(false, forKey: DecisionEnginePreference.pauseKey)

        expectPreferenceError(.invalidSelection) {
            try DecisionEnginePreference.initializeFirstLaunch(defaults: engineDefaults)
        }
        #expect(engineDefaults.object(forKey: DecisionEnginePreference.key) as? String == "unknown-engine")

        let (pauseDefaults, pauseSuite) = try isolatedDefaults()
        defer { pauseDefaults.removePersistentDomain(forName: pauseSuite) }
        pauseDefaults.set(DecisionEngineChoice.jev.rawValue, forKey: DecisionEnginePreference.key)
        pauseDefaults.set(NSNumber(value: 1), forKey: DecisionEnginePreference.pauseKey)

        expectPreferenceError(.invalidPauseSetting) {
            try DecisionEnginePreference.initializeFirstLaunch(defaults: pauseDefaults)
        }
        #expect((pauseDefaults.object(forKey: DecisionEnginePreference.pauseKey) as? NSNumber)?.intValue == 1)
    }
}

private func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "DecisionEnginePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, suiteName)
}

private func expectPreferenceError(
    _ expected: DecisionEnginePreferenceError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected preference error: \(expected.localizedDescription)")
    } catch let actual as DecisionEnginePreferenceError {
        switch (expected, actual) {
        case (.invalidInitialization, .invalidInitialization),
            (.invalidSelection, .invalidSelection),
            (.invalidPauseSetting, .invalidPauseSetting):
            break
        default:
            Issue.record("Unexpected preference error: \(actual.localizedDescription)")
        }
    } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
    }
}
