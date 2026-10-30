import Foundation
import Testing
import MacAmbientJevCore
@testable import MacAmbientJevONNX
#if os(Windows)
import WinSDK
#endif

@Suite(.serialized)
struct ONNXProviderRegistryTests {
    @Test
    func providerInventoryRejectsInvalidFilesAndAcceptsProviderDLL() throws {
        let fixture = try ProviderFixture()
        defer { fixture.cleanup() }
        func reject(_ library: ONNXProviderFile, _ text: String, dependencies: [ONNXProviderFile]) {
            do { _ = try validateProviderInventory(library: library, dependencies: dependencies); Issue.record("Expected inventory rejection: \(text)") }
            catch let error as ONNXRuntimeError { #expect(error.message.contains(text)) }
            catch { Issue.record("Expected ONNXRuntimeError, got \(error)") }
        }
        let good = try fixture.file("provider.dll", machine: ProviderFixture.targetMachine)
        let first = good.sha256.first == "0" ? "1" : "0"
        reject(ONNXProviderFile(path: good.path, sha256: first + String(good.sha256.dropFirst())), "SHA-256 mismatch", dependencies: [])
        reject(good, "exceeds 64 files", dependencies: Array(repeating: good, count: 64))
        let duplicate = try fixture.file("a/Provider.DLL", machine: ProviderFixture.targetMachine)
        let duplicateDependency = try fixture.file("b/PROVIDER.dll", machine: ProviderFixture.targetMachine)
        reject(duplicate, "Duplicate provider basename", dependencies: [duplicateDependency])
        let runtime = try fixture.file("OnNxRuNtImE.DlL", machine: ProviderFixture.targetMachine)
        reject(runtime, "must not include onnxruntime.dll", dependencies: [])
        let accepted = try fixture.file("onnxruntime_providers_X.dll", machine: ProviderFixture.targetMachine)
        #expect(try validateProviderInventory(library: accepted, dependencies: []).count == 1)
        #if arch(arm64)
        let wrongMachine: UInt16 = 0x8664
        #else
        let wrongMachine: UInt16 = 0xAA64
        #endif
        let badDependency = try fixture.file("bad/dependency.dll", machine: wrongMachine)
        reject(good, "PE machine mismatch for \(badDependency.path)", dependencies: [badDependency])
        var manyDirectories: [ONNXProviderFile] = []
        for index in 0..<16 { manyDirectories.append(try fixture.file("dir\(index)/provider\(index).dll", machine: ProviderFixture.targetMachine)) }
        reject(good, "exceeds 16 directories", dependencies: manyDirectories)
    }

    #if os(Windows)
    @Test
    func nonProviderSystemDLLRegistrationFailsAndCleansUp() throws {
        let environment = try ONNXEnvironment.shared()
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let length = buffer.withUnsafeMutableBufferPointer { GetSystemDirectoryW($0.baseAddress, DWORD($0.count)) }
        guard length > 0, Int(length) < buffer.count else { throw ONNXRuntimeError(message: "GetSystemDirectoryW failed (Win32 \(GetLastError())).") }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF16.self) + "\\version.dll"
        let library = ONNXProviderFile(path: path, sha256: try FileSHA256.hexDigest(ofFileAt: URL(fileURLWithPath: path)))
        let name = "P6-8c1-\(UUID().uuidString)"
        var message: String?
        do {
            try environment.providers.register(name: name, library: library, dependencies: [])
            try environment.providers.unregister(name: name)
            Issue.record("version.dll unexpectedly registered as an execution provider")
        } catch let error as ONNXRuntimeError {
            message = error.message
        }
        #expect(message?.contains("Registering provider") == true)
        #expect(environment.providers.registrations[name] == nil)
    }
    #endif
}

private struct ProviderFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("onnx-provider-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ relativePath: String, machine: UInt16) throws -> ONNXProviderFile {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes += [0x50, 0x45, 0, 0, UInt8(truncatingIfNeeded: machine), UInt8(truncatingIfNeeded: machine >> 8)]
        try Data(bytes).write(to: url)
        return ONNXProviderFile(path: url.path, sha256: try FileSHA256.hexDigest(ofFileAt: url))
    }
    func cleanup() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove provider fixture \(root.path): \(error)") }
    }
    static var targetMachine: UInt16 {
        #if arch(arm64)
        0xAA64
        #else
        0x8664
        #endif
    }
}
