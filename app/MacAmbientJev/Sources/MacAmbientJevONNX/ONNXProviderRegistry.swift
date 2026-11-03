import Foundation
import CONNXRuntime
#if os(Windows)
import WinSDK
#endif

public enum ONNXHardwareType: String, Sendable { case cpu, gpu, npu }

public struct ONNXProviderDevice: @unchecked Sendable {
    public let epName: String; public let epVendor: String
    public let hardwareType: ONNXHardwareType; public let vendorID: UInt32; public let deviceID: UInt32
    public let metadata: [String: String]
    let handle: OpaquePointer; let registrationID: Foundation.UUID

    public var deviceKey: String { Self.deviceKey(hardwareType: hardwareType, vendorID: vendorID, deviceID: deviceID) }

    public static func deviceKey(hardwareType: ONNXHardwareType, vendorID: UInt32, deviceID: UInt32) -> String {
        func hex(_ value: UInt32) -> String {
            let digits = String(value, radix: 16)
            return String(repeating: "0", count: (value <= 0xffff ? 4 : 8) - digits.count) + digits
        }
        return "\(hardwareType.rawValue):\(hex(vendorID)):\(hex(deviceID))"
    }
}

final class ONNXProviderLease {}

final class ONNXProviderRegistration {
    let id: Foundation.UUID; let devices: Set<OpaquePointer>
    var cookies: [UnsafeMutableRawPointer]; weak var lease: ONNXProviderLease?
    var registered: Bool
    init(id: Foundation.UUID, devices: Set<OpaquePointer>, cookies: [UnsafeMutableRawPointer], registered: Bool) {
        self.id = id; self.devices = devices; self.cookies = cookies; self.registered = registered
    }
}

public final class ONNXProviderRegistry: @unchecked Sendable {
    let api: UnsafePointer<OrtApi>; let environment: OpaquePointer
    private let lock = NSLock()
    var registrations: [String: ONNXProviderRegistration] = [:]
    init(api: UnsafePointer<OrtApi>, environment: OpaquePointer) { self.api = api; self.environment = environment }

    public func register(name: String, library: ONNXProviderFile, dependencies: [ONNXProviderFile]) throws {
        #if !os(Windows)
        throw ONNXRuntimeError(message: "ONNX execution provider libraries can only be registered on Windows.")
        #else
        lock.lock(); defer { lock.unlock() }
        guard !name.isEmpty, !name.utf8.contains(0) else { throw ONNXRuntimeError(message: "Provider registration name must be nonempty and contain no NUL.") }
        guard registrations[name] == nil else { throw ONNXRuntimeError(message: "Provider registration name is already in use: \(name)") }
        let directories = try validateProviderInventory(library: library, dependencies: dependencies)
        guard SetDefaultDllDirectories(DWORD(0xE00)) else { throw ONNXRuntimeError(message: "SetDefaultDllDirectories failed (Win32 \(GetLastError())).") }
        var cookies: [UnsafeMutableRawPointer] = [], registered = false
        let id = Foundation.UUID()
        do {
            let before = Set(try epDevices())
            for directory in directories {
                let path = Array(directory.utf16) + [0]
                guard let cookie = path.withUnsafeBufferPointer({ AddDllDirectory($0.baseAddress) }) else {
                    throw ONNXRuntimeError(message: "AddDllDirectory failed for \(directory) (Win32 \(GetLastError())).")
                }
                cookies.append(cookie)
            }
            let path = Array(library.path.utf16) + [0]
            let status = name.withCString { n in path.withUnsafeBufferPointer { api.pointee.RegisterExecutionProviderLibrary!(environment, n, $0.baseAddress) } }
            try checkStatus(status, api: api, context: "Registering provider \(name) at \(library.path) failed")
            registered = true
            let added = Set(try epDevices()).subtracting(before)
            registrations[name] = ONNXProviderRegistration(id: id, devices: added, cookies: cookies, registered: true)
        } catch {
            let cause = error
            if registered {
                do {
                    try checkStatus(name.withCString { api.pointee.UnregisterExecutionProviderLibrary!(environment, $0) }, api: api, context: "Rolling back provider \(name) failed")
                    registered = false
                } catch {
                    registrations[name] = ONNXProviderRegistration(id: id, devices: [], cookies: cookies, registered: true)
                    throw ONNXRuntimeError(message: "Provider operation failed: \(cause); unregister rollback failed: \(error)")
                }
            }
            do { try removeCookies(&cookies) }
            catch {
                registrations[name] = ONNXProviderRegistration(id: id, devices: [], cookies: cookies, registered: registered)
                throw ONNXRuntimeError(message: "Provider operation failed: \(cause); DLL directory cleanup failed: \(error)")
            }
            throw cause
        }
        #endif
    }

