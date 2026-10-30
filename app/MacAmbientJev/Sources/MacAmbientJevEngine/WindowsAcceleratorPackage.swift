import Foundation
#if os(Windows)
import WinSDK
#endif
import MacAmbientJevEngineProtocol
import MacAmbientJevEngineHost

internal func windowsAcceleratorError(_ message: String) -> EngineAdapterError { EngineAdapterError(code: .modelFailure, message: message, recoveryAction: .none, details: []) }
func validateAcceleratorPathSet(libraryPath: String, headRoot: String, declaredPaths: [String], actualPaths: [String]) throws {
    func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.path.lowercased()
    }
    let library = normalized(libraryPath), head = normalized(headRoot)
    let boundary = head.hasSuffix("/") ? head : head + "/"
    guard library.hasPrefix(boundary) else {
        throw windowsAcceleratorError("Accelerator library is outside head package root: \(libraryPath) (head root: \(headRoot)).")
    }
    let declared = Set(declaredPaths.map(normalized)), actual = Set(actualPaths.map(normalized))
    let missing = declared.subtracting(actual).sorted(), extra = actual.subtracting(declared).sorted()
    guard missing.isEmpty && extra.isEmpty else {
        throw windowsAcceleratorError("Accelerator package paths differ; missing: [\(missing.joined(separator: ", "))]; extra: [\(extra.joined(separator: ", "))].")
    }
}
func validateAcceleratorPackage(_ descriptor: EngineAcceleratorDescriptor) throws {
    #if arch(arm64)
    let nativeArchitecture = "arm64"
    let nativeMachine: UInt32 = 12
    #elseif arch(x86_64)
    let nativeArchitecture = "x64"
    let nativeMachine: UInt32 = 9
    #else
    throw windowsAcceleratorError("Unsupported native architecture for Windows accelerator packages.")
    #endif
    guard descriptor.packageArchitecture == nativeArchitecture else {
        throw windowsAcceleratorError("Accelerator package architecture \(descriptor.packageArchitecture) does not match native architecture \(nativeArchitecture).")
    }
    guard !descriptor.packageFullName.utf8.contains(0) else { throw windowsAcceleratorError("Accelerator package full name contains NUL.") }
    var pending = [descriptor.packageFullName], visited = Set<String>(), rootKeys = Set<String>(), roots: [String] = [], headRoot: String?
    while !pending.isEmpty {
        let name = pending.removeFirst()
        guard visited.insert(name.lowercased()).inserted else { continue }
        for package in try queryAcceleratorPackage(name) {
            pending.append(package.name)
            if package.name.caseInsensitiveCompare(descriptor.packageFullName) == .orderedSame {
                guard package.architecture == nativeMachine else { throw windowsAcceleratorError("Accelerator package '\(descriptor.packageFullName)' has OS architecture \(package.architecture); expected architecture \(nativeArchitecture).") }
                headRoot = package.root
            }
            let key = URL(fileURLWithPath: package.root.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.path.lowercased()
            if rootKeys.insert(key).inserted { roots.append(package.root) }
        }
    }
    guard let headRoot else { throw windowsAcceleratorError("Package inventory did not return requested head package '\(descriptor.packageFullName)'.") }
    let actual = try roots.flatMap { try acceleratorPackageDLLs(root: $0) }
    try validateAcceleratorPathSet(libraryPath: descriptor.libraryPath, headRoot: headRoot,
        declaredPaths: [descriptor.libraryPath] + descriptor.dependencies.map(\.path), actualPaths: actual)
}
private func queryAcceleratorPackage(_ name: String) throws -> [(name: String, root: String, architecture: UInt32)] {
    let units = Array(name.utf16) + [0]
    var reference: PACKAGE_INFO_REFERENCE?
    let opened = units.withUnsafeBufferPointer { OpenPackageInfoByFullName($0.baseAddress, 0, &reference) }
    guard opened == 0, let reference else { throw windowsAcceleratorError("OpenPackageInfoByFullName failed for '\(name)' (Win32 \(opened)).") }
    let packages: [(name: String, root: String, architecture: UInt32)]
    do {
        var length: UINT32 = 0, count: UINT32 = 0
        let sized = GetPackageInfo(reference, 0x30, &length, nil, &count)
        guard sized == 122, length > 0 else { throw windowsAcceleratorError("GetPackageInfo size query failed for '\(name)' (Win32 \(sized), length \(length)).") }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: MemoryLayout<PACKAGE_INFO>.alignment)
        defer { buffer.deallocate() }
        let code = GetPackageInfo(reference, 0x30, &length, buffer.assumingMemoryBound(to: BYTE.self), &count)
        guard code == 0, count > 0, UInt64(count) * UInt64(MemoryLayout<PACKAGE_INFO>.stride) <= UInt64(length) else {
            throw windowsAcceleratorError("GetPackageInfo failed or returned no packages for '\(name)' (Win32 \(code), count \(count)).")
        }
        let infos = buffer.assumingMemoryBound(to: PACKAGE_INFO.self)
        let packageCount = Swift.Int(truncatingIfNeeded: count)
        packages = try (0..<packageCount).map { index in
            let info = infos[index]
            guard let fullName = info.packageFullName, let path = info.path else {
                throw windowsAcceleratorError("GetPackageInfo returned an empty package name or root for '\(name)'.")
            }
            let packageName = String(decodingCString: fullName, as: UTF16.self)
            let root = String(decodingCString: path, as: UTF16.self)
            let slashPath = root.replacingOccurrences(of: "\\", with: "/"), bytes = Array(slashPath.utf8)
            let drive = bytes.count >= 3 && (((65...90).contains(bytes[0])) || ((97...122).contains(bytes[0]))) && bytes[1] == 58 && bytes[2] == 47
            let unc = bytes.count > 2 && bytes[0] == 47 && bytes[1] == 47 && bytes[2] != 47 && slashPath.dropFirst(2).split(separator: "/").count >= 2
            guard !packageName.isEmpty, !root.isEmpty, drive || unc else {
                throw windowsAcceleratorError("GetPackageInfo returned an empty package name or non-absolute root for '\(name)'.")
            }
            return (packageName, root, info.packageId.processorArchitecture)
        }
    } catch {
        let cause = error, closed = ClosePackageInfo(reference)
        if closed != 0 { throw windowsAcceleratorError("ClosePackageInfo failed for '\(name)' (Win32 \(closed)); prior error: \(cause).") }
        throw cause
    }
    let closed = ClosePackageInfo(reference); guard closed == 0 else { throw windowsAcceleratorError("ClosePackageInfo failed for '\(name)' (Win32 \(closed)).") }
    return packages
}
private func acceleratorPackageDLLs(root: String) throws -> [String] {
    var pending = [root], result: [String] = []
    while !pending.isEmpty {
        let directory = pending.removeFirst(), wide = Array(directory.utf16) + [0]
        let attributes = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
        guard attributes != DWORD.max else { throw windowsAcceleratorError("GetFileAttributesW failed for '\(directory)' (Win32 \(GetLastError())).") }
        guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw windowsAcceleratorError("Accelerator package contains a reparse point: \(directory).") }
        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else { throw windowsAcceleratorError("Accelerator package root or entry is not a directory: \(directory).") }
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: directory) }
        catch { throw windowsAcceleratorError("Could not enumerate accelerator package directory '\(directory)': \(error).") }
        for name in entries {
            let path = directory + (directory.hasSuffix("/") || directory.hasSuffix("\\") ? "" : "\\") + name
            let entryWide = Array(path.utf16) + [0]
            let entryAttributes = entryWide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
            guard entryAttributes != DWORD.max else { throw windowsAcceleratorError("GetFileAttributesW failed for '\(path)' (Win32 \(GetLastError())).") }
            guard entryAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else { throw windowsAcceleratorError("Accelerator package contains a reparse point: \(path).") }
            if entryAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { pending.append(path) }
            else if URL(fileURLWithPath: path).pathExtension.caseInsensitiveCompare("dll") == .orderedSame { result.append(path) }
        }
    }
    return result
}
