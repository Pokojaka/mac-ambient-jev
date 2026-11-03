public struct ASRRatioCalibration: Sendable, Equatable {
    public let id: String
    public let executionProviders: Set<ASRExecutionProvider>
    public let ratioUpperBound: Double
    public init(id: String, executionProviders: Set<ASRExecutionProvider>, ratioUpperBound: Double) {
        self.id = id
        self.executionProviders = executionProviders
        self.ratioUpperBound = ratioUpperBound
    }
}

public enum ASRSelectionError: Error, Sendable, Equatable {
    case invalidMeasuredRTF, invalidCalibration, invalidPrediction
}

public enum ASRSizeSelectionReason: Sendable, Equatable {
    case noGPU, hardwareQueryFailed, providerUnavailable, providerAcquisitionFailed
    case unknownDedicatedVRAM, insufficientDedicatedVRAM, insufficientMemory, awaitingAssets
    case eligible, verificationRequired, verificationFailed, uncalibrated, unmeasured
    case recommendLarge, tooSlow
    public var explanation: String {
        switch self {
        case .noGPU: "GPU がないため、0.6B を使用します。"
        case .hardwareQueryFailed: "GPU 情報を取得できないため、0.6B を使用します。"
        case .providerUnavailable: "対応する実行プロバイダーが利用できないため、0.6B を使用します。"
        case .providerAcquisitionFailed: "実行プロバイダーを取得できないため、0.6B を使用します。"
        case .unknownDedicatedVRAM: "専用 VRAM 容量が不明なため、0.6B を使用します。"
        case .insufficientDedicatedVRAM: "専用 VRAM が不足するため、0.6B を使用します。"
        case .insufficientMemory: "利用可能な RAM が不足するため、0.6B を使用します。"
        case .awaitingAssets: "モデル資産が未準備のため、0.6B のままです。"
        case .eligible: "0.6B で実行プロバイダーを検証し、速度を計測できます。"
        case .verificationRequired: "1.7B の推奨には実行プロバイダーの検証が必要です。"
        case .verificationFailed: "EP の検証に失敗しました。CPU を使用する場合は選択してください"
        case .uncalibrated: "性能比率またはメモリ使用量の校正データがないため、1.7B を推奨できません。"
        case .unmeasured: "0.6B の速度が未計測のため、1.7B を推奨できません。"
        case .recommendLarge: "計測結果から 1.7B を推奨します。"
        case .tooSlow: "1.7B の推定 RTF が基準を超えるため、0.6B を使用します。"
        }
    }
}

public struct ASRSizeSelection: Sendable, Equatable {
    public let reason: ASRSizeSelectionReason
    public let measuredRTF: Double?
    public let predictedRTF: Double?
    public var size: ASRModelSize { .small }
    public var recommendLarge: Bool { reason == .recommendLarge }
    public var explanation: String { reason.explanation }
}

public struct ASRInitialSizeGate: Sendable, Equatable {
    public let selection: ASRSizeSelection
    fileprivate let provider: ASRExecutionProvider?
}

private func result(_ reason: ASRSizeSelectionReason, measuredRTF: Double?) -> ASRSizeSelection {
    ASRSizeSelection(reason: reason, measuredRTF: measuredRTF, predictedRTF: nil)
}
private func gateResult(_ reason: ASRSizeSelectionReason, provider: ASRExecutionProvider?) -> ASRInitialSizeGate {
    let selection = ASRSizeSelection(reason: reason, measuredRTF: nil, predictedRTF: nil)
    return ASRInitialSizeGate(selection: selection, provider: provider)
}
public func initialSizeGate(
    hardware: ASRHardware, acquisition: ASRAcquisition, memoryEnvelope: ASRMemoryEnvelope,
    assetsAvailable: Bool
) -> ASRInitialSizeGate {
    switch hardware {
    case .noGPU:
        return gateResult(.noGPU, provider: nil)
    case .queryFailed:
        return gateResult(.hardwareQueryFailed, provider: nil)
    case let .gpu(_, _, _, _, dedicatedVRAMBytes):
        let provider: ASRExecutionProvider
        switch acquisition {
        case .unavailable: return gateResult(.providerUnavailable, provider: nil)
        case .failed: return gateResult(.providerAcquisitionFailed, provider: nil)
        case let .acquired(value): provider = value
        }
        guard let vram = dedicatedVRAMBytes else { return gateResult(.unknownDedicatedVRAM, provider: provider) }
        guard vram > 0 else { return gateResult(.insufficientDedicatedVRAM, provider: provider) }
        if case let .measured(requiredVRAM, requiredRAM, availableRAM) = memoryEnvelope {
            if vram < requiredVRAM { return gateResult(.insufficientDedicatedVRAM, provider: provider) }
            if availableRAM < requiredRAM { return gateResult(.insufficientMemory, provider: provider) }
        }
        guard assetsAvailable else { return gateResult(.awaitingAssets, provider: provider) }
        guard case .measured = memoryEnvelope else { return gateResult(.uncalibrated, provider: provider) }
        return gateResult(.eligible, provider: provider)
    }
}

public func recommendLarge(
    gate: ASRInitialSizeGate, verification: ASRVerification,
    measuredRTF: Double?, calibration: ASRRatioCalibration?
) throws -> ASRSizeSelection {
    if let measuredRTF, (!measuredRTF.isFinite || measuredRTF <= 0) { throw ASRSelectionError.invalidMeasuredRTF }
    if let calibration,
       (calibration.id.isEmpty || calibration.executionProviders.isEmpty || !calibration.ratioUpperBound.isFinite || calibration.ratioUpperBound <= 0) {
        throw ASRSelectionError.invalidCalibration
    }
    if case .failed = verification {
        return result(.verificationFailed, measuredRTF: measuredRTF)
    }
    guard gate.selection.reason == .eligible else {
        return result(gate.selection.reason, measuredRTF: measuredRTF)
    }
    guard case .verified = verification else {
        return result(.verificationRequired, measuredRTF: measuredRTF)
    }
    guard let provider = gate.provider, let calibration,
          calibration.executionProviders.contains(provider) else {
        return result(.uncalibrated, measuredRTF: measuredRTF)
    }
    guard let measuredRTF else { return result(.unmeasured, measuredRTF: nil) }
    let predicted = measuredRTF * calibration.ratioUpperBound
    guard predicted.isFinite, predicted > 0 else { throw ASRSelectionError.invalidPrediction }
    return ASRSizeSelection(reason: predicted <= 0.70 ? .recommendLarge : .tooSlow, measuredRTF: measuredRTF, predictedRTF: predicted)
}
