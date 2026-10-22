import Foundation
import MacAmbientJevCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public enum ApplicationRootLockError: Error, LocalizedError, Equatable {
    case alreadyRunning(path: String)
    case filesystem(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyRunning(path):
            "別のエンジンが同じアプリケーションフォルダーを使用中です: \(path)"
        case let .filesystem(path, reason):
            "アプリケーションフォルダーのロックを取得できません: \(path) (\(reason))"
        }
    }
}

/// The per-user exclusive lock on the application root, held for the life of the engine process.
/// The lock belongs to the open file, so the OS also releases it when the process dies.
public final class ApplicationRootLock: @unchecked Sendable {
    public static let fileName = "engine.lock"

    public let lockURL: URL
    private var handle: FileHandle?

    private init(lockURL: URL, handle: FileHandle) {
        self.lockURL = lockURL
        self.handle = handle
    }

    /// Creates the application root when absent. A second holder fails with `alreadyRunning`.
    public static func acquire(paths: AppPaths) throws -> ApplicationRootLock {
        let root = paths.root
        let url = root.appending(path: fileName, directoryHint: .notDirectory)
        let handle: FileHandle
        do {
            try SessionFileAccess.createDirectory(root, relativeTo: root)
            handle = try SessionFileAccess.openHandle(url, relativeTo: root, writable: true, create: true)
        } catch {
            throw ApplicationRootLockError.filesystem(path: url.path, reason: error.localizedDescription)
        }
        do {
            try lock(handle, url: url)
        } catch {
            try? handle.close()
            throw error
        }
        return ApplicationRootLock(lockURL: url, handle: handle)
    }

    /// Releasing is idempotent; dropping the last reference releases too.
    public func release() {
        try? handle?.close()
        handle = nil
    }

    deinit {
        release()
    }

    private static func lock(_ handle: FileHandle, url: URL) throws {
        #if os(Windows)
        var overlapped = OVERLAPPED()
        let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY)
        guard LockFileEx(handle._handle, flags, 0, 1, 0, &overlapped) else {
            let code = GetLastError()
            if code == DWORD(ERROR_LOCK_VIOLATION) {
                throw ApplicationRootLockError.alreadyRunning(path: url.path)
            }
            throw ApplicationRootLockError.filesystem(path: url.path, reason: "LockFileEx failed (\(code))")
        }
        #else
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK {
                throw ApplicationRootLockError.alreadyRunning(path: url.path)
            }
            throw ApplicationRootLockError.filesystem(path: url.path, reason: String(cString: strerror(code)))
        }
        #endif
    }
}
