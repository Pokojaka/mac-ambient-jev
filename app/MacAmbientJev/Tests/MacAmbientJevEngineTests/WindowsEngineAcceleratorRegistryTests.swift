import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPortableRuntime
@testable import MacAmbientJevEngine

@Suite struct WindowsEngineAcceleratorRegistryTests {
    @Test func cpuDevicesAreDropped() throws {
        let result = try acceleratorDeviceKeys([(.cpu, 0, 0)])
        #expect(result.isEmpty)
    }

    @Test func gpuAndNpuKeysAreLowercaseAndZeroPadded() throws {
        let result = try acceleratorDeviceKeys([(.gpu, 0x10de, 0x2684), (.npu, 0, 2),
            (.npu, 0x4d4f4351, 1), (.gpu, 0x10000, UInt32.max)])
        #expect(result.map(\.key) == ["gpu:10de:2684", "npu:0000:0002", "npu:4d4f4351:0001", "gpu:00010000:ffffffff"])
    }

    @Test func duplicateDeviceKeysNameTheKey() {
        do {
            _ = try acceleratorDeviceKeys([(.gpu, 1, 2), (.gpu, 1, 2)])
            Issue.record("Expected duplicate accelerator keys to fail.")
        } catch { #expect(error.localizedDescription.contains("gpu:0001:0002")) }
    }

    @Test func missingDXCoreLuidNamesTheDevice() {
        do {
            _ = try windowsAcceleratorIdentity(luid: String(UInt64.max), deviceName: "missing-device", type: "gpu")
            Issue.record("Expected an unmatched DXCore LUID to fail.")
        } catch {
            #expect(error.localizedDescription.contains("No DXCore adapter"))
            #expect(error.localizedDescription.contains("missing-device"))
        }
    }

    @Test func nonexistentPackageFailsBeforeRegistration() async throws {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let package = "Missing.Accelerator_1.0.0.0_\(architecture)__8wekyb3d8bbwe"
        let descriptor = try EngineAcceleratorDescriptor(providerName: "missing", packageFullName: package,
            packageArchitecture: architecture, libraryPath: "C:/missing/plugin.dll",
            libraryHash: String(repeating: "a", count: 64), dependencies: [])
        let registry = WindowsEngineAcceleratorRegistry(layout: PortableInstalledModelLayout(
            modelsRoot: URL(fileURLWithPath: "C:/models", isDirectory: true)))
        do {
            _ = try await registry.bind(descriptor)
            Issue.record("Expected nonexistent package validation to fail.")
        } catch {
            #expect(error.localizedDescription.contains("OpenPackageInfoByFullName"))
            #expect(error.localizedDescription.contains("1168"))
            #expect(error.localizedDescription.contains(package))
        }
        #expect(await registry.registrations.isEmpty)
    }
}
