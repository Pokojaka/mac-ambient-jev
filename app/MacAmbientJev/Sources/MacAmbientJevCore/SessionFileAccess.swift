import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !os(Windows)

/// Files beneath a session boundary are opened relative to pinned directory descriptors.
/// The caller-selected root's ancestry may include OS aliases; the root itself and every
/// descendant must be real directories/files, never symbolic links.
public enum SessionFileAccess {
    public static func read(_ url: URL, relativeTo root: URL) throws -> Data {
        let handle = try openHandle(url, relativeTo: root)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    public static func readIfPresent(_ url: URL, relativeTo root: URL) throws -> Data? {
        do { return try read(url, relativeTo: root) }
        catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
            return nil
        }
    }

    public static func openHandle(
        _ url: URL, relativeTo root: URL, writable: Bool = false,
        create: Bool = false, exclusive: Bool = false
    ) throws -> FileHandle {
        let parent = try parentDirectory(of: url, relativeTo: root)
        defer { close(parent) }
        var flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if create { flags |= O_CREAT }
        if exclusive { flags |= O_EXCL }
        let descriptor = openat(parent, url.lastPathComponent, flags, mode_t(0o600))
        guard descriptor >= 0 else { throw failure(url) }
        do { try requireRegularFile(descriptor, url: url) }
        catch { close(descriptor); throw error }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public static func fileSize(_ url: URL, relativeTo root: URL) throws -> Int {
        let handle = try openHandle(url, relativeTo: root)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw failure(url) }
        return Int(info.st_size)
    }

    public static func createDirectory(_ url: URL, relativeTo root: URL) throws {
        let descriptor = try directory(url, relativeTo: root, create: true)
        close(descriptor)
    }

    public static func createExclusiveDirectory(_ url: URL, relativeTo root: URL) throws {
        let parent = try parentDirectory(of: url, relativeTo: root)
        defer { close(parent) }
        guard mkdirat(parent, url.lastPathComponent, mode_t(0o700)) == 0 else { throw failure(url) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(url) }
        close(descriptor)
    }

