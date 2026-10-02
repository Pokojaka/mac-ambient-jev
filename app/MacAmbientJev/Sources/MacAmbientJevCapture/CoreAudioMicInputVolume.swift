import CoreAudio
import Foundation
import MacAmbientJevCore

/// Every AudioObject call used for input volume. Tests replace it so no real HAL call runs.
@MainActor
protocol MicInputVolumeHAL {
    func defaultInputDevice() throws(MicInputVolumeFailure) -> AudioObjectID
    func device(forUID uid: String) throws(MicInputVolumeFailure) -> AudioObjectID
    func uid(of device: AudioObjectID) throws(MicInputVolumeFailure) -> String
    func inputChannelCount(of device: AudioObjectID) throws(MicInputVolumeFailure) -> Int
    func hasInputVolume(_ device: AudioObjectID, element: UInt32) -> Bool
    func isInputVolumeSettable(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Bool
    func inputVolume(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Float
    func setInputVolume(_ device: AudioObjectID, element: UInt32, to value: Float) throws(MicInputVolumeFailure)
    func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                     _ queue: DispatchQueue,
                     _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure)
    func removeListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ queue: DispatchQueue,
                        _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure)
}

enum MicInputVolumeAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func inputVolume(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeInput, mElement: element)
    }
}

struct CoreAudioMicInputVolumeHAL: MicInputVolumeHAL {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func check(_ status: OSStatus, _ failure: MicInputVolumeFailure) throws(MicInputVolumeFailure) {
        guard status == noErr else { throw failure }
    }

    func defaultInputDevice() throws(MicInputVolumeFailure) -> AudioObjectID {
        var address = MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &device),
                       .propertyUnavailable)
        return device
    }

    func device(forUID uid: String) throws(MicInputVolumeFailure) -> AudioObjectID {
        var address = MicInputVolumeAddress.global(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(Self.system, &address, UInt32(MemoryLayout<CFString>.size),
                                       pointer, &size, &device)
        }
        try Self.check(status, .deviceIdentityUnverified)
        return device
    }

    func uid(of device: AudioObjectID) throws(MicInputVolumeFailure) -> String {
        var address = MicInputVolumeAddress.global(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try Self.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid),
                       .deviceIdentityUnverified)
        guard let uid else { throw .deviceIdentityUnverified }
        return uid.takeRetainedValue() as String
    }

    func inputChannelCount(of device: AudioObjectID) throws(MicInputVolumeFailure) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), .propertyUnavailable)
        guard Int(size) >= MemoryLayout<AudioBufferList>.size else { throw .propertyUnavailable }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try Self.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage),
                       .propertyUnavailable)
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func hasInputVolume(_ device: AudioObjectID, element: UInt32) -> Bool {
        var address = MicInputVolumeAddress.inputVolume(element)
        return AudioObjectHasProperty(device, &address)
    }

    func isInputVolumeSettable(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Bool {
        var address = MicInputVolumeAddress.inputVolume(element)
        var settable = DarwinBoolean(false)
        try Self.check(AudioObjectIsPropertySettable(device, &address, &settable), .propertyUnavailable)
        return settable.boolValue
    }

    func inputVolume(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Float {
        var address = MicInputVolumeAddress.inputVolume(element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try Self.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value),
                       .propertyUnavailable)
        guard size == UInt32(MemoryLayout<Float32>.size) else { throw .invalidValue }
        return value
    }

    func setInputVolume(_ device: AudioObjectID, element: UInt32, to value: Float) throws(MicInputVolumeFailure) {
        var address = MicInputVolumeAddress.inputVolume(element)
        var scalar = Float32(value)
        try Self.check(AudioObjectSetPropertyData(device, &address, 0, nil,
                                                  UInt32(MemoryLayout<Float32>.size), &scalar),
                       .writeRejected)
    }

    func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                     _ queue: DispatchQueue,
                     _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        var address = address
        try Self.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block),
                       .listenerRegistrationFailed)
    }

    func removeListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ queue: DispatchQueue,
                        _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        var address = address
        try Self.check(AudioObjectRemovePropertyListenerBlock(object, &address, queue, block),
                       .listenerRemovalFailed)
    }
}

/// Binds to the capture device's input-scope VolumeScalar controls: main element first,
/// otherwise every input channel. Writes are confirmed by HAL notification plus readback.
@MainActor
final class CoreAudioMicInputVolume: MicInputVolumeControlling {
    static let tolerance: Float = 0.001
    static let quantizationAllowance: Float = 0.01

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct Binding {
        let device: AudioObjectID
        let uid: String
        let elements: [UInt32]
        let isSettable: Bool
        var known: [UInt32: Float]
        let onChange: @MainActor @Sendable (MicInputVolumeChange) -> Void
    }

    private struct OwnWrite {
        let token: UInt64
        var written: Set<UInt32> = []
        var notified: Set<UInt32> = []
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private let hal: any MicInputVolumeHAL
    private let acknowledgementTimeout: TimeInterval
    private let queue = DispatchQueue(label: "app.mac-ambient-jev.mic-input-volume")
    private var binding: Binding?
    private var listeners: [Listener] = []
    private var generation: UInt64 = 0
    private var ownWrite: OwnWrite?

