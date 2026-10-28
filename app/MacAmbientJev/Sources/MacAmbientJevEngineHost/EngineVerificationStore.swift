import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

public struct EngineVerificationKey: Codable, Equatable, Sendable {
    public let gpuName, driverVersion, adapterID, deviceID: String
    public let architecture, epPackageHash, epLibraryHash, ortVersion: String
    public let modelRevision, modelSize, decodingSettings, fixtureHash: String
    public let verificationPolicyVersion: String
    public let threads: Int

    public init(
        gpuName: String, driverVersion: String, adapterID: String, deviceID: String,
        architecture: String, epPackageHash: String, epLibraryHash: String, ortVersion: String,
        modelRevision: String, modelSize: String, decodingSettings: String, fixtureHash: String,
        verificationPolicyVersion: String, threads: Int
    ) {
        self.gpuName = gpuName; self.driverVersion = driverVersion
        self.adapterID = adapterID; self.deviceID = deviceID
        self.architecture = architecture; self.epPackageHash = epPackageHash
        self.epLibraryHash = epLibraryHash; self.ortVersion = ortVersion
        self.modelRevision = modelRevision; self.modelSize = modelSize
        self.decodingSettings = decodingSettings; self.fixtureHash = fixtureHash
        self.verificationPolicyVersion = verificationPolicyVersion
        self.threads = threads
    }
}

public struct EngineVerificationReceipt: Codable, Equatable, Sendable {
    public let key: EngineVerificationKey
    public let observedOutput: String
    public let passed: Bool
    public let rtf: Double
    public let timestamp: Date

    public init(key: EngineVerificationKey, observedOutput: String, passed: Bool, rtf: Double, timestamp: Date) {
        self.key = key; self.observedOutput = observedOutput
        self.passed = passed; self.rtf = rtf; self.timestamp = timestamp
    }
}

public enum EngineVerificationStoreError: Error {
    case corrupt(path: String, reason: String)
    case invalid(String)
}

public struct EngineVerificationStore: Sendable {
    private let root: URL

    public init(paths: AppPaths) { self.root = paths.root }

    public func load(for key: EngineVerificationKey) throws -> EngineVerificationReceipt? {
        let identifier = try Self.identifier(for: key), url = receiptURL(identifier)
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: root) else { return nil }

        let receipt: EngineVerificationReceipt
        do {
            try EngineJSONValidator.validate(data)
            receipt = try JSONDecoder().decode(EngineVerificationReceipt.self, from: data)
            try Self.validate(receipt)
        } catch {
            throw EngineVerificationStoreError.corrupt(path: url.path, reason: String(describing: error))
        }
        guard try Self.identifier(for: receipt.key) == identifier else {
            throw EngineVerificationStoreError.corrupt(path: url.path, reason: "embedded key does not match the requested key")
        }
        return receipt
    }

    @discardableResult
    public func publish(_ receipt: EngineVerificationReceipt) throws -> String {
        let identifier = try Self.identifier(for: receipt.key)
        try Self.validate(receipt)

        let data = try Self.makeEncoder().encode(receipt)

        let directory = root.appending(path: "accelerators", directoryHint: .isDirectory)
        let url = receiptURL(identifier)
        try SessionFileAccess.createDirectory(root, relativeTo: root)
        try SessionFileAccess.createDirectory(directory, relativeTo: root)
        try SessionFileAccess.writeAtomically(data, to: url, relativeTo: root)
        return identifier
    }

    private func receiptURL(_ identifier: String) -> URL {
        root.appending(path: "accelerators", directoryHint: .isDirectory)
            .appending(path: "\(identifier).json", directoryHint: .notDirectory)
    }

    private static func identifier(for key: EngineVerificationKey) throws -> String {
        FileSHA256.hexDigest(of: try makeEncoder().encode(key))
    }

    private static func validate(_ receipt: EngineVerificationReceipt) throws {
        guard receipt.rtf.isFinite, receipt.rtf > 0 else {
            throw EngineVerificationStoreError.invalid("rtf must be finite and positive")
        }
        guard receipt.timestamp.timeIntervalSince1970.isFinite else {
            throw EngineVerificationStoreError.invalid("timestamp must be finite")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