    /// Nil means absent; false means a regular file. Symlinks and special files are errors.
    public static func isDirectoryIfPresent(_ url: URL, relativeTo root: URL) throws -> Bool? {
        if url.pathComponents == root.pathComponents {
            do {
                let descriptor = try directory(url, relativeTo: root)
                close(descriptor)
                return true
            } catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) {
                return nil
            }
        }
        let parent: Int32
        do { parent = try parentDirectory(of: url, relativeTo: root) }
        catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) { return nil }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw failure(url)
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return true
        case S_IFREG: return false
        default: throw unsafe(url)
        }
    }

    /// Removal stays anchored even if a child directory is renamed during traversal.
    public static func removeIfPresent(_ url: URL, relativeTo root: URL) throws {
        let parent: Int32
        do { parent = try parentDirectory(of: url, relativeTo: root) }
        catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) { return }
        defer { close(parent) }
        try removeEntry(parent, name: url.lastPathComponent, url: url)
    }

    public static func copy(_ source: URL, relativeTo sourceRoot: URL, to destination: URL, relativeTo destinationRoot: URL) throws {
        let input = try openHandle(source, relativeTo: sourceRoot)
        defer { try? input.close() }
        let output = try openHandle(destination, relativeTo: destinationRoot, writable: true, create: true, exclusive: true)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    private static func removeEntry(_ parent: Int32, name: String, url: URL) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw failure(url)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw failure(url) }
            guard let stream = fdopendir(descriptor) else { close(descriptor); throw failure(url) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw failure(url) }
                    break
                }
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
                }
                if child != "." && child != ".." {
                    try removeEntry(descriptor, name: child, url: url.appending(path: child))
                }
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure(url) }
        } else {
            guard info.st_mode & S_IFMT == S_IFREG else { throw unsafe(url) }
            guard unlinkat(parent, name, 0) == 0 else { throw failure(url) }
        }
    }

    public static func contentsOfDirectory(_ url: URL, relativeTo root: URL) throws -> [URL] {
        let descriptor = try directory(url, relativeTo: root)
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw failure(url) }
        defer { closedir(stream) }
        var result: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw failure(url) }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { result.append(url.appending(path: name)) }
        }
    }

    /// The temporary file is exclusively created in the pinned destination directory.
    /// Neither validation nor publication follows the destination or a staged symlink.
    public static func writeAtomically(_ data: Data, to url: URL, relativeTo root: URL) throws {
        let parent = try parentDirectory(of: url, relativeTo: root)
        defer { close(parent) }
        try validateEntry(parent, name: url.lastPathComponent, url: url, allowMissing: true)
        let temporary = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw failure(url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(parent, temporary, 0)
        }
        try handle.write(contentsOf: data)
        try synchronizeDescriptor(descriptor, url: url)
        try validateEntry(parent, name: url.lastPathComponent, url: url, allowMissing: true)
        guard renameat(parent, temporary, parent, url.lastPathComponent) == 0 else { throw failure(url) }
        try synchronizeDescriptor(parent, url: url.deletingLastPathComponent())
    }

    public static func rename(_ source: URL, to destination: URL, relativeTo root: URL) throws {
        let sourceParent = try parentDirectory(of: source, relativeTo: root)
        defer { close(sourceParent) }
        let destinationParent = try parentDirectory(of: destination, relativeTo: root)
        defer { close(destinationParent) }
        try validateEntry(sourceParent, name: source.lastPathComponent, url: source, allowMissing: false)
        try validateEntry(destinationParent, name: destination.lastPathComponent, url: destination, allowMissing: true)
        guard renameat(sourceParent, source.lastPathComponent, destinationParent, destination.lastPathComponent) == 0 else {
            throw failure(destination)
        }
        try synchronizeDescriptor(destinationParent, url: destination.deletingLastPathComponent())
    }

    public static func synchronize(_ url: URL, relativeTo root: URL, isDirectory: Bool = false) throws {
        let descriptor: Int32
        if isDirectory { descriptor = try directory(url, relativeTo: root) }
        else {
            let handle = try openHandle(url, relativeTo: root)
            defer { try? handle.close() }
            try synchronizeDescriptor(handle.fileDescriptor, url: url)
            return
        }
        defer { close(descriptor) }
        try synchronizeDescriptor(descriptor, url: url)
    }

    private static func synchronizeDescriptor(_ descriptor: Int32, url: URL) throws {
        #if canImport(Darwin)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(url) }
        let result = info.st_mode & S_IFMT == S_IFDIR ? fsync(descriptor) : fcntl(descriptor, F_FULLFSYNC)
        #else
        let result = fsync(descriptor)
        #endif
        guard result == 0 else { throw failure(url) }
    }

    private static func parentDirectory(of url: URL, relativeTo root: URL) throws -> Int32 {
        guard !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw unsafe(url)
        }
        return try directory(url.deletingLastPathComponent(), relativeTo: root)
    }

    private static func directory(_ url: URL, relativeTo root: URL, create: Bool = false) throws -> Int32 {
        let boundary = root
        let boundaryParts = boundary.pathComponents
        let parts = url.pathComponents
        guard url.isFileURL, boundary.isFileURL, parts.starts(with: boundaryParts),
              !parts.contains("..") else { throw unsafe(url) }
        // Only ancestors of the explicitly chosen boundary may contain aliases.
        // Creation below that boundary always uses mkdirat followed by openat.
        if create {
            try FileManager.default.createDirectory(at: boundary.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(boundary.path, mode_t(0o700)) != 0 && errno != EEXIST { throw failure(boundary) }
        }
        var current = open(boundary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw failure(boundary) }
        do {
            for component in parts.dropFirst(boundaryParts.count) {
                if create && mkdirat(current, component, mode_t(0o700)) != 0 && errno != EEXIST { throw failure(url) }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure(url) }
                close(current)
                current = next
            }
            return current
        } catch { close(current); throw error }
    }

    private static func validateEntry(_ directory: Int32, name: String, url: URL, allowMissing: Bool) throws {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if allowMissing && errno == ENOENT { return }
            throw failure(url)
        }
        defer { close(descriptor) }
        try requireRegularFile(descriptor, url: url)
    }

    private static func requireRegularFile(_ descriptor: Int32, url: URL) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(url) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw unsafe(url) }
    }

    private static func unsafe(_ url: URL) -> CocoaError {
        CocoaError(.fileReadInvalidFileName, userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "セッションのパスは通常ファイルと実ディレクトリである必要があります（symlink は使えません）: \(url.path)",
        ])
    }

    private static func failure(_ url: URL) -> CocoaError {
        let code = errno
        return CocoaError(.fileReadUnknown, userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "セッションファイルにアクセスできません（symlink は使えません）: \(url.path)",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code)),
        ])
    }
}
#endif
