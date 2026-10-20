#if os(Windows)
import Foundation
import CWindowsSession
import ucrt

/// Windows equivalent of the POSIX descriptor-relative session boundary.
public enum SessionFileAccess {
    private final class Handle {
        let raw: UnsafeMutableRawPointer
        var owned = true
        init(_ raw: UnsafeMutableRawPointer) { self.raw = raw }
        deinit { if owned { msj_close(raw) } }

        func fileHandle(writable: Bool, url: URL) throws -> FileHandle {
            let descriptor = msj_descriptor(raw, writable ? 1 : 0)
            guard descriptor >= 0 else { throw unsafe(url) }
            owned = false // The descriptor, then Foundation, owns this handle.
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }

    private final class Names { var values: [String] = [] }

    private static func check(_ code: UInt32, url: URL) throws {
        guard code != 0 else { return }
        if code == 1920 || code == 123 || code == 267 { throw unsafe(url) }
        let underlying: NSError
        if code == 2 || code == 3 {
            underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        } else {
            underlying = NSError(domain: "NSWin32ErrorDomain", code: Int(code))
        }
        throw CocoaError(.fileReadUnknown, userInfo: [
            NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: underlying,
            NSLocalizedDescriptionKey: "セッションファイルへのアクセスに失敗しました (Windows \(code)): \(url.path)",
        ])
    }

    private static func unsafe(_ url: URL) -> CocoaError {
        CocoaError(.fileReadInvalidFileName, userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "セッションのパスには通常ファイルと実ディレクトリが必要です（reparse point は使えません）: \(url.path)",
        ])
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSPOSIXErrorDomain
            && (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT)
    }

    private static func child(_ parent: Handle, name: String, url: URL, kind: Int32,
                              writable: Bool = false, create: Bool = false,
                              exclusive: Bool = false, deletable: Bool = false) throws -> Handle {
        guard PortableFileName.isValid(name) else { throw unsafe(url) }
        var raw: UnsafeMutableRawPointer?
        try name.withCString(encodedAs: UTF16.self) {
            try check(msj_open_at(parent.raw, $0, kind, writable ? 1 : 0,
                                  create ? 1 : 0, exclusive ? 1 : 0, deletable ? 1 : 0, &raw), url: url)
        }
        guard let raw else { throw unsafe(url) }
        return Handle(raw)
    }

    private static func directory(_ url: URL, relativeTo root: URL, create: Bool = false,
                                  writable: Bool = false) throws -> Handle {
        let boundary = root.pathComponents
        let parts = url.pathComponents
        guard root.isFileURL, url.isFileURL,
              parts.map({ $0.lowercased() }).starts(with: boundary.map { $0.lowercased() }),
              !boundary.contains(".."), !parts.contains("..") else { throw unsafe(url) }
        if create {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let path = root.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }
        guard let path else { throw unsafe(root) }
        var raw: UnsafeMutableRawPointer?
        try path.withCString(encodedAs: UTF16.self) {
            try check(msj_open_root($0, create ? 1 : 0, (writable || create) ? 1 : 0, &raw), url: root)
        }
        guard let raw else { throw unsafe(root) }
        var current = Handle(raw)
        var currentURL = root
        for name in parts.dropFirst(boundary.count) {
            currentURL.appendPathComponent(name)
            current = try child(current, name: name, url: currentURL, kind: 1,
                                writable: writable || create, create: create)
        }
        return current
    }

    private static func parent(of url: URL, relativeTo root: URL, writable: Bool = false) throws -> Handle {
        guard url.pathComponents.count > root.pathComponents.count,
              PortableFileName.isValid(url.lastPathComponent) else { throw unsafe(url) }
        return try directory(url.deletingLastPathComponent(), relativeTo: root, writable: writable)
    }

    public static func openHandle(_ url: URL, relativeTo root: URL, writable: Bool = false,
                                   create: Bool = false, exclusive: Bool = false) throws -> FileHandle {
        let parent = try parent(of: url, relativeTo: root, writable: writable || create || exclusive)
        return try child(parent, name: url.lastPathComponent, url: url, kind: 0,
                         writable: writable, create: create, exclusive: exclusive)
            .fileHandle(writable: writable, url: url)
    }

