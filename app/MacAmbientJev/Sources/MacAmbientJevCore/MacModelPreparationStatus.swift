import Foundation

/// The models the Mac app downloads, pinned in `Resources/mac_models.json`.
public enum MacModel: String, CaseIterable, Sendable {
    case asr
    case diarization
    case vad

    public var displayName: String {
        switch self {
        case .asr: "音声認識"
        case .diarization: "話者分離"
        case .vad: "発話区間検出"
        }
    }
}

public enum MacModelState: Equatable, Sendable {
    case idle
    case downloading
    /// Hashing the files or loading the model.
    case verifying
    case ready
    case failed(String)
}

/// What the Settings screen and the live and finalization gates read about the three models.
public struct ModelPreparationStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    public var models: [MacModel: MacModelState]
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public static let initial = ModelPreparationStatus(
        models: Dictionary(uniqueKeysWithValues: MacModel.allCases.map { ($0, MacModelState.idle) }),
        bytesDone: 0,
        bytesTotal: 0
    )

    /// Shown while recording and queued work wait for the models.
    public static let waitingForModelsText = "モデルの取得後に文字起こしします"

    public func state(_ model: MacModel) -> MacModelState { models[model]! }

    public var phase: Phase {
        let states = MacModel.allCases.map(state)
        for case let .failed(reason) in states { return .failed(reason) }
        if states.contains(.downloading) { return .downloading }
        if states.contains(.verifying) { return .loading }
        if states.allSatisfy({ $0 == .ready }) { return .ready }
        return .idle
    }
}
