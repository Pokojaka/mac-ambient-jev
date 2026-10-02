import Foundation

/// A level summary on the capture timeline. A window is either speech (VAD-confirmed energy)
/// or raw (per-channel input peak and clipping), never both.
public struct MicLevelWindow: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let speechSeconds: Double
    public let speechMeanSquare: Double?
    public let speechPeak: Float
    public let inputPeak: Float
    public let clippedFraction: Double

    public init(
        startSeconds: Double, endSeconds: Double, speechSeconds: Double,
        speechMeanSquare: Double?, speechPeak: Float, inputPeak: Float,
        clippedFraction: Double
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speechSeconds = speechSeconds
        self.speechMeanSquare = speechMeanSquare
        self.speechPeak = speechPeak
        self.inputPeak = inputPeak
        self.clippedFraction = clippedFraction
    }
}

public enum MicInputWarning: Sendable, Equatable {
    case low
    case clipping
    case monitoringUnavailable
}

public enum MicInputVolumeFailure: Error, Sendable, Equatable {
    case deviceIdentityUnverified
    case propertyUnavailable
    case invalidValue
    case listenerRegistrationFailed
    case listenerRemovalFailed
    case notBound
    case staleExpectedValues
    case writeRejected
    case noMovement
    case unexpectedMovement
    case partialWrite
    case acknowledgementTimeout
    case writeUnresolved
}

public enum MicInputAdjustment: Sendable, Equatable {
    case active
    case disabledBySetting
    case unsupportedDevice
    case pausedByExternalChange
    case failed(MicInputVolumeFailure)
    case restoreFailed(MicInputVolumeFailure)
}

public struct MicInputStatus: Sendable, Equatable {
    public let warning: MicInputWarning?
    public let adjustment: MicInputAdjustment

    public init(warning: MicInputWarning?, adjustment: MicInputAdjustment) {
        self.warning = warning
        self.adjustment = adjustment
    }
}

public struct MicGainDecision: Sendable, Equatable {
    public let volumeDelta: Float?
    public let warning: MicInputWarning?

    public init(volumeDelta: Float?, warning: MicInputWarning?) {
        self.volumeDelta = volumeDelta
        self.warning = warning
    }
}

/// Speech-gated input-volume policy. Pure: the caller supplies time, capability and scalars.
public struct MicGainPolicy: Sendable {
    static let evidenceSpan = 8.0
    static let requiredLowSpeech = 3.0
    static let speechGapReset = 2.0
    static let lowEntryMeanSquare = meanSquare(dBFS: -34)
    static let recoveryMeanSquare = meanSquare(dBFS: -30)
    static let recoverySpeech = 2.0
    static let lowClearAfterNoSpeech = 8.0
    static let raiseStep: Float = 0.05
    static let raiseInterval = 5.0
    static let raisePeakCeiling: Float = 0.80
    static let loudMeanSquare = meanSquare(dBFS: -14)
    static let loudRearmMeanSquare = meanSquare(dBFS: -18)
    static let loudSpeech = 1.0
    static let loudStep: Float = -0.05
    static let loudInterval = 2.0
    static let clippedFractionThreshold = 0.001
    static let clipStep: Float = -0.10
    static let clipInterval = 0.5
    static let clipWarningPersistence = 1.0
    static let clipClear = 3.0
    static let settleAfterChange = 1.5
    static let maximumSpeechLatency = 2.0
    static let maximumRawLatency = 1.0
    static let futureTolerance = 1.0
    static let orderTolerance = 1e-9

    private struct SpeechSummary: Sendable {
        let startSeconds: Double
        let seconds: Double
        let meanSquare: Double
        let peak: Float
    }

    private enum Kind {
        case speech(meanSquare: Double)
        case raw
    }

    private var speechCursor: Double?
    private var rawCursor: Double?
    private var evidence: [SpeechSummary] = []
    private var lastSpeechEnd: Double?
    private var recoverySeconds = 0.0
    private var loudSeconds = 0.0
    private var lowActive = false
    private var settleUntil: Double?
    private var lastRaise: Double?
    private var lastLoudLower: Double?
    private var lastClipLower: Double?
    private var clipSince: Double?
    private var cleanRawSeconds = 0.0
    private var clipWarning = false

    public init() {}

    static func meanSquare(dBFS: Double) -> Double { pow(10, dBFS / 10) }

    private var warning: MicInputWarning? {
        clipWarning ? .clipping : (lowActive ? .low : nil)
    }

    private var unchanged: MicGainDecision { MicGainDecision(volumeDelta: nil, warning: warning) }

    public mutating func observe(
        _ window: MicLevelWindow, currentScalars: [Float],
        canAdjust: Bool, nowSeconds: Double
    ) -> MicGainDecision {
        guard nowSeconds.isFinite else { return unchanged }
        if lowActive, let lastSpeechEnd,
           nowSeconds - lastSpeechEnd >= Self.lowClearAfterNoSpeech - Self.orderTolerance {
            lowActive = false
        }
        guard currentScalars.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              window.endSeconds <= nowSeconds + Self.futureTolerance,
              let kind = Self.classify(window) else { return unchanged }
        let adjustable = canAdjust && !currentScalars.isEmpty
        switch kind {
        case .speech(let meanSquare):
            return observeSpeech(window, meanSquare: meanSquare, scalars: currentScalars,
                                 adjustable: adjustable, now: nowSeconds)
        case .raw:
            return observeRaw(window, scalars: currentScalars, adjustable: adjustable, now: nowSeconds)
        }
    }

