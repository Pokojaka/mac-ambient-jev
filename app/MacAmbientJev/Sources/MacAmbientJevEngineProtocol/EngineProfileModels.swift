import Foundation

private func engineProfileRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else {
        throw EngineProtocolError.invalidJSON(reason)
    }
}

private func engineProfileRequireNonempty(_ value: String, _ field: String) throws {
    try engineProfileRequire(!value.isEmpty, "\(field) must not be empty")
}

public enum EngineProfileProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case cpu
    case nvTensorRtRtx = "nv_tensor_rt_rtx"
    case openVINO = "open_vino"
    case miGraphX = "mi_graph_x"
    case vitisAI = "vitis_ai"
    case qnn

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown profile provider")
        }
        self = value
    }
}

public enum EngineProfileSelectionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case noGPU = "no_gpu"
    case hardwareQueryFailed = "hardware_query_failed"
    case providerUnavailable = "provider_unavailable"
    case providerAcquisitionFailed = "provider_acquisition_failed"
    case unknownDedicatedVRAM = "unknown_dedicated_vram"
    case insufficientDedicatedVRAM = "insufficient_dedicated_vram"
    case insufficientMemory = "insufficient_memory"
    case awaitingAssets = "awaiting_assets"
    case eligible
    case verificationRequired = "verification_required"
    case verificationFailed = "verification_failed"
    case uncalibrated
    case unmeasured
    case recommendLarge = "recommend_large"
    case tooSlow = "too_slow"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw EngineProtocolError.invalidJSON("unknown profile selection reason")
        }
        self = value
    }
}

public enum EngineProfileDecisionState: String, Codable, CaseIterable, Equatable, Sendable {
    case awaitingAssets = "awaiting_assets"
    case offered
    case complete
}

public enum EngineProfileSetupOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case binding
    case verifying
}

public enum EngineProfileHardware: Codable, Equatable, Sendable {
    case noGPU
    case queryFailed(String)
    case gpu(name: String, adapterID: String, deviceID: String, driverVersion: String, dedicatedVRAMBytes: UInt64?)

    private enum Kind: String, Codable {
        case noGPU = "no_gpu"
        case queryFailed = "query_failed"
        case gpu

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw EngineProtocolError.invalidJSON("unknown profile hardware kind")
            }
            self = value
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case message
        case name
        case adapterID = "adapter_id"
        case deviceID = "device_id"
        case driverVersion = "driver_version"
        case dedicatedVRAMBytes = "dedicated_vram_bytes"
    }

    private var kind: Kind {
        switch self {
        case .noGPU: .noGPU
        case .queryFailed: .queryFailed
        case .gpu: .gpu
        }
    }

    private func validate() throws {
        switch self {
        case .noGPU:
            break
        case let .queryFailed(message):
            try engineProfileRequireNonempty(message, "message")
        case let .gpu(name, adapterID, deviceID, driverVersion, _):
            try engineProfileRequireNonempty(name, "name")
            try engineProfileRequireNonempty(adapterID, "adapter_id")
            try engineProfileRequireNonempty(deviceID, "device_id")
            try engineProfileRequireNonempty(driverVersion, "driver_version")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: EngineCodingKey.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .noGPU:
            try engineProfileRequire(Set(dynamic.allKeys.map(\.stringValue)) == ["kind"], "no_gpu hardware has invalid fields")
            self = .noGPU
        case .queryFailed:
            try engineProfileRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == ["kind", "message"],
                "query_failed hardware has invalid fields"
            )
            let message = try container.decode(String.self, forKey: .message)
            try engineProfileRequireNonempty(message, "message")
            self = .queryFailed(message)
        case .gpu:
            try engineProfileRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == [
                    "kind", "name", "adapter_id", "device_id", "driver_version", "dedicated_vram_bytes"
                ],
                "gpu hardware has invalid fields"
            )
            let name = try container.decode(String.self, forKey: .name)
            let adapterID = try container.decode(String.self, forKey: .adapterID)
            let deviceID = try container.decode(String.self, forKey: .deviceID)
            let driverVersion = try container.decode(String.self, forKey: .driverVersion)
            let dedicatedVRAMBytes = try container.decode(EngineNullable<UInt64>.self, forKey: .dedicatedVRAMBytes).wrappedValue
            try engineProfileRequireNonempty(name, "name")
            try engineProfileRequireNonempty(adapterID, "adapter_id")
            try engineProfileRequireNonempty(deviceID, "device_id")
            try engineProfileRequireNonempty(driverVersion, "driver_version")
            self = .gpu(
                name: name,
                adapterID: adapterID,
                deviceID: deviceID,
                driverVersion: driverVersion,
                dedicatedVRAMBytes: dedicatedVRAMBytes
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .noGPU:
            break
        case let .queryFailed(message):
            try container.encode(message, forKey: .message)
        case let .gpu(name, adapterID, deviceID, driverVersion, dedicatedVRAMBytes):
            try container.encode(name, forKey: .name)
            try container.encode(adapterID, forKey: .adapterID)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(driverVersion, forKey: .driverVersion)
            try container.encode(EngineNullable(wrappedValue: dedicatedVRAMBytes), forKey: .dedicatedVRAMBytes)
        }
    }
}

