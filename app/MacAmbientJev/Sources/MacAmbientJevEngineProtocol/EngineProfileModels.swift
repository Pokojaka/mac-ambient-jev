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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case initialSize = "initial_size"
        case recommendLarge = "recommend_large"
        case reason
        case explanation
        case measuredRTF = "measured_rtf"
        case predictedRTF = "predicted_rtf"
    }

    public init(
        initialSize: EngineASRSize,
        recommendLarge: Bool,
        reason: EngineProfileSelectionReason,
        explanation: String,
        measuredRTF: Double?,
        predictedRTF: Double?
    ) throws {
        try Self.validate(
            initialSize: initialSize,
            recommendLarge: recommendLarge,
            reason: reason,
            explanation: explanation,
            measuredRTF: measuredRTF,
            predictedRTF: predictedRTF
        )
        self.initialSize = initialSize
        self.recommendLarge = recommendLarge
        self.reason = reason
        self.explanation = explanation
        _measuredRTF = EngineNullable(wrappedValue: measuredRTF)
        _predictedRTF = EngineNullable(wrappedValue: predictedRTF)
    }

    private static func validate(
        initialSize: EngineASRSize,
        recommendLarge: Bool,
        reason: EngineProfileSelectionReason,
        explanation: String,
        measuredRTF: Double?,
        predictedRTF: Double?
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
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            initialSize: container.decode(EngineASRSize.self, forKey: .initialSize),
            recommendLarge: container.decode(Bool.self, forKey: .recommendLarge),
            reason: container.decode(EngineProfileSelectionReason.self, forKey: .reason),
            explanation: container.decode(String.self, forKey: .explanation),
            measuredRTF: container.decode(EngineNullable<Double>.self, forKey: .measuredRTF).wrappedValue,
            predictedRTF: container.decode(EngineNullable<Double>.self, forKey: .predictedRTF).wrappedValue
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(
            initialSize: initialSize,
            recommendLarge: recommendLarge,
            reason: reason,
            explanation: explanation,
            measuredRTF: measuredRTF,
            predictedRTF: predictedRTF
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(initialSize, forKey: .initialSize)
        try container.encode(recommendLarge, forKey: .recommendLarge)
        try container.encode(reason, forKey: .reason)
        try container.encode(explanation, forKey: .explanation)
        try container.encode(_measuredRTF, forKey: .measuredRTF)
        try container.encode(_predictedRTF, forKey: .predictedRTF)
    }
}

public struct EngineProfileSetup: Codable, Equatable, Sendable {
    @EngineNullable public private(set) var evaluation: EngineProfileEvaluation?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case evaluation
    }

    public init(evaluation: EngineProfileEvaluation?) {
        _evaluation = EngineNullable(wrappedValue: evaluation)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        self.init(evaluation: try container.decode(EngineNullable<EngineProfileEvaluation>.self, forKey: .evaluation).wrappedValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_evaluation, forKey: .evaluation)
    }
}