    public mutating func didApplyVolumeChange(atSeconds: Double) {
        precondition(atSeconds.isFinite)
        settleUntil = atSeconds + Self.settleAfterChange
        resetSpeechEvidence()
        rawCursor = max(rawCursor ?? atSeconds, atSeconds)
    }

    public mutating func reset() {
        self = MicGainPolicy()
    }

    private static func classify(_ window: MicLevelWindow) -> Kind? {
        let duration = window.endSeconds - window.startSeconds
        guard window.startSeconds.isFinite, window.endSeconds.isFinite,
              window.startSeconds >= 0, duration > 0,
              window.speechSeconds.isFinite, window.speechSeconds >= 0,
              window.speechSeconds <= duration + orderTolerance,
              window.speechPeak.isFinite, window.speechPeak >= 0,
              window.inputPeak.isFinite, window.inputPeak >= 0,
              window.clippedFraction.isFinite,
              window.clippedFraction >= 0, window.clippedFraction <= 1 else { return nil }
        if window.speechSeconds > 0 {
            guard let meanSquare = window.speechMeanSquare, meanSquare.isFinite, meanSquare >= 0,
                  window.inputPeak == 0, window.clippedFraction == 0 else { return nil }
            return .speech(meanSquare: meanSquare)
        }
        guard window.speechMeanSquare == nil, window.speechPeak == 0 else { return nil }
        return .raw
    }

    private mutating func resetSpeechEvidence() {
        evidence.removeAll()
        recoverySeconds = 0
        loudSeconds = 0
    }

    private static func elapsed(since time: Double?, now: Double, atLeast interval: Double) -> Bool {
        guard let time else { return true }
        return now - time >= interval - orderTolerance
    }

    private mutating func observeSpeech(
        _ window: MicLevelWindow, meanSquare: Double, scalars: [Float],
        adjustable: Bool, now: Double
    ) -> MicGainDecision {
        if let speechCursor, window.startSeconds < speechCursor - Self.orderTolerance {
            return unchanged
        }
        speechCursor = window.endSeconds
        guard now - window.endSeconds <= Self.maximumSpeechLatency else { return unchanged }
        if let settleUntil, window.startSeconds < settleUntil - Self.orderTolerance { return unchanged }
        if let lastSpeechEnd, window.startSeconds - lastSpeechEnd > Self.speechGapReset {
            resetSpeechEvidence()
        }
        lastSpeechEnd = window.endSeconds
        evidence.append(SpeechSummary(
            startSeconds: window.startSeconds, seconds: window.speechSeconds,
            meanSquare: meanSquare, peak: window.speechPeak
        ))
        evidence.removeAll { $0.startSeconds < window.endSeconds - Self.evidenceSpan }

        if meanSquare >= Self.recoveryMeanSquare {
            recoverySeconds += window.speechSeconds
        } else {
            recoverySeconds = 0
        }
        if lowActive, recoverySeconds >= Self.recoverySpeech - Self.orderTolerance { lowActive = false }
        if meanSquare > Self.loudMeanSquare {
            loudSeconds += window.speechSeconds
        } else if meanSquare < Self.loudRearmMeanSquare {
            loudSeconds = 0
        }

        if loudSeconds >= Self.loudSpeech - Self.orderTolerance, adjustable, scalars.contains(where: { $0 > 0 }),
           Self.elapsed(since: lastLoudLower, now: now, atLeast: Self.loudInterval) {
            lastLoudLower = now
            loudSeconds = 0
            return MicGainDecision(volumeDelta: Self.loudStep, warning: warning)
        }

        let totalSpeech = evidence.reduce(0) { $0 + $1.seconds }
        guard clipSince == nil, recoverySeconds < Self.recoverySpeech - Self.orderTolerance,
              totalSpeech >= Self.requiredLowSpeech - Self.orderTolerance else { return unchanged }
        let weighted = evidence.reduce(0) { $0 + $1.meanSquare * $1.seconds } / totalSpeech
        guard weighted < Self.lowEntryMeanSquare else { return unchanged }
        let peak = evidence.reduce(Float(0)) { max($0, $1.peak) }
        let maxed = scalars.allSatisfy { $0 >= 1 }
        if adjustable, !maxed, peak < Self.raisePeakCeiling {
            guard Self.elapsed(since: lastRaise, now: now, atLeast: Self.raiseInterval) else {
                return unchanged
            }
            lastRaise = now
            return MicGainDecision(volumeDelta: Self.raiseStep, warning: warning)
        }
        lowActive = true
        return unchanged
    }

    private mutating func observeRaw(
        _ window: MicLevelWindow, scalars: [Float], adjustable: Bool, now: Double
    ) -> MicGainDecision {
        if let rawCursor, window.startSeconds < rawCursor - Self.orderTolerance {
            return unchanged
        }
        rawCursor = window.endSeconds
        guard now - window.endSeconds <= Self.maximumRawLatency else { return unchanged }
        guard window.clippedFraction >= Self.clippedFractionThreshold else {
            cleanRawSeconds += window.endSeconds - window.startSeconds
            if cleanRawSeconds >= Self.clipClear - Self.orderTolerance {
                clipWarning = false
                clipSince = nil
            }
            return unchanged
        }
        cleanRawSeconds = 0
        let since = clipSince ?? window.startSeconds
        clipSince = since
        let canLower = adjustable && scalars.contains { $0 > 0 }
        if !canLower || window.endSeconds - since >= Self.clipWarningPersistence - Self.orderTolerance {
            clipWarning = true
        }
        guard canLower, Self.elapsed(since: lastClipLower, now: now, atLeast: Self.clipInterval) else {
            return unchanged
        }
        lastClipLower = now
        return MicGainDecision(volumeDelta: Self.clipStep, warning: warning)
    }
}
