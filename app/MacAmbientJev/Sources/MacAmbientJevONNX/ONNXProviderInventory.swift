import Foundation
import MacAmbientJevCore

public struct ONNXProviderFile: Sendable {
    public let path: String
    public let sha256: String
    public init(path: String, sha256: String) { self.path = path; self.sha256 = sha256 }
}

func validateProviderInventory(library: ONNXProviderFile, dependencies: [ONNXProviderFile]) throws -> [String] {
    let files = [library] + dependencies
    guard files.count <= 64 else { throw ONNXRuntimeError(message: "ONNX provider inventory exceeds 64 files.") }
    var names = Set<String>(), directories = [String: String]()
    for file in files {
        let path = file.path
        guard !path.contains("\0") else { throw ONNXRuntimeError(message: "Provider path contains NUL: \(path)") }
        #if os(Windows)
        let validationPath = path.replacingOccurrences(of: "/", with: "\\")
        let b = Array(validationPath.utf8), drive = b.count >= 3 && ((65...90).contains(b[0]) || (97...122).contains(b[0])) && b[1] == 58 && b[2] == 92
        let parts = validationPath.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false)
        let unc = b.count > 2 && b[0] == 92 && b[1] == 92 && b[2] != 92 && parts.count >= 2 && !parts[0].isEmpty && !parts[1].isEmpty
        guard drive || unc else { throw ONNXRuntimeError(message: "Provider path is not fully qualified: \(path)") }
        #else
        guard path.hasPrefix("/") else { throw ONNXRuntimeError(message: "Provider path is not absolute: \(path)") }
        #endif
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeRegular else {
            throw ONNXRuntimeError(message: "Provider file is missing or not regular: \(path)")
        }
        let name = url.lastPathComponent.lowercased()
        guard name != "onnxruntime.dll" else { throw ONNXRuntimeError(message: "Provider inventory must not include onnxruntime.dll: \(path)") }
        guard names.insert(name).inserted else { throw ONNXRuntimeError(message: "Duplicate provider basename: \(path)") }
        let directory = url.standardizedFileURL.deletingLastPathComponent().path
        #if os(Windows)
        let directoryKey = directory.lowercased()
        #else
        let directoryKey = directory
        #endif
        directories[directoryKey] = directories[directoryKey] ?? directory
        guard directories.count <= 16 else { throw ONNXRuntimeError(message: "Provider inventory exceeds 16 directories at: \(path)") }
        let actual: String
        do { actual = try FileSHA256.hexDigest(ofFileAt: url) }
        catch { throw ONNXRuntimeError(message: "Could not compute SHA-256 for provider file \(path): \(error)") }
        guard actual.caseInsensitiveCompare(file.sha256) == .orderedSame else {
            throw ONNXRuntimeError(message: "SHA-256 mismatch for \(path): actual \(actual), expected \(file.sha256)")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let dos = try handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else {
                throw ONNXRuntimeError(message: "Malformed PE DOS header: \(path)")
            }
            let offset = UInt32(dos[60]) | UInt32(dos[61]) << 8 | UInt32(dos[62]) << 16 | UInt32(dos[63]) << 24
            guard offset >= 64 else { throw ONNXRuntimeError(message: "Malformed PE header offset: \(path)") }
            try handle.seek(toOffset: UInt64(offset))
            guard let pe = try handle.read(upToCount: 6), pe.count == 6, Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else {
                throw ONNXRuntimeError(message: "Malformed PE signature: \(path)")
            }
            let machine = UInt16(pe[4]) | UInt16(pe[5]) << 8
            #if arch(arm64)
            let expected: UInt16 = 0xAA64
            #elseif arch(x86_64)
            let expected: UInt16 = 0x8664
            #else
            throw ONNXRuntimeError(message: "Unsupported architecture for PE validation: \(path)")
            #endif
            guard machine == expected else { throw ONNXRuntimeError(message: "PE machine mismatch for \(path): actual \(machine), expected \(expected)") }
        } catch let error as ONNXRuntimeError { throw error }
        catch { throw ONNXRuntimeError(message: "Could not read PE headers for provider file \(path): \(error)") }
    }
    return directories.values.sorted()
}
