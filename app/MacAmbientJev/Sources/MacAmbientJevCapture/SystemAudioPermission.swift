import CoreFoundation
import Dispatch
import Foundation
import Darwin

public enum SystemAudioPermissionStatus: Sendable {
    case authorized, denied, notDetermined
}

public enum SystemAudioPermissionResult: Sendable {
    case authorized, grantedNow, unavailable
}

public protocol SystemAudioPermissionProviding: Sendable {
    /// nil means the private SPI is absent or returned an unknown status.
    func preflight() async -> SystemAudioPermissionStatus?
    func request() async -> Bool
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

    public func preflight() async -> SystemAudioPermissionStatus? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let preflightSymbol, requestSymbol != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let status: SystemAudioPermissionStatus? = switch preflightSymbol(service, nil) {
                case 0: .authorized
                case 1: .denied
                case 2: .notDetermined
                default: nil
                }
                continuation.resume(returning: status)
            }
        }
    }

    public func request() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let requestSymbol else {
                    continuation.resume(returning: false)
                    return
                }
                requestSymbol(service, nil, { granted in
                    continuation.resume(returning: granted)
                })
            }
        }
    }
}
