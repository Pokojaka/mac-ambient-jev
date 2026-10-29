import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

/// Registers validated accelerator packages and selects one exact provider/device pair.
/// Implementations validate package identity, hashes, architecture, and the complete dependency
/// closure during registration. They must keep the registration alive for every returned device
/// and ASR engine/session. Accelerated ASR must never fall back to CPU, and must honor—not ignore—
/// the requested language and decoding settings.
public protocol EngineAcceleratorRegistry: Sendable {
    func registerLibrary(_ descriptor: EngineAcceleratorDescriptor) async throws

    /// Returns only the requested provider/device pair; never substitutes another device.
    func selectDevice(providerName: String, deviceID: String) async throws -> any EngineAcceleratorDevice
}

/// An accelerator device exposing its actual runtime and model identities.
public protocol EngineAcceleratorDevice: Sendable {
    var ortVersion: String { get }
    var modelRevision: String { get }

    /// Creates an accelerated ASR engine using every supplied setting without CPU fallback.
    func makeASREngine(
        size: ASRModelSize,
        threads: Int,
        language: String,
        maxNewTokens: Int,
        noRepeatNgramSize: Int?
    ) async throws -> any ASREngine
}

/// Explicit production failure for builds without an accelerator implementation.
public struct EngineUnavailableAcceleratorRegistry: EngineAcceleratorRegistry {
    public init() {}

    public func registerLibrary(_ descriptor: EngineAcceleratorDescriptor) async throws {
        throw unavailableError
    }

    public func selectDevice(providerName: String, deviceID: String) async throws -> any EngineAcceleratorDevice {
        throw unavailableError
    }

    private var unavailableError: EngineAdapterError {
        EngineAdapterError(
            code: .modelFailure,
            message: "アクセラレーターはこのビルドでは利用できません",
            recoveryAction: .none,
            details: []
        )
    }
}
