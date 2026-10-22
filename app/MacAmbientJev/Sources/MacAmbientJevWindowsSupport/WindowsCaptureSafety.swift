import Foundation
#if os(Windows)
import CMiniaudio
#endif
import MacAmbientJevPipeline

public enum WindowsCaptureAdapterError: Error, LocalizedError, Sendable, Equatable {
    case native(operation: String, code: Int32)
    case invalidConfiguration(String)
    case diskOverflow
    case timestamp(String)
    case health(String)
    case combined([String])

    public var errorDescription: String? {
        switch self {
        case .native(let operation, let code):
            "Native operation \(operation) failed with code \(code)"
        case .invalidConfiguration(let details):
            "Invalid capture configuration: \(details)"
        case .diskOverflow:
            "Available disk space exceeds Int64.max"
        case .timestamp(let details):
            "Capture timestamp error: \(details)"
        case .health(let details):
            "Capture health error: \(details)"
        case .combined(let details):
            "Multiple capture errors: \(details.joined(separator: "; "))"
        }
    }
}

/// Disk-space queries for an explicit absolute file-system directory.
///
/// The native implementation delegates to `GetDiskFreeSpaceExW`, whose BOOL result is
/// paired with `GetLastError` on failure. The C boundary validates the supplied directory;
/// this adapter never substitutes the current drive or an assumed free-space value.
/// See [GetDiskFreeSpaceExW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getdiskfreespaceexw).
public struct WindowsCaptureDiskSpaceProvider: CaptureDiskSpaceProviding {
    private let query: @Sendable (URL) throws -> UInt64

    /// Creates an injectable disk-space provider for deterministic tests.
    public init(query: @escaping @Sendable (URL) throws -> UInt64) {
        self.query = query
    }

    #if os(Windows)
    /// Creates a provider backed by the native Windows disk-space API.
    public init() {
        query = { url in try Self.nativeAvailableBytes(at: url) }
    }
    #endif

    public func availableBytes(at url: URL) throws -> Int64? {
        let path = url.path
        guard url.isFileURL, Self.isAbsoluteFilePath(path), !path.isEmpty, !path.contains("\0") else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Disk-space queries require an absolute file URL with a nonempty path and no embedded NUL"
            )
        }

        let bytes = try query(url)
        guard bytes <= UInt64(Int64.max) else {
            throw WindowsCaptureAdapterError.diskOverflow
        }
        return Int64(bytes)
    }

    private static func isAbsoluteFilePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        if path.hasPrefix("\\\\"), path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).count >= 2 {
            return true
        }

        let units = Array(path.utf16)
        guard units.count >= 3 else { return false }
        let isDriveLetter = (units[0] >= 65 && units[0] <= 90) || (units[0] >= 97 && units[0] <= 122)
        let isSeparator = units[2] == 47 || units[2] == 92
        return isDriveLetter && units[1] == 58 && isSeparator
    }

    #if os(Windows)
    private static func nativeAvailableBytes(at url: URL) throws -> UInt64 {
        var path = Array(url.path.utf16)
        path.append(0)
        var available: UInt64 = 0
        let result = path.withUnsafeBufferPointer { buffer in
            mja_capture_disk_free(buffer.baseAddress!, &available)
        }
        guard result == 0 else {
            throw WindowsCaptureAdapterError.native(operation: "GetDiskFreeSpaceExW", code: result)
        }
        return available
    }
    #endif
}

@MainActor
public protocol WindowsCapturePowerProviding: AnyObject {
    func acquire() throws
    func release() throws
}

/// Owns one explicit Windows recording-power lifetime.
///
/// `SetThreadExecutionState` is thread-specific. The native C adapter maintains a dedicated
/// owner thread and attempts to join it during release, so acquire and release remain paired by
/// that native owner. If the worker cannot be proven joined, C retains its owner resources to
/// avoid use-after-free. See [SetThreadExecutionState](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setthreadexecutionstate).
/// Call `release()` before ending the provider's lifetime; deinitialization never silently
/// clears an active native assertion.
@MainActor
public final class WindowsRecordingPowerProvider: WindowsCapturePowerProviding {
    private let acquireOperation: () throws -> Void
    private let releaseOperation: () throws -> Void
    private nonisolated(unsafe) var active = false

