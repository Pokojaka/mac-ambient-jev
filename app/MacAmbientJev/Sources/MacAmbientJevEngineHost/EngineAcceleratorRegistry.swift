import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol

/// Binds a validated accelerator package and returns its available accelerator devices.
/// Implementations validate the actual package full name, library and dependency hashes,
/// package architecture, and the complete dependency closure (at most 64 files and 16 directories).
/// Returned devices expose only GPU or NPU hardware, with engine-owned stable keys and actual
/// driver and memory identities. Binding must never substitute CPU and must remain registered for
/// every returned device and its ASR engines/sessions.
public protocol EngineAcceleratorRegistry: Sendable {
    func bind(_ descriptor: EngineAcceleratorDescriptor) async throws -> [any EngineAcceleratorDevice]
}

/// An accelerator device exposing its actual runtime, model, and hardware identities.
public protocol EngineAcceleratorDevice: Sendable {
    var info: EngineAcceleratorDeviceInfo { get }
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

    public func bind(_ descriptor: EngineAcceleratorDescriptor) async throws -> [any EngineAcceleratorDevice] {
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
