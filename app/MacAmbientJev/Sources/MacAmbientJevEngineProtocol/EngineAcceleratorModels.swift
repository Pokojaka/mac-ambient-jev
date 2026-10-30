import Foundation

private func engineAcceleratorRequire(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw EngineProtocolError.invalidJSON(reason) }
}

private func engineAcceleratorRequireNonempty(_ value: String, _ field: String) throws {
    try engineAcceleratorRequire(!value.isEmpty, "\(field) must not be empty")
}

private func engineAcceleratorValidateHash(_ value: String, _ field: String) throws {
    let bytes = value.utf8
    try engineAcceleratorRequire(
        bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) },
        "\(field) must be 64 lowercase hexadecimal characters"
    )
}

public struct EngineAcceleratorDependency: Codable, Equatable, Sendable {
    public let path: String
    public let hash: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case path, hash }

    public init(path: String, hash: String) throws {
        try engineAcceleratorRequireNonempty(path, "path")
        try engineAcceleratorValidateHash(hash, "hash")
        self.path = path
        self.hash = hash
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(path: container.decode(String.self, forKey: .path), hash: container.decode(String.self, forKey: .hash))
    }
}

public struct EngineAcceleratorDescriptor: Codable, Equatable, Sendable {
    public let providerName, packageFullName, packageArchitecture: String
    public let libraryPath, libraryHash: String
    public let dependencies: [EngineAcceleratorDependency]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerName = "provider_name", packageFullName = "package_full_name"
        case packageArchitecture = "package_architecture", libraryPath = "library_path", libraryHash = "library_hash"
        case dependencies
    }

    public init(
        providerName: String, packageFullName: String, packageArchitecture: String,
        libraryPath: String, libraryHash: String, dependencies: [EngineAcceleratorDependency]
    ) throws {
        try engineAcceleratorRequireNonempty(providerName, "provider_name")
        try engineAcceleratorRequireNonempty(packageFullName, "package_full_name")
        try engineAcceleratorRequire(packageArchitecture == "x64" || packageArchitecture == "arm64", "package_architecture must be x64 or arm64")
        try engineAcceleratorRequireNonempty(libraryPath, "library_path")
        try engineAcceleratorValidateHash(libraryHash, "library_hash")
        try engineAcceleratorRequire(dependencies.count <= 64, "dependencies must contain at most 64 entries")
        self.providerName = providerName
        self.packageFullName = packageFullName
        self.packageArchitecture = packageArchitecture
        self.libraryPath = libraryPath
        self.libraryHash = libraryHash
        self.dependencies = dependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            providerName: container.decode(String.self, forKey: .providerName),
            packageFullName: container.decode(String.self, forKey: .packageFullName),
            packageArchitecture: container.decode(String.self, forKey: .packageArchitecture),
            libraryPath: container.decode(String.self, forKey: .libraryPath),
            libraryHash: container.decode(String.self, forKey: .libraryHash),
            dependencies: container.decode([EngineAcceleratorDependency].self, forKey: .dependencies)
        )
    }
}

public struct EngineAcceleratorDeviceInfo: Codable, Equatable, Sendable {
    public let deviceKey, type, description, driverVersion: String
    @EngineNullable public private(set) var dedicatedMemoryBytes: UInt64?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case deviceKey = "device_key", type, description
        case driverVersion = "driver_version", dedicatedMemoryBytes = "dedicated_memory_bytes"
    }

    public init(
        deviceKey: String, type: String, description: String, driverVersion: String,
        dedicatedMemoryBytes: UInt64?
    ) throws {
        try engineAcceleratorRequire(type == "gpu" || type == "npu", "type must be gpu or npu")
        try engineAcceleratorRequire(
            deviceKey.range(of: "^\(type):[0-9a-f]{4}:[0-9a-f]{4}\\z", options: .regularExpression) != nil,
            "device_key must match type:xxxx:xxxx using lowercase hexadecimal"
        )
        try engineAcceleratorRequireNonempty(description, "description")
        try engineAcceleratorRequireNonempty(driverVersion, "driver_version")
        try engineAcceleratorRequire(type != "gpu" || dedicatedMemoryBytes != nil, "dedicated_memory_bytes must not be null for GPUs")
        self.deviceKey = deviceKey
        self.type = type
        self.description = description
        self.driverVersion = driverVersion
        _dedicatedMemoryBytes = EngineNullable(wrappedValue: dedicatedMemoryBytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            deviceKey: container.decode(String.self, forKey: .deviceKey),
            type: container.decode(String.self, forKey: .type),
            description: container.decode(String.self, forKey: .description),
            driverVersion: container.decode(String.self, forKey: .driverVersion),
            dedicatedMemoryBytes: container.decode(EngineNullable<UInt64>.self, forKey: .dedicatedMemoryBytes).wrappedValue
        )
    }
}

public struct EngineAcceleratorsBindPayload: Codable, Equatable, Sendable {
    public let descriptor: EngineAcceleratorDescriptor
    private enum CodingKeys: String, CodingKey, CaseIterable { case descriptor }