public enum EngineProfileAcquisition: Codable, Equatable, Sendable {
    case unavailable
    case failed(String)
    case acquired(EngineProfileProvider)

    private enum Kind: String, Codable {
        case unavailable
        case failed
        case acquired

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw EngineProtocolError.invalidJSON("unknown profile acquisition kind")
            }
            self = value
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case message
        case provider
    }

    private var kind: Kind {
        switch self {
        case .unavailable: .unavailable
        case .failed: .failed
        case .acquired: .acquired
        }
    }

    private func validate() throws {
        if case let .failed(message) = self {
            try engineProfileRequireNonempty(message, "message")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: EngineCodingKey.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .unavailable:
            try engineProfileRequire(Set(dynamic.allKeys.map(\.stringValue)) == ["kind"], "unavailable acquisition has invalid fields")
            self = .unavailable
        case .failed:
            try engineProfileRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == ["kind", "message"],
                "failed acquisition has invalid fields"
            )
            let message = try container.decode(String.self, forKey: .message)
            try engineProfileRequireNonempty(message, "message")
            self = .failed(message)
        case .acquired:
            try engineProfileRequire(
                Set(dynamic.allKeys.map(\.stringValue)) == ["kind", "provider"],
                "acquired acquisition has invalid fields"
            )
            self = .acquired(try container.decode(EngineProfileProvider.self, forKey: .provider))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .unavailable:
            break
        case let .failed(message):
            try container.encode(message, forKey: .message)
        case let .acquired(provider):
            try container.encode(provider, forKey: .provider)
        }
    }
}

public struct EngineProfilesEvaluatePayload: Codable, Equatable, Sendable {
    public let hardware: EngineProfileHardware
    public let acquisition: EngineProfileAcquisition
    public let threads: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hardware
        case acquisition
        case threads
    }

    public init(hardware: EngineProfileHardware, acquisition: EngineProfileAcquisition, threads: Int) throws {
        try engineProfileRequire((1...4).contains(threads), "threads must be between 1 and 4")
        self.hardware = hardware
        self.acquisition = acquisition
        self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            hardware: container.decode(EngineProfileHardware.self, forKey: .hardware),
            acquisition: container.decode(EngineProfileAcquisition.self, forKey: .acquisition),
            threads: container.decode(Int.self, forKey: .threads)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try engineProfileRequire((1...4).contains(threads), "threads must be between 1 and 4")
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hardware, forKey: .hardware)
        try container.encode(acquisition, forKey: .acquisition)
        try container.encode(threads, forKey: .threads)
    }
}

