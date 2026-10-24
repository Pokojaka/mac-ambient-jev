import Foundation

private func enginePresentationRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func enginePresentationRequireNonempty(_ value: String, _ field: String) throws {
    try enginePresentationRequire(!value.isEmpty, "\(field) must not be empty")
}

public enum EngineRecordingTone: String, Codable, CaseIterable, Equatable, Sendable {
    case neutral
    case recording
    case warning
    case error
}

public enum EnginePreparationPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed
}

public enum EngineProcessingIndicator: String, Codable, CaseIterable, Equatable, Sendable {
    case idle
    case running
    case backlogged
    case complete
    case partialFailure = "partial_failure"
}

public struct EnginePresentationState: Codable, Equatable, Sendable {
    public let recordingStatusText: String
    public let recordingTone: EngineRecordingTone
    public let preparationPhase: EnginePreparationPhase
    @EngineNullable public private(set) var preparationStatusText: String?
    @EngineNullable public private(set) var recoveryStatusText: String?
    @EngineNullable public private(set) var processingStatusText: String?
    public let liveFailureNotices: [String]
    public let silenceWarningActive: Bool
    @EngineNullable public private(set) var silenceWarningText: String?
    public let audioGapCount: UInt64
    @EngineNullable public private(set) var audioGapText: String?
    public let processingIndicator: EngineProcessingIndicator

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case recordingStatusText = "recording_status_text"
        case recordingTone = "recording_tone"
        case preparationPhase = "preparation_phase"
        case preparationStatusText = "preparation_status_text"
        case recoveryStatusText = "recovery_status_text"
        case processingStatusText = "processing_status_text"
        case liveFailureNotices = "live_failure_notices"
        case silenceWarningActive = "silence_warning_active"
        case silenceWarningText = "silence_warning_text"
        case audioGapCount = "audio_gap_count"
        case audioGapText = "audio_gap_text"
        case processingIndicator = "processing_indicator"
    }

    public init(
        recordingStatusText: String,
        recordingTone: EngineRecordingTone,
        preparationPhase: EnginePreparationPhase,
        preparationStatusText: String?,
        recoveryStatusText: String?,
        processingStatusText: String?,
        liveFailureNotices: [String],
        silenceWarningActive: Bool,
        silenceWarningText: String?,
        audioGapCount: UInt64,
        audioGapText: String?,
        processingIndicator: EngineProcessingIndicator
    ) throws {
        self.recordingStatusText = recordingStatusText
        self.recordingTone = recordingTone
        self.preparationPhase = preparationPhase
        _preparationStatusText = EngineNullable(wrappedValue: preparationStatusText)
        _recoveryStatusText = EngineNullable(wrappedValue: recoveryStatusText)
        _processingStatusText = EngineNullable(wrappedValue: processingStatusText)
        self.liveFailureNotices = liveFailureNotices
        self.silenceWarningActive = silenceWarningActive
        _silenceWarningText = EngineNullable(wrappedValue: silenceWarningText)
        self.audioGapCount = audioGapCount
        _audioGapText = EngineNullable(wrappedValue: audioGapText)
        self.processingIndicator = processingIndicator
        try validate()
    }

    private func validate() throws {
        try enginePresentationRequireNonempty(recordingStatusText, "recording_status_text")
        let preparationRequiresStatusText = preparationPhase == .preparing || preparationPhase == .failed
        try enginePresentationRequire(
            (preparationStatusText != nil) == preparationRequiresStatusText,
            "preparation_status_text presence must match preparation_phase"
        )
        if let preparationStatusText {
            try enginePresentationRequireNonempty(preparationStatusText, "preparation_status_text")
        }
        if let recoveryStatusText {
            try enginePresentationRequireNonempty(recoveryStatusText, "recovery_status_text")
        }
        if let processingStatusText {
            try enginePresentationRequireNonempty(processingStatusText, "processing_status_text")
        }
        for notice in liveFailureNotices {
            try enginePresentationRequireNonempty(notice, "live_failure_notices entry")
        }
        if let silenceWarningText {
            try enginePresentationRequireNonempty(silenceWarningText, "silence_warning_text")
        }
        try enginePresentationRequire(
            silenceWarningActive == (silenceWarningText != nil),
            "silence_warning_active must match silence_warning_text presence"
        )
        if let audioGapText {
            try enginePresentationRequireNonempty(audioGapText, "audio_gap_text")
            try enginePresentationRequire(audioGapCount > 0, "audio_gap_text requires a positive audio_gap_count")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            recordingStatusText: container.decode(String.self, forKey: .recordingStatusText),
            recordingTone: container.decode(EngineRecordingTone.self, forKey: .recordingTone),
            preparationPhase: container.decode(EnginePreparationPhase.self, forKey: .preparationPhase),
            preparationStatusText: container.decode(EngineNullable<String>.self, forKey: .preparationStatusText).wrappedValue,
            recoveryStatusText: container.decode(EngineNullable<String>.self, forKey: .recoveryStatusText).wrappedValue,
            processingStatusText: container.decode(EngineNullable<String>.self, forKey: .processingStatusText).wrappedValue,
            liveFailureNotices: container.decode([String].self, forKey: .liveFailureNotices),
            silenceWarningActive: container.decode(Bool.self, forKey: .silenceWarningActive),
            silenceWarningText: container.decode(EngineNullable<String>.self, forKey: .silenceWarningText).wrappedValue,
            audioGapCount: container.decode(UInt64.self, forKey: .audioGapCount),
            audioGapText: container.decode(EngineNullable<String>.self, forKey: .audioGapText).wrappedValue,
            processingIndicator: container.decode(EngineProcessingIndicator.self, forKey: .processingIndicator)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordingStatusText, forKey: .recordingStatusText)
        try container.encode(recordingTone, forKey: .recordingTone)
        try container.encode(preparationPhase, forKey: .preparationPhase)
        try container.encode(_preparationStatusText, forKey: .preparationStatusText)
        try container.encode(_recoveryStatusText, forKey: .recoveryStatusText)
        try container.encode(_processingStatusText, forKey: .processingStatusText)
        try container.encode(liveFailureNotices, forKey: .liveFailureNotices)
        try container.encode(silenceWarningActive, forKey: .silenceWarningActive)
        try container.encode(_silenceWarningText, forKey: .silenceWarningText)
        try container.encode(audioGapCount, forKey: .audioGapCount)
        try container.encode(_audioGapText, forKey: .audioGapText)
        try container.encode(processingIndicator, forKey: .processingIndicator)
    }
}