    init(hal: any MicInputVolumeHAL, acknowledgementTimeout: TimeInterval) {
        self.hal = hal
        self.acknowledgementTimeout = acknowledgementTimeout
    }

    func bind(captureDeviceUID: String,
              onChange: @escaping @MainActor @Sendable (MicInputVolumeChange) -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot {
        precondition(binding == nil, "unbind before binding again")
        let defaultDevice = try hal.defaultInputDevice()
        let device = try hal.device(forUID: captureDeviceUID)
        guard device != kAudioObjectUnknown, device == defaultDevice,
              try hal.uid(of: device) == captureDeviceUID else { throw .deviceIdentityUnverified }
        let (elements, isSettable) = try probe(device)
        var known: [UInt32: Float] = [:]
        for element in elements { known[element] = try read(device, element) }
        generation += 1
        binding = Binding(device: device, uid: captureDeviceUID, elements: elements,
                          isSettable: isSettable, known: known, onChange: onChange)
        if isSettable {
            do throws(MicInputVolumeFailure) {
                try listen(device: device, elements: elements)
            } catch {
                try removeListeners()
                binding = nil
                throw error
            }
        }
        return snapshot(of: binding!)
    }

    /// Main element if it is fully usable; otherwise complete input-channel coverage or nothing.
    private func probe(_ device: AudioObjectID) throws(MicInputVolumeFailure) -> ([UInt32], Bool) {
        let main = kAudioObjectPropertyElementMain
        if hal.hasInputVolume(device, element: main) {
            _ = try read(device, main)
            if try hal.isInputVolumeSettable(device, element: main) { return ([main], true) }
        }
        let channels = try hal.inputChannelCount(of: device)
        guard channels > 0 else { return ([], false) }
        var elements: [UInt32] = []
        var settable = true
        for element in UInt32(1)...UInt32(channels) {
            guard hal.hasInputVolume(device, element: element) else {
                settable = false
                continue
            }
            _ = try read(device, element)
            elements.append(element)
            if !(try hal.isInputVolumeSettable(device, element: element)) { settable = false }
        }
        return (elements, settable)
    }

    private func read(_ device: AudioObjectID, _ element: UInt32) throws(MicInputVolumeFailure) -> Float {
        let value = try hal.inputVolume(device, element: element)
        guard value.isFinite, value >= 0, value <= 1 else { throw .invalidValue }
        return value
    }

    private func listen(device: AudioObjectID, elements: [UInt32]) throws(MicInputVolumeFailure) {
        let token = generation
        var targets = elements.map { (device, MicInputVolumeAddress.inputVolume($0)) }
        targets.append((AudioObjectID(kAudioObjectSystemObject),
                        MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice)))
        targets.append((device, MicInputVolumeAddress.global(kAudioDevicePropertyDeviceIsAlive)))
        for (object, address) in targets {
            // HAL invokes this on its queue, not the actor that registered it.
            let block: AudioObjectPropertyListenerBlock = { @Sendable [weak self] count, addresses in
                let changed = Array(UnsafeBufferPointer(start: addresses, count: Int(count)))
                Task { @MainActor in self?.received(changed, token: token) }
            }
            try hal.addListener(object, address, queue, block)
            listeners.append(Listener(object: object, address: address, block: block))
        }
    }

