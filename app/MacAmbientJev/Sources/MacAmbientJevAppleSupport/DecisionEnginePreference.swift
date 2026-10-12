import CoreFoundation
import Foundation
import MacAmbientJevCore

public enum DecisionEnginePreferenceError: LocalizedError, Sendable {
    case invalidInitialization
    case invalidSelection
    case invalidPauseSetting

    public var errorDescription: String? {
        switch self {
        case .invalidInitialization:
            "意思決定エンジン設定の初期化状態が不正です。"
        case .invalidSelection:
            "意思決定エンジンの設定が不正です。"
        case .invalidPauseSetting:
            "一時停止設定が不正です。"
        }
    }
}

public enum DecisionEnginePreference {
    public static let key = "decision.engine"
    public static let pauseKey = "decision.isPaused"

    /// First launch is when both keys are absent. The engine starts paused so that
    /// nothing reaches the external API until the user resumes.
    public static func initializeFirstLaunch(defaults: UserDefaults) throws {
        let engine = defaults.object(forKey: key)
        let pause = defaults.object(forKey: pauseKey)
        if engine == nil && pause == nil {
            defaults.set(DecisionEngineChoice.jev.rawValue, forKey: key)
            defaults.set(true, forKey: pauseKey)
        } else if engine == nil || pause == nil {
            throw DecisionEnginePreferenceError.invalidInitialization
        }

        _ = try load(defaults: defaults)
        _ = try isPaused(defaults: defaults)
    }

    public static func load(defaults: UserDefaults) throws -> DecisionEngineChoice {
        guard let rawValue = defaults.object(forKey: key) as? String,
            let choice = DecisionEngineChoice(rawValue: rawValue)
        else {
            throw DecisionEnginePreferenceError.invalidSelection
        }
        return choice
    }

    public static func isPaused(defaults: UserDefaults) throws -> Bool {
        guard let value = defaults.object(forKey: pauseKey) as? NSNumber,
            CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            throw DecisionEnginePreferenceError.invalidPauseSetting
        }
        return value.boolValue
    }
}
