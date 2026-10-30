import Foundation
import CWindowsAccelerator
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevONNX
import MacAmbientJevPortableRuntime

func acceleratorDeviceKeys(_ devices: [(type: ONNXHardwareType, vendorID: UInt32, deviceID: UInt32)]) throws -> [(index: Int, key: String)] {
    var result: [(index: Int, key: String)] = [], keys = Set<String>()
    for (index, device) in devices.enumerated() {
        guard device.type != .cpu else { continue }
        let key = ONNXProviderDevice.deviceKey(hardwareType: device.type, vendorID: device.vendorID, deviceID: device.deviceID)
        guard keys.insert(key).inserted else { throw windowsAcceleratorError("Duplicate accelerator device key \(key).") }
        result.append((index, key))
    }
    return result
}

func windowsAcceleratorIdentity(luid: String?, deviceName: String, type: String) throws -> (driverVersion: String, memory: UInt64?, adapterIdentity: String) {
    guard let luid, !luid.isEmpty, luid.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = UInt64(luid) else {
        throw windowsAcceleratorError("Missing or invalid decimal UInt64 LUID for device \(deviceName).")
    }
    var driver: UInt64 = 0, memory: UInt64 = 0, available: Int32 = 0
    var adapterIdentity = [CChar](repeating: 0, count: 45)
    let hr = mja_dxcore_identity(value, &driver, &memory, &available, &adapterIdentity)
    if hr != 0 {
        let formatted = String(format: "0x%08x", UInt32(bitPattern: hr))
        throw windowsAcceleratorError("DXCore adapter/HardwareIDParts/driver version lookup failed for device \(deviceName), LUID \(luid) (HRESULT \(formatted)).")
    }
    let version = [48, 32, 16, 0].map { String((driver >> UInt64($0)) & 0xffff) }.joined(separator: ".")
    guard available == 1 || type != "gpu" else { throw windowsAcceleratorError("Dedicated memory is unavailable for GPU device \(deviceName), LUID \(luid).") }
    return (driverVersion: version, memory: available == 1 ? memory : nil, adapterIdentity: String(decoding: adapterIdentity.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self))
}

internal actor WindowsEngineAcceleratorRegistry: EngineAcceleratorRegistry {
    private let layout: PortableInstalledModelLayout
    private(set) var registrations: [(descriptor: EngineAcceleratorDescriptor, name: String)] = []

    init(layout: PortableInstalledModelLayout) { self.layout = layout }

    func bind(_ descriptor: EngineAcceleratorDescriptor) async throws -> [any EngineAcceleratorDevice] {
        try await Task.detached(executorPreference: BlockingIOExecutor.shared) { try await self.bindSynchronously(descriptor) }.value
    }

    // Keep this actor-isolated helper suspension-free to serialize cache and registration work.
    // The detached task's preferred executor supplies noncooperative threads.
    private func bindSynchronously(_ descriptor: EngineAcceleratorDescriptor) throws -> [any EngineAcceleratorDevice] {
        let cached = registrations.first { $0.descriptor == descriptor }
        let name: String, environment: ONNXEnvironment
        if let cached {
            name = cached.name
            environment = try ONNXEnvironment.shared()
        } else {
            try validateAcceleratorPackage(descriptor)
            name = UUID().uuidString
            environment = try ONNXEnvironment.shared()
            try environment.providers.register(name: name,
                library: ONNXProviderFile(path: descriptor.libraryPath, sha256: descriptor.libraryHash),
                dependencies: descriptor.dependencies.map { ONNXProviderFile(path: $0.path, sha256: $0.hash) })
            registrations.append((descriptor, name))
        }
        let devices = try environment.providers.devices(registrationName: name)
        let keyed = try acceleratorDeviceKeys(devices.map { (type: $0.hardwareType, vendorID: $0.vendorID, deviceID: $0.deviceID) })
        return try keyed.map { item in
            let raw = devices[item.index]
            guard let description = raw.metadata["Description"], !description.isEmpty else {
                throw windowsAcceleratorError("Provider \(raw.epName) device \(item.key) has no nonempty Description metadata.")
            }
            let identity = try windowsAcceleratorIdentity(luid: raw.metadata["LUID"], deviceName: description, type: raw.hardwareType.rawValue)
            let info = try EngineAcceleratorDeviceInfo(deviceKey: item.key, type: raw.hardwareType.rawValue,
                description: description, driverVersion: identity.driverVersion, dedicatedMemoryBytes: identity.memory)
            return WindowsEngineAcceleratorDevice(info: info, raw: raw, layout: layout, adapterIdentity: identity.adapterIdentity)
        }
    }
}

private struct WindowsEngineAcceleratorDevice: EngineAcceleratorDevice {
    let info: EngineAcceleratorDeviceInfo
    let raw: ONNXProviderDevice
    let layout: PortableInstalledModelLayout
    let adapterIdentity: String
    var ortVersion: String { ONNXEnvironment.runtimeVersion }
    var modelRevision: String { "\(ASRModelSize.small.repository)@\(ASRModelSize.small.commit)" }

    func makeASREngine(size: ASRModelSize, threads: Int, language: String, maxNewTokens: Int,
        noRepeatNgramSize: Int?) async throws -> any ASREngine {
        try ONNXQwen3ASREngine(modelDirectory: layout.qwen3Directory(size: size), size: size,
            intraOpThreads: threads, device: raw, language: language, maxNewTokens: maxNewTokens,
            noRepeatNgramSize: noRepeatNgramSize)
    }
}