    public init(descriptor: EngineAcceleratorDescriptor) throws {
        self.descriptor = descriptor
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(descriptor: container.decode(EngineAcceleratorDescriptor.self, forKey: .descriptor))
    }
}

public struct EngineAcceleratorsBindResult: Codable, Equatable, Sendable {
    public let bindingID: String
    public let devices: [EngineAcceleratorDeviceInfo]
    private enum CodingKeys: String, CodingKey, CaseIterable { case bindingID = "binding_id", devices }

    public init(bindingID: String, devices: [EngineAcceleratorDeviceInfo]) throws {
        try engineAcceleratorRequireNonempty(bindingID, "binding_id")
        self.bindingID = bindingID
        self.devices = devices
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            bindingID: container.decode(String.self, forKey: .bindingID),
            devices: container.decode([EngineAcceleratorDeviceInfo].self, forKey: .devices)
        )
    }
}

public struct EngineAcceleratorsVerifyPayload: Codable, Equatable, Sendable {
    public let bindingID, deviceKey: String
    public let asrSize: EngineASRSize
    public let threads: Int
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bindingID = "binding_id", deviceKey = "device_key", asrSize = "asr_size", threads
    }

    public init(bindingID: String, deviceKey: String, asrSize: EngineASRSize, threads: Int) throws {
        try engineAcceleratorRequireNonempty(bindingID, "binding_id")
        try engineAcceleratorRequireNonempty(deviceKey, "device_key")
        try engineAcceleratorRequire((1...4).contains(threads), "threads must be between 1 and 4")
        self.bindingID = bindingID
        self.deviceKey = deviceKey
        self.asrSize = asrSize
        self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            bindingID: container.decode(String.self, forKey: .bindingID),
            deviceKey: container.decode(String.self, forKey: .deviceKey),
            asrSize: container.decode(EngineASRSize.self, forKey: .asrSize),
            threads: container.decode(Int.self, forKey: .threads)
        )
    }
}

public enum EngineAcceleratorsVerifyResult: Codable, Equatable, Sendable {
    case pass(verificationID: String, rtf: Double)
    case fail(verificationID: String, reason: String, observedOutput: String)

    private enum Kind: String, Codable {
        case pass
        case fail
        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            guard let value = Self(rawValue: rawValue) else { throw EngineProtocolError.invalidJSON("unknown accelerator verification result") }
            self = value
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case result, verificationID = "verification_id", rtf
        case reason, observedOutput = "observed_output"
    }

    private func validate() throws {
        switch self {
        case let .pass(verificationID, rtf):
            try engineAcceleratorRequireNonempty(verificationID, "verification_id")
            try engineAcceleratorRequire(rtf.isFinite && rtf > 0, "rtf must be finite and positive")
        case let .fail(verificationID, reason, _):
            try engineAcceleratorRequireNonempty(verificationID, "verification_id")
            try engineAcceleratorRequireNonempty(reason, "reason")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: EngineCodingKey.self)
        switch try container.decode(Kind.self, forKey: .result) {
        case .pass:
            try engineAcceleratorRequire(Set(dynamic.allKeys.map(\.stringValue)) == ["result", "verification_id", "rtf"], "pass result has invalid fields")
            self = .pass(
                verificationID: try container.decode(String.self, forKey: .verificationID),
                rtf: try container.decode(Double.self, forKey: .rtf)
            )
        case .fail:
            try engineAcceleratorRequire(Set(dynamic.allKeys.map(\.stringValue)) == ["result", "verification_id", "reason", "observed_output"], "fail result has invalid fields")
            self = .fail(
                verificationID: try container.decode(String.self, forKey: .verificationID),
                reason: try container.decode(String.self, forKey: .reason),
                observedOutput: try container.decode(String.self, forKey: .observedOutput)
            )
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pass(verificationID, rtf):
            try container.encode(Kind.pass, forKey: .result)
            try container.encode(verificationID, forKey: .verificationID)
            try container.encode(rtf, forKey: .rtf)
        case let .fail(verificationID, reason, observedOutput):
            try container.encode(Kind.fail, forKey: .result)
            try container.encode(verificationID, forKey: .verificationID)
            try container.encode(reason, forKey: .reason)
            try container.encode(observedOutput, forKey: .observedOutput)
        }
    }
}

public enum EngineProfileChoice: String, Codable, CaseIterable, Equatable, Sendable {
    case small
    case large

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else { throw EngineProtocolError.invalidJSON("unknown engine profile choice") }
        self = value
    }
}

public struct EngineProfilesDecidePayload: Codable, Equatable, Sendable {
    public let expectedRevision: EngineID
    public let choice: EngineProfileChoice
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case expectedRevision = "expected_revision", choice
    }

    public init(expectedRevision: EngineID, choice: EngineProfileChoice) throws {
        self.expectedRevision = expectedRevision
        self.choice = choice
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            expectedRevision: container.decode(EngineID.self, forKey: .expectedRevision),
            choice: container.decode(EngineProfileChoice.self, forKey: .choice)
        )
    }
}