    private func removeListeners() throws(MicInputVolumeFailure) {
        let registered = listeners
        listeners.removeAll()
        var failure: MicInputVolumeFailure?
        for listener in registered {
            do throws(MicInputVolumeFailure) {
                try hal.removeListener(listener.object, listener.address, queue, listener.block)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    private func received(_ addresses: [AudioObjectPropertyAddress], token: UInt64) {
        guard token == generation, let binding else { return }
        var external = false
        var defaultInputChanged = false
        for address in addresses {
            switch address.mSelector {
            case kAudioDevicePropertyVolumeScalar:
                if var write = ownWrite, write.written.contains(address.mElement) {
                    write.notified.insert(address.mElement)
                    ownWrite = write
                    if write.written.isSubset(of: write.notified) { resolveOwnWrite(acknowledged: true) }
                    continue
                }
                guard let known = binding.known[address.mElement] else { continue }
                do throws(MicInputVolumeFailure) {
                    if abs(try read(binding.device, address.mElement) - known) > Self.tolerance {
                        external = true
                    }
                } catch {
                    external = true
                }
            case kAudioHardwarePropertyDefaultInputDevice:
                defaultInputChanged = true
            default:
                external = true
            }
        }
        if defaultInputChanged {
            binding.onChange(.defaultInputDevice)
        } else if external {
            binding.onChange(.controls)
        }
    }

    private func resolveOwnWrite(acknowledged: Bool) {
        guard let continuation = ownWrite?.continuation else { return }
        ownWrite?.continuation = nil
        continuation.resume(returning: acknowledged)
    }

    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot {
        guard let binding else { throw .notBound }
        guard try hal.uid(of: binding.device) == binding.uid else { throw .deviceIdentityUnverified }
        var elements: [MicInputVolumeElement] = []
        for element in binding.elements {
            elements.append(MicInputVolumeElement(element: element, scalar: try read(binding.device, element)))
        }
        return MicInputVolumeSnapshot(deviceUID: binding.uid, elements: elements,
                                      isSettable: binding.isSettable)
    }

    private func snapshot(of binding: Binding) -> MicInputVolumeSnapshot {
        MicInputVolumeSnapshot(
            deviceUID: binding.uid,
            elements: binding.elements.map { MicInputVolumeElement(element: $0, scalar: binding.known[$0]!) },
            isSettable: binding.isSettable
        )
    }

    func setVolumes(_ values: [MicInputVolumeElement],
                    expected: MicInputVolumeSnapshot) async throws(MicInputVolumeWriteFailure)
        -> MicInputVolumeSnapshot {
        func failure(_ reason: MicInputVolumeFailure) -> MicInputVolumeWriteFailure {
            MicInputVolumeWriteFailure(reason: reason, effective: [], unresolved: [])
        }
        guard let binding, binding.isSettable, ownWrite == nil else { throw failure(.notBound) }
        guard expected.deviceUID == binding.uid,
              expected.elements.map(\.element) == binding.elements else {
            throw failure(.staleExpectedValues)
        }
        var targets: [UInt32: Float] = [:]
        for value in values {
            guard binding.elements.contains(value.element), targets[value.element] == nil,
                  value.scalar.isFinite, value.scalar >= 0, value.scalar <= 1 else {
                throw failure(.invalidValue)
            }
            targets[value.element] = value.scalar
        }
        let before: [UInt32: Float]
        do throws(MicInputVolumeFailure) {
            guard try hal.uid(of: binding.device) == binding.uid else {
                throw MicInputVolumeFailure.deviceIdentityUnverified
            }
            before = try readAll(binding)
        } catch {
            throw failure(error)
        }
        for element in expected.elements
        where abs(before[element.element]! - element.scalar) > Self.tolerance {
            throw failure(.staleExpectedValues)
        }
        let changes = targets.filter { abs($0.value - before[$0.key]!) > Self.tolerance }
        guard !changes.isEmpty else { return snapshot(of: binding) }

        let token = generation
        ownWrite = OwnWrite(token: token)
        var setterFailure: MicInputVolumeFailure?
        for element in changes.keys.sorted() {
            ownWrite?.written.insert(element)
            do throws(MicInputVolumeFailure) {
                try hal.setInputVolume(binding.device, element: element, to: changes[element]!)
            } catch {
                ownWrite?.written.remove(element)
                setterFailure = error
                break
            }
        }
        let written = ownWrite!.written
        let acknowledged = written.isEmpty ? true : await waitForAcknowledgement(token: token)
        ownWrite = nil
        guard token == generation, var current = self.binding else {
            throw MicInputVolumeWriteFailure(reason: .notBound, effective: [], unresolved: written.sorted())
        }
        let after: [UInt32: Float]
        do throws(MicInputVolumeFailure) {
            after = try readAll(current)
        } catch {
            throw MicInputVolumeWriteFailure(reason: error, effective: [], unresolved: written.sorted())
        }
        current.known = after
        self.binding = current
        let effective = snapshot(of: current)

        var moved: [UInt32] = []
        var stalled: [UInt32] = []
        var unexpected = false
        for element in current.elements {
            let change = after[element]! - before[element]!
            guard written.contains(element) else {
                if abs(change) > Self.tolerance { unexpected = true }
                continue
            }
            let requested = changes[element]! - before[element]!
            if abs(change) <= Self.tolerance {
                stalled.append(element)
            } else if (change > 0) == (requested > 0),
                      abs(change) <= abs(requested) + Self.quantizationAllowance {
                moved.append(element)
            } else {
                unexpected = true
            }
        }
        let reason: MicInputVolumeFailure? =
            unexpected ? .unexpectedMovement
            : !acknowledged ? .acknowledgementTimeout
            : setterFailure != nil ? (moved.isEmpty ? setterFailure : .partialWrite)
            : stalled.isEmpty ? nil
            : moved.isEmpty ? .noMovement : .partialWrite
        guard let reason else { return effective }
        throw MicInputVolumeWriteFailure(
            reason: reason, effective: effective.elements,
            unresolved: acknowledged ? [] : stalled
        )
    }

    private func waitForAcknowledgement(token: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            ownWrite?.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + acknowledgementTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.ownWrite?.token == token else { return }
                    self.resolveOwnWrite(acknowledged: false)
                }
            }
        }
    }

    private func readAll(_ binding: Binding) throws(MicInputVolumeFailure) -> [UInt32: Float] {
        var values: [UInt32: Float] = [:]
        for element in binding.elements { values[element] = try read(binding.device, element) }
        return values
    }

    func unbind() throws(MicInputVolumeFailure) {
        generation += 1
        resolveOwnWrite(acknowledged: false)
        binding = nil
        try removeListeners()
    }
}