    /// Creates an injectable provider for deterministic lifecycle tests.
    public init(
        acquire: @escaping () throws -> Void,
        release: @escaping () throws -> Void
    ) {
        acquireOperation = acquire
        releaseOperation = release
    }

    #if os(Windows)
    /// Creates a provider backed by the native Windows power owner.
    public convenience init() {
        let backend = NativeWindowsPowerBackend()
        self.init(acquire: { try backend.acquire() }, release: { try backend.release() })
    }
    #endif

    public func acquire() throws {
        guard !active else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Recording power is already active"
            )
        }
        try acquireOperation()
        active = true
    }

    public func release() throws {
        guard active else { return }
        active = false
        try releaseOperation()
    }

    deinit {
        precondition(!active, "WindowsRecordingPowerProvider requires explicit release() before deinitialization")
    }
}

#if os(Windows)
private func powerDiagnosticMessages(
    _ errors: mja_power_errors,
    operation: String
) -> [String] {
    var messages: [String] = []
    if errors.startup != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).startup",
                code: errors.startup
            ).localizedDescription
        )
    }
    if errors.wait != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).wait",
                code: errors.wait
            ).localizedDescription
        )
    }
    if errors.clear != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).clear",
                code: errors.clear
            ).localizedDescription
        )
    }
    if errors.cleanup != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(
                operation: "\(operation).cleanup",
                code: errors.cleanup
            ).localizedDescription
        )
    }
    return messages
}

private func nativeFailureMessages(
    operation: String,
    code: Int32,
    diagnostics: [String]
) -> [String] {
    var messages: [String] = []
    if code != 0 {
        messages.append(
            WindowsCaptureAdapterError.native(operation: operation, code: code).localizedDescription
        )
    }
    messages.append(contentsOf: diagnostics)

    var uniqueMessages: [String] = []
    for message in messages where !uniqueMessages.contains(message) {
        uniqueMessages.append(message)
    }
    return uniqueMessages
}

private final class NativeWindowsPowerBackend {
    private var owner: OpaquePointer?

    func acquire() throws {
        guard owner == nil else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Native recording-power owner is already active"
            )
        }

        var acquiredOwner: OpaquePointer?
        var errors = mja_power_errors(startup: 0, wait: 0, clear: 0, cleanup: 0)
        let result = mja_power_acquire(&acquiredOwner, &errors)
        let failures = nativeFailureMessages(
            operation: "mja_power_acquire",
            code: result,
            diagnostics: powerDiagnosticMessages(errors, operation: "mja_power_acquire")
        )
        guard failures.isEmpty else {
            throw WindowsCaptureAdapterError.combined(failures)
        }
        guard let acquiredOwner else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "mja_power_acquire succeeded without returning an owner"
            )
        }
        owner = acquiredOwner
    }

    func release() throws {
        guard let owner else {
            throw WindowsCaptureAdapterError.invalidConfiguration(
                "Native recording-power owner is not active"
            )
        }
        self.owner = nil
        var errors = mja_power_errors(startup: 0, wait: 0, clear: 0, cleanup: 0)
        let result = mja_power_release(owner, &errors)
        let failures = nativeFailureMessages(
            operation: "mja_power_release",
            code: result,
            diagnostics: powerDiagnosticMessages(errors, operation: "mja_power_release")
        )
        guard failures.isEmpty else {
            throw WindowsCaptureAdapterError.combined(failures)
        }
    }
}
#endif

public enum WindowsAutomaticInputVolume: String, Sendable {
    case none
}

public enum WindowsThermalMonitoringKind: String, Sendable {
    case none
}

/// Explicit Windows capability declarations; these are not runtime guesses.
public struct WindowsCaptureCapabilities: Sendable {
    public let automaticInputVolume: WindowsAutomaticInputVolume = .none
    public let thermalMonitoring: WindowsThermalMonitoringKind = .none

    public init() {}
}