    public func devices(registrationName: String) throws -> [ONNXProviderDevice] {
        lock.lock(); defer { lock.unlock() }
        guard let registration = registrations[registrationName], registration.registered else { throw ONNXRuntimeError(message: "Provider registration is not live: \(registrationName)") }
        var result: [ONNXProviderDevice] = []
        for handle in try epDevices() where registration.devices.contains(handle) {
            guard let name = api.pointee.EpDevice_EpName!(handle), let vendor = api.pointee.EpDevice_EpVendor!(handle), let hardware = api.pointee.EpDevice_Device!(handle) else {
                throw ONNXRuntimeError(message: "ONNX Runtime returned incomplete provider device metadata.")
            }
            let type: ONNXHardwareType
            switch api.pointee.HardwareDevice_Type!(hardware) {
            case OrtHardwareDeviceType_CPU: type = .cpu
            case OrtHardwareDeviceType_GPU: type = .gpu
            case OrtHardwareDeviceType_NPU: type = .npu
            default: throw ONNXRuntimeError(message: "ONNX Runtime returned an unsupported provider hardware type.")
            }
            var metadata: [String: String] = [:]
            if let pairs = api.pointee.HardwareDevice_Metadata!(hardware) {
                for key in ["Description", "LUID", "DxgiVideoMemory"] {
                    if let value = key.withCString({ api.pointee.GetKeyValue!(pairs, $0) }) { metadata[key] = String(cString: value) }
                }
            }
            result.append(ONNXProviderDevice(epName: String(cString: name), epVendor: String(cString: vendor), hardwareType: type,
                vendorID: api.pointee.HardwareDevice_VendorId!(hardware), deviceID: api.pointee.HardwareDevice_DeviceId!(hardware),
                metadata: metadata, handle: handle, registrationID: registration.id))
        }
        return result
    }

    func acquire(device: ONNXProviderDevice, options: OpaquePointer) throws -> ONNXProviderLease {
        lock.lock(); defer { lock.unlock() }
        var match: ONNXProviderRegistration?
        for candidate in registrations.values where candidate.id == device.registrationID { match = candidate; break }
        guard let registration = match, registration.registered, registration.devices.contains(device.handle) else {
            throw ONNXRuntimeError(message: "Provider device is stale or not owned by this registry.")
        }
        let selected: [OpaquePointer?] = [device.handle]
        try checkStatus(selected.withUnsafeBufferPointer { api.pointee.SessionOptionsAppendExecutionProvider_V2!(options, environment, $0.baseAddress, 1, nil, nil, 0) },
            api: api, context: "Selecting provider device \(device.epName) failed")
        try checkStatus("session.disable_cpu_ep_fallback".withCString { k in "1".withCString { api.pointee.AddSessionConfigEntry!(options, k, $0) } },
            api: api, context: "Disabling CPU fallback for provider device \(device.epName) failed")
        if let lease = registration.lease { return lease }
        let lease = ONNXProviderLease(); registration.lease = lease
        return lease
    }

    public func unregister(name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let registration = registrations[name] else { throw ONNXRuntimeError(message: "Provider registration does not exist: \(name)") }
        guard registration.lease == nil else { throw ONNXRuntimeError(message: "Provider \(name) is held by active sessions or values.") }
        if registration.registered {
            try checkStatus(name.withCString { api.pointee.UnregisterExecutionProviderLibrary!(environment, $0) }, api: api, context: "Unregistering provider \(name) failed")
            registration.registered = false
        }
        #if os(Windows)
        try removeCookies(&registration.cookies)
        #endif
        registrations.removeValue(forKey: name)
    }

    func epDevices() throws -> [OpaquePointer] {
        var devices: UnsafePointer<OpaquePointer?>?; var count = 0
        try checkStatus(api.pointee.GetEpDevices!(environment, &devices, &count), api: api, context: "ONNX Runtime provider device query failed")
        guard count == 0 || devices != nil else { throw ONNXRuntimeError(message: "ONNX Runtime returned no provider device array.") }
        return try (0..<count).map { guard let device = devices![$0] else { throw ONNXRuntimeError(message: "ONNX Runtime returned a null provider device.") }; return device }
    }

    #if os(Windows)
    func removeCookies(_ cookies: inout [UnsafeMutableRawPointer]) throws {
        var remaining: [UnsafeMutableRawPointer] = [], failures: [String] = []
        for cookie in cookies { if !RemoveDllDirectory(cookie) { failures.append(String(GetLastError())); remaining.append(cookie) } }
        cookies = remaining
        guard failures.isEmpty else { throw ONNXRuntimeError(message: "RemoveDllDirectory failed (Win32 \(failures.joined(separator: ", "))).") }
    }
    #endif
}