    public static func read(_ url: URL, relativeTo root: URL) throws -> Data {
        let handle = try openHandle(url, relativeTo: root)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    public static func readIfPresent(_ url: URL, relativeTo root: URL) throws -> Data? {
        do { return try read(url, relativeTo: root) }
        catch { if isMissing(error) { return nil }; throw error }
    }

    public static func fileSize(_ url: URL, relativeTo root: URL) throws -> Int {
        let handle = try openHandle(url, relativeTo: root)
        defer { try? handle.close() }
        var size: Int64 = 0
        try check(msj_size(handle._handle, &size), url: url)
        guard let result = Int(exactly: size), result >= 0 else { throw unsafe(url) }
        return result
    }

    public static func createDirectory(_ url: URL, relativeTo root: URL) throws {
        _ = try directory(url, relativeTo: root, create: true)
    }

    public static func createExclusiveDirectory(_ url: URL, relativeTo root: URL) throws {
        let parent = try parent(of: url, relativeTo: root, writable: true)
        _ = try child(parent, name: url.lastPathComponent, url: url, kind: 1, create: true, exclusive: true)
    }

    public static func isDirectoryIfPresent(_ url: URL, relativeTo root: URL) throws -> Bool? {
        do {
            if url.pathComponents.map({ $0.lowercased() }) == root.pathComponents.map({ $0.lowercased() }) {
                _ = try directory(url, relativeTo: root)
                return true
            }
            let parent = try parent(of: url, relativeTo: root)
            let entry = try child(parent, name: url.lastPathComponent, url: url, kind: -1)
            var result: Int32 = 0
            try check(msj_kind(entry.raw, &result), url: url)
            return result != 0
        } catch { if isMissing(error) { return nil }; throw error }
    }

    private static func names(in directory: Handle, url: URL) throws -> [String] {
        let names = Names()
        let context = Unmanaged.passUnretained(names).toOpaque()
        try check(msj_list(directory.raw, { pointer, context in
            guard let pointer, let context else { return }
            Unmanaged<Names>.fromOpaque(context).takeUnretainedValue().values
                .append(String(decodingCString: pointer, as: UTF16.self))
        }, context), url: url)
        return names.values
    }

    public static func contentsOfDirectory(_ url: URL, relativeTo root: URL) throws -> [URL] {
        let directory = try directory(url, relativeTo: root)
        return try names(in: directory, url: url).map { url.appending(path: $0) }
    }

    private static func remove(_ url: URL, from parent: Handle) throws {
        let entry: Handle
        do { entry = try child(parent, name: url.lastPathComponent, url: url, kind: -1, deletable: true) }
        catch { if isMissing(error) { return }; throw error }
        var isDirectory: Int32 = 0
        try check(msj_kind(entry.raw, &isDirectory), url: url)
        if isDirectory != 0 {
            for name in try names(in: entry, url: url) { try remove(url.appending(path: name), from: entry) }
        }
        try check(msj_remove(entry.raw), url: url)
    }

    public static func removeIfPresent(_ url: URL, relativeTo root: URL) throws {
        do { try remove(url, from: parent(of: url, relativeTo: root, writable: true)) }
        catch { if isMissing(error) { return }; throw error }
    }

    public static func copy(_ source: URL, relativeTo sourceRoot: URL,
                             to destination: URL, relativeTo destinationRoot: URL) throws {
        let input = try openHandle(source, relativeTo: sourceRoot)
        defer { try? input.close() }
        let output = try openHandle(destination, relativeTo: destinationRoot, writable: true, create: true, exclusive: true)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
        try check(msj_flush(output._handle), url: destination)
    }

    private static func validate(_ url: URL, in parent: Handle, allowMissing: Bool) throws {
        do { _ = try child(parent, name: url.lastPathComponent, url: url, kind: 0) }
        catch { if allowMissing && isMissing(error) { return }; throw error }
    }

    public static func writeAtomically(_ data: Data, to url: URL, relativeTo root: URL) throws {
        let parent = try parent(of: url, relativeTo: root, writable: true)
        try validate(url, in: parent, allowMissing: true)
        let temporary = ".\(UUID().uuidString).tmp"
        let staged = try child(parent, name: temporary, url: url, kind: 0,
                               writable: true, create: true, exclusive: true, deletable: true)
        let output = try staged.fileHandle(writable: true, url: url)
        defer { try? output.close() }
        var published = false
        defer { if !published { _ = msj_remove(output._handle) } }
        try output.write(contentsOf: data)
        try check(msj_flush(output._handle), url: url)
        try validate(url, in: parent, allowMissing: true)
        try url.lastPathComponent.withCString(encodedAs: UTF16.self) {
            try check(msj_rename(output._handle, parent.raw, $0), url: url)
        }
        published = true
        try check(msj_flush(parent.raw), url: url.deletingLastPathComponent())
    }

    public static func rename(_ source: URL, to destination: URL, relativeTo root: URL) throws {
        let sourceParent = try parent(of: source, relativeTo: root, writable: true)
        let destinationParent = try parent(of: destination, relativeTo: root, writable: true)
        let entry = try child(sourceParent, name: source.lastPathComponent, url: source,
                              kind: 0, writable: true, deletable: true)
        try validate(destination, in: destinationParent, allowMissing: true)
        try check(msj_flush(entry.raw), url: source)
        try destination.lastPathComponent.withCString(encodedAs: UTF16.self) {
            try check(msj_rename(entry.raw, destinationParent.raw, $0), url: destination)
        }
        try check(msj_flush(destinationParent.raw), url: destination.deletingLastPathComponent())
        try check(msj_flush(sourceParent.raw), url: source.deletingLastPathComponent())
    }

    public static func synchronize(_ url: URL, relativeTo root: URL, isDirectory: Bool = false) throws {
        if isDirectory {
            let handle = try directory(url, relativeTo: root, writable: true)
            try check(msj_flush(handle.raw), url: url)
        } else {
            let handle = try openHandle(url, relativeTo: root, writable: true)
            defer { try? handle.close() }
            try check(msj_flush(handle._handle), url: url)
        }
    }
}
#endif
