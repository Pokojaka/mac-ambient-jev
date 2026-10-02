import CoreFoundation
import Dispatch
import Foundation
import Darwin

public enum SystemAudioPermissionStatus: Sendable {
    case authorized, denied, notDetermined
}

public enum SystemAudioPermissionResult: Sendable {
    case authorized, grantedNow
}

public enum SystemAudioPermissionError: LocalizedError, Equatable {
    /// The TCC SPI is absent or reported a status this app does not know.
    case unverifiable

    public var errorDescription: String? {
        "システム音声の権限を確認できません。このmacOSではシステム音声を録音できません"
    }
}

public protocol SystemAudioPermissionProviding: Sendable {
    func preflight() async throws(SystemAudioPermissionError) -> SystemAudioPermissionStatus
    func request() async throws(SystemAudioPermissionError) -> Bool
}

/// TCC's preflight caches its first result in-process, including denials.
/// A denied preflight must still request; use its callback answer without preflighting again.
public final class TCCSystemAudioPermission: SystemAudioPermissionProviding, @unchecked Sendable {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Completion = @convention(block) (Bool) -> Void
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping Completion) -> Void
    private let service = CFStringCreateWithCString(
        kCFAllocatorDefault, "kTCCServiceAudioCapture", CFStringBuiltInEncodings.UTF8.rawValue
    )!
    private let queue = DispatchQueue(label: "app.mac-ambient-jev.tcc-audio", qos: .utility)
    private let handle: UnsafeMutableRawPointer?
    private let preflightSymbol: Preflight?
    private let requestSymbol: Request?

    public init() {
        let library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY | RTLD_LOCAL)
        handle = library
        if let library, let pointer = dlsym(library, "TCCAccessPreflight") {
            preflightSymbol = unsafeBitCast(pointer, to: Preflight.self)
        } else {
            preflightSymbol = nil
        }
        if let library, let pointer = dlsym(library, "TCCAccessRequest") {
            requestSymbol = unsafeBitCast(pointer, to: Request.self)
        } else {
            requestSymbol = nil
        }
    }

    deinit { if let handle { dlclose(handle) } }

    public func preflight() async throws(SystemAudioPermissionError) -> SystemAudioPermissionStatus {
        guard let preflightSymbol, requestSymbol != nil else { throw .unverifiable }
        let raw = await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: preflightSymbol(service, nil))
            }
        }
        switch raw {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: throw .unverifiable
        }
    }

    public func request() async throws(SystemAudioPermissionError) -> Bool {
        guard let requestSymbol else { throw .unverifiable }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                requestSymbol(service, nil, { granted in
                    continuation.resume(returning: granted)
                })
            }
        }
    }
}
