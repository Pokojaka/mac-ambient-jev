public enum InferenceWorkload: Sendable, Equatable { case load, live, finalization }
public enum InferenceEnvelope: Sendable, Equatable {
    case unmeasured, stale
    case measured(loadPeakBytes: UInt64, residentBytes: UInt64, scratchBytes: UInt64, concurrentBytes: UInt64)
}
public enum InferenceRTF: Sendable, Equatable { case unmeasured, stale, measured(Double) }
public enum InferenceAdmissionReason: Sendable, Equatable {
    case unsupportedCPUCount, invalidThreads, lowMemory, insufficientPhysicalMemory, insufficientCommitHeadroom
    case envelopeUnmeasured, envelopeStale, rtfUnmeasured, rtfStale, liveTooSlow

    public var explanation: String {
        switch self {
        case .unsupportedCPUCount: "論理CPU数が2未満のため、推論を実行できません。"
        case .invalidThreads: "スレッド数は1から論理CPU数未満（最大4）の範囲で指定してください。"
        case .lowMemory: "低メモリ状態が検出されたため、推論を開始できません。"
        case .insufficientPhysicalMemory: "物理メモリの空き容量が推論に必要な量を下回っています。"
        case .insufficientCommitHeadroom: "コミット可能メモリの余裕が推論に必要な量を下回っています。"
        case .envelopeUnmeasured: "推論のメモリ使用量が未計測です。"
        case .envelopeStale: "推論のメモリ計測が古いため、更新が必要です。"
        case .rtfUnmeasured: "リアルタイム係数が未計測です。"
        case .rtfStale: "リアルタイム係数の計測が古いため、更新が必要です。"
        case .liveTooSlow: "リアルタイム係数が基準を超えており、ライブ推論には遅すぎます。"
        }
    }
}
public enum InferenceAdmission: Sendable, Equatable {
    case admit, warn(InferenceAdmissionReason), block(InferenceAdmissionReason)

    public var explanation: String {
        switch self {
        case .admit: "推論を開始できます。"
        case .warn(let reason), .block(let reason): reason.explanation
        }
    }
}
public enum InferenceAdmissionError: Error, Sendable, Equatable {
    case invalidPhysicalMemory, invalidMeasuredRTF, envelopeOverflow
}

public func admitInference(
    physicalMemoryBytes: UInt64, freePhysicalMemoryBytes: UInt64, commitHeadroomBytes: UInt64,
    envelope: InferenceEnvelope, measuredRTF: InferenceRTF, threads: Int, logicalCPUCount: Int,
    workload: InferenceWorkload, lowMemorySignal: Bool
) throws -> InferenceAdmission {
    guard physicalMemoryBytes > 0, freePhysicalMemoryBytes <= physicalMemoryBytes else {
        throw InferenceAdmissionError.invalidPhysicalMemory
    }
    if case .measured(let rtf) = measuredRTF, (!rtf.isFinite || rtf <= 0) {
        throw InferenceAdmissionError.invalidMeasuredRTF
    }
    let required: UInt64?
    if case .measured(let load, let resident, let scratch, let concurrent) = envelope {
        let (first, second) = workload == .load ? (load, concurrent) : (resident, scratch)
        let (partial, overflow1) = first.addingReportingOverflow(second)
        let (sum, overflow2) = partial.addingReportingOverflow(workload == .load ? 0 : concurrent)
        guard !overflow1, !overflow2 else { throw InferenceAdmissionError.envelopeOverflow }
        required = sum
    } else { required = nil }
    guard logicalCPUCount >= 2 else { return .block(.unsupportedCPUCount) }
    guard (1...min(4, logicalCPUCount - 1)).contains(threads) else { return .block(.invalidThreads) }
    guard !lowMemorySignal else { return .block(.lowMemory) }
    let tenth = physicalMemoryBytes / 10 + (physicalMemoryBytes % 10 == 0 ? 0 : 1)
    let reserve = max(UInt64(1) << 30, tenth)
    guard freePhysicalMemoryBytes >= reserve else { return .block(.insufficientPhysicalMemory) }
    guard commitHeadroomBytes >= reserve else { return .block(.insufficientCommitHeadroom) }
    if let required {
        guard required <= freePhysicalMemoryBytes - reserve else { return .block(.insufficientPhysicalMemory) }
        guard required <= commitHeadroomBytes - reserve else { return .block(.insufficientCommitHeadroom) }
    }
    if workload == .live, case .measured(let rtf) = measuredRTF, rtf > 0.70 {
        return .block(.liveTooSlow)
    }
    switch envelope {
    case .unmeasured: return .warn(.envelopeUnmeasured)
    case .stale: return .warn(.envelopeStale)
    case .measured: break
    }
    switch measuredRTF {
    case .unmeasured: return .warn(.rtfUnmeasured)
    case .stale: return .warn(.rtfStale)
    case .measured: return .admit
    }
}
