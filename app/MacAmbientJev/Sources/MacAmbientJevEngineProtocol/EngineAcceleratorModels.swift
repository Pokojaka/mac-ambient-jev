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
    public let providerName, deviceID, gpuName, driverVersion, adapterID, architecture: String
    @EngineNullable public private(set) var dedicatedVRAMBytes: UInt64?
    public let packageIdentity, libraryPath, libraryHash: String
    public let dependencies: [EngineAcceleratorDependency]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case providerName = "provider_name", deviceID = "device_id", gpuName = "gpu_name"
        case driverVersion = "driver_version", adapterID = "adapter_id", architecture
        case dedicatedVRAMBytes = "dedicated_vram_bytes"
        case packageIdentity = "package_identity", libraryPath = "library_path", libraryHash = "library_hash"
        case dependencies
    }

    private static func validate(
        providerName: String, deviceID: String, gpuName: String, driverVersion: String,
        adapterID: String, architecture: String, packageIdentity: String, libraryPath: String,
        libraryHash: String, dependencies: [EngineAcceleratorDependency]
    ) throws {
        try engineAcceleratorRequireNonempty(providerName, "provider_name")
        try engineAcceleratorRequireNonempty(deviceID, "device_id")
        try engineAcceleratorRequireNonempty(gpuName, "gpu_name")
        try engineAcceleratorRequireNonempty(driverVersion, "driver_version")
        try engineAcceleratorRequireNonempty(adapterID, "adapter_id")
        try engineAcceleratorRequire(architecture == "x64" || architecture == "arm64", "architecture must be x64 or arm64")
        try engineAcceleratorRequireNonempty(packageIdentity, "package_identity")
        try engineAcceleratorRequireNonempty(libraryPath, "library_path")
        try engineAcceleratorValidateHash(libraryHash, "library_hash")
        try engineAcceleratorRequire(dependencies.count <= 64, "dependencies must contain at most 64 entries")

    }

    public init(
        providerName: String, deviceID: String, gpuName: String, driverVersion: String,
        adapterID: String, architecture: String, dedicatedVRAMBytes: UInt64?, packageIdentity: String,
        libraryPath: String, libraryHash: String, dependencies: [EngineAcceleratorDependency]
    ) throws {
        try Self.validate(
            providerName: providerName, deviceID: deviceID, gpuName: gpuName, driverVersion: driverVersion,
            adapterID: adapterID, architecture: architecture, packageIdentity: packageIdentity,
            libraryPath: libraryPath, libraryHash: libraryHash, dependencies: dependencies
        )
        self.providerName = providerName
        self.deviceID = deviceID
        self.gpuName = gpuName
        self.driverVersion = driverVersion
        self.adapterID = adapterID
        self.architecture = architecture
        _dedicatedVRAMBytes = EngineNullable(wrappedValue: dedicatedVRAMBytes)
        self.packageIdentity = packageIdentity
        self.libraryPath = libraryPath
        self.libraryHash = libraryHash
        self.dependencies = dependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            providerName: container.decode(String.self, forKey: .providerName),
            deviceID: container.decode(String.self, forKey: .deviceID),
            gpuName: container.decode(String.self, forKey: .gpuName),
            driverVersion: container.decode(String.self, forKey: .driverVersion),
            adapterID: container.decode(String.self, forKey: .adapterID),
            architecture: container.decode(String.self, forKey: .architecture),
            dedicatedVRAMBytes: container.decode(EngineNullable<UInt64>.self, forKey: .dedicatedVRAMBytes).wrappedValue,
            packageIdentity: container.decode(String.self, forKey: .packageIdentity),
            libraryPath: container.decode(String.self, forKey: .libraryPath),
            libraryHash: container.decode(String.self, forKey: .libraryHash),
            dependencies: container.decode([EngineAcceleratorDependency].self, forKey: .dependencies)
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
    private enum CodingKeys: String, CodingKey, CaseIterable { case bindingID = "binding_id" }

    public init(bindingID: String) throws {
        try engineAcceleratorRequireNonempty(bindingID, "binding_id")
        self.bindingID = bindingID
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(bindingID: container.decode(String.self, forKey: .bindingID))
    }
}

public struct EngineAcceleratorsVerifyPayload: Codable, Equatable, Sendable {
    public let bindingID: String
    public let asrSize: EngineASRSize
    public let threads: Int
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bindingID = "binding_id", asrSize = "asr_size", threads
    }

    public init(bindingID: String, asrSize: EngineASRSize, threads: Int) throws {
        try engineAcceleratorRequireNonempty(bindingID, "binding_id")
        try engineAcceleratorRequire((1...4).contains(threads), "threads must be between 1 and 4")
        self.bindingID = bindingID
        self.asrSize = asrSize
        self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: CodingKeys.self)
        try self.init(
            bindingID: container.decode(String.self, forKey: .bindingID),
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