public struct EngineProfileEvaluation: Codable, Equatable, Sendable {
    public let initialSize: EngineASRSize
    public let recommendLarge: Bool
    public let reason: EngineProfileSelectionReason
    public let explanation: String
    @EngineNullable public private(set) var measuredRTF: Double?
    @EngineNullable public private(set) var predictedRTF: Double?
    public let decisionState: EngineProfileDecisionState
    @EngineNullable public private(set) var requestedChoice: EngineProfileChoice?
    @EngineNullable public private(set) var calibrationID: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case initialSize = "initial_size"
        case recommendLarge = "recommend_large"
        case reason
        case explanation
        case measuredRTF = "measured_rtf"
        case predictedRTF = "predicted_rtf"
        case decisionState = "decision_state"
        case requestedChoice = "requested_choice"
        case calibrationID = "calibration_id"
    }

    public init(
        initialSize: EngineASRSize,
        recommendLarge: Bool,
        reason: EngineProfileSelectionReason,
        explanation: String,
        measuredRTF: Double?,
        predictedRTF: Double?,
        decisionState: EngineProfileDecisionState,
        requestedChoice: EngineProfileChoice?,
        calibrationID: String?
    ) throws {
        try Self.validate(
            initialSize: initialSize,
            recommendLarge: recommendLarge,
            reason: reason,
            explanation: explanation,
            measuredRTF: measuredRTF,
            predictedRTF: predictedRTF,
            calibrationID: calibrationID
        )
        self.initialSize = initialSize
        self.recommendLarge = recommendLarge
        self.reason = reason
        self.explanation = explanation
        _measuredRTF = EngineNullable(wrappedValue: measuredRTF)
        _predictedRTF = EngineNullable(wrappedValue: predictedRTF)
        self.decisionState = decisionState
        _requestedChoice = EngineNullable(wrappedValue: requestedChoice)
        _calibrationID = EngineNullable(wrappedValue: calibrationID)
    }

    private static func validate(
        initialSize: EngineASRSize,
        recommendLarge: Bool,
        reason: EngineProfileSelectionReason,
        explanation: String,
        measuredRTF: Double?,
        predictedRTF: Double?,
        calibrationID: String?
    ) throws {
        try engineProfileRequire(initialSize == .small, "initial_size must be small")
        try engineProfileRequireNonempty(explanation, "explanation")
        try engineProfileRequire(recommendLarge == (reason == .recommendLarge), "recommend_large must match reason")
        if let measuredRTF {
            try engineProfileRequire(measuredRTF.isFinite && measuredRTF > 0, "measured_rtf must be finite and positive")
        }
        if let predictedRTF {
            try engineProfileRequire(predictedRTF.isFinite && predictedRTF > 0, "predicted_rtf must be finite and positive")
        }
        if let calibrationID {
            try engineProfileRequireNonempty(calibrationID, "calibration_id")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            initialSize: container.decode(EngineASRSize.self, forKey: .initialSize),
            recommendLarge: container.decode(Bool.self, forKey: .recommendLarge),
            reason: container.decode(EngineProfileSelectionReason.self, forKey: .reason),
            explanation: container.decode(String.self, forKey: .explanation),
            measuredRTF: container.decode(EngineNullable<Double>.self, forKey: .measuredRTF).wrappedValue,
            predictedRTF: container.decode(EngineNullable<Double>.self, forKey: .predictedRTF).wrappedValue,
            decisionState: container.decode(EngineProfileDecisionState.self, forKey: .decisionState),
            requestedChoice: container.decode(EngineNullable<EngineProfileChoice>.self, forKey: .requestedChoice).wrappedValue,
            calibrationID: container.decode(EngineNullable<String>.self, forKey: .calibrationID).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(
            initialSize: initialSize,
            recommendLarge: recommendLarge,
            reason: reason,
            explanation: explanation,
            measuredRTF: measuredRTF,
            predictedRTF: predictedRTF,
            calibrationID: calibrationID
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(initialSize, forKey: .initialSize)
        try container.encode(recommendLarge, forKey: .recommendLarge)
        try container.encode(reason, forKey: .reason)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(_measuredRTF, forKey: .measuredRTF)
        try container.encode(_predictedRTF, forKey: .predictedRTF)
        try container.encode(decisionState, forKey: .decisionState)
        try container.encode(_requestedChoice, forKey: .requestedChoice)
        try container.encode(_calibrationID, forKey: .calibrationID)
    }
}

public struct EngineProfileSetup: Codable, Equatable, Sendable {
    @EngineNullable public private(set) var evaluation: EngineProfileEvaluation?
    @EngineNullable public private(set) var operation: EngineProfileSetupOperation?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case evaluation
        case operation
    }

    public init(evaluation: EngineProfileEvaluation?, operation: EngineProfileSetupOperation?) {
        _evaluation = EngineNullable(wrappedValue: evaluation)
        _operation = EngineNullable(wrappedValue: operation)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(
            evaluation: try container.decode(EngineNullable<EngineProfileEvaluation>.self, forKey: .evaluation).wrappedValue,
            operation: try container.decode(EngineNullable<EngineProfileSetupOperation>.self, forKey: .operation).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_evaluation, forKey: .evaluation)
        try container.encode(_operation, forKey: .operation)
    }
}
