import CoreAudio
import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevCapture

// MARK: Fake HAL

/// Property-level fake: no real AudioObject call, write or listener can escape it.
@MainActor
private final class FakeHAL: MicInputVolumeHAL {
    enum Response { case apply, quantize(Float), ignore, reverse, silent }

    var defaultDevice: AudioObjectID = 7
    var devices: [String: AudioObjectID] = ["mic": 7, "other": 9]
    var uids: [AudioObjectID: String] = [7: "mic", 9: "other"]
    var channels: [AudioObjectID: Int] = [7: 1, 9: 1]
    var volumes: [AudioObjectID: [UInt32: Float]] = [7: [0: 0.53], 9: [0: 0.2]]
    var settable: Set<UInt32> = [0]
    var setFailures: Set<UInt32> = []
    var response: Response = .apply
    private(set) var writes: [(AudioObjectID, UInt32, Float)] = []
    private(set) var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private(set) var removed: [(AudioObjectID, AudioObjectPropertyAddress)] = []

    func defaultInputDevice() throws(MicInputVolumeFailure) -> AudioObjectID { defaultDevice }
    func device(forUID uid: String) throws(MicInputVolumeFailure) -> AudioObjectID {
        devices[uid] ?? AudioObjectID(kAudioObjectUnknown)
    }
    func uid(of device: AudioObjectID) throws(MicInputVolumeFailure) -> String {
        guard let uid = uids[device] else { throw .deviceIdentityUnverified }
        return uid
    }
    func inputChannelCount(of device: AudioObjectID) throws(MicInputVolumeFailure) -> Int {
        channels[device] ?? 0
    }
    func hasInputVolume(_ device: AudioObjectID, element: UInt32) -> Bool {
        volumes[device]?[element] != nil
    }
    func isInputVolumeSettable(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Bool {
        device == 7 && settable.contains(element)
    }
    func inputVolume(_ device: AudioObjectID, element: UInt32) throws(MicInputVolumeFailure) -> Float {
        guard let value = volumes[device]?[element] else { throw .propertyUnavailable }
        return value
    }
    func setInputVolume(_ device: AudioObjectID, element: UInt32, to value: Float) throws(MicInputVolumeFailure) {
        writes.append((device, element, value))
        if setFailures.contains(element) { throw .writeRejected }
        let before = volumes[device]![element]!
        let applied: Float? = switch response {
        case .apply: value
        case .quantize(let step): (value / step).rounded() * step
        case .ignore: before
        case .reverse: before - (value - before)
        case .silent: nil
        }
        guard let applied else { return }
        // The HAL applies and notifies asynchronously on its own queue.
        Task { @MainActor in
            self.volumes[device]![element] = applied
            self.notify(device, MicInputVolumeAddress.inputVolume(element))
        }
    }
    func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ queue: DispatchQueue,
                     _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        listeners.append((object, address, block))
    }
    func removeListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ queue: DispatchQueue,
                        _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        removed.append((object, address))
        listeners.removeAll { $0.0 == object && $0.1 == address }
    }

    func notify(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        for (registered, registeredAddress, block) in listeners
        where registered == object && registeredAddress == address {
            var changed = address
            withUnsafePointer(to: &changed) { block(1, $0) }
        }
    }

    func manualChange(_ element: UInt32, to value: Float) {
        volumes[7]![element] = value
        notify(7, MicInputVolumeAddress.inputVolume(element))
    }
}

@MainActor
private final class ExternalCounter {
    var count = 0
}

@MainActor
private func drainMainActor() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func adapter(_ hal: FakeHAL, timeout: TimeInterval) -> CoreAudioMicInputVolume {
    CoreAudioMicInputVolume(hal: hal, acknowledgementTimeout: timeout)
}

private func elements(_ pairs: [(UInt32, Float)]) -> [MicInputVolumeElement] {
    pairs.map { MicInputVolumeElement(element: $0.0, scalar: $0.1) }
}

/// Linked Float steps are compared within one ULP-scale tolerance.
private func close(_ lhs: [UInt32: Float], _ rhs: [UInt32: Float]) -> Bool {
    lhs.keys.sorted() == rhs.keys.sorted() && lhs.allSatisfy { abs($0.value - rhs[$0.key]!) < 1e-6 }
}

private func close(_ lhs: [MicInputVolumeElement]?, _ rhs: [(UInt32, Float)]) -> Bool {
    guard let lhs, lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0.element == $1.0 && abs($0.scalar - $1.1) < 1e-6 }
}

// MARK: Fake volume control for the controller

@MainActor
private final class FakeVolume: MicInputVolumeControlling {
    enum Write {
        case apply
        case fail(MicInputVolumeFailure, applied: Bool, unresolved: [UInt32])
        case hang
    }

    let uid = "mic"
    var values: [UInt32: Float]
    var isSettable = true
    var bindFailure: MicInputVolumeFailure?
    var snapshotFailure: MicInputVolumeFailure?
    var writeMode: Write = .apply
    private(set) var binds = 0
    private(set) var unbinds = 0
    private(set) var writes: [[MicInputVolumeElement]] = []
    private var onExternalChange: (@MainActor @Sendable () -> Void)?
    private var hung: CheckedContinuation<Void, Never>?

    init(values: [UInt32: Float]) { self.values = values }

    private var current: MicInputVolumeSnapshot {
        MicInputVolumeSnapshot(
            deviceUID: uid,
            elements: values.keys.sorted().map { MicInputVolumeElement(element: $0, scalar: values[$0]!) },
            isSettable: isSettable
        )
    }

    func bind(captureDeviceUID: String,
              onExternalChange: @escaping @MainActor @Sendable () -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot {
        binds += 1
        if let bindFailure { throw bindFailure }
        self.onExternalChange = onExternalChange
        return current
    }

    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot {
        if let snapshotFailure { throw snapshotFailure }
        return current
    }

    func setVolumes(_ requested: [MicInputVolumeElement], expected: MicInputVolumeSnapshot)
        async throws(MicInputVolumeWriteFailure) -> MicInputVolumeSnapshot {
        writes.append(requested)
        switch writeMode {
        case .apply:
            apply(requested)
            return current
        case .fail(let reason, let applied, let unresolved):
            if applied { apply(requested) }
            throw MicInputVolumeWriteFailure(reason: reason, effective: current.elements, unresolved: unresolved)
        case .hang:
            await withCheckedContinuation { hung = $0 }
            apply(requested)
            return current
        }
    }

    func unbind() throws(MicInputVolumeFailure) { unbinds += 1 }

    private func apply(_ requested: [MicInputVolumeElement]) {
        for value in requested { values[value.element] = value.scalar }
    }

    func manualChange(_ element: UInt32, to value: Float) {
        values[element] = value
        onExternalChange?()
    }

    func releaseHungWrite() {
        hung?.resume()
        hung = nil
    }
}

@MainActor
private final class Harness {
    var time = 0.0
    var statuses: [MicInputStatus] = []
    var effectiveChanges = 0
    let volume: FakeVolume?
    var controller: MicInputVolumeController!

    init(volume: FakeVolume?, pendingWriteTimeout: TimeInterval) {
        self.volume = volume
        controller = MicInputVolumeController(
            sessionID: UUID(), volume: volume, pendingWriteTimeout: pendingWriteTimeout,
            now: { [unowned self] in self.time },
            onStatus: { [unowned self] _, status in self.statuses.append(status) },
            onEffectiveChange: { [unowned self] in self.effectiveChanges += 1 }
        )
        controller.bind(captureDeviceUID: "mic")
    }

    func speak(from start: Double, windows: Int, dBFS: Double) async {
        for index in 0..<windows {
            let begin = start + Double(index) * 0.25
            time = begin + 0.3
            controller.consumeSpeech([MicLevelWindow(
                startSeconds: begin, endSeconds: begin + 0.25, speechSeconds: 0.25,
                speechMeanSquare: pow(10, dBFS / 10), speechPeak: 0.1, inputPeak: 0, clippedFraction: 0
            )])
            await drainMainActor()
        }
    }

    func raw(from start: Double, windows: Int, clipped: Double) async {
        for index in 0..<windows {
            let begin = start + Double(index) * 0.1
            time = begin + 0.12
            controller.consumeRaw([MicLevelWindow(
                startSeconds: begin, endSeconds: begin + 0.1, speechSeconds: 0, speechMeanSquare: nil,
                speechPeak: 0, inputPeak: clipped > 0 ? 1 : 0, clippedFraction: clipped
            )])
            await drainMainActor()
        }
    }
}

@Suite struct MicInputVolumeTests {
    // MARK: Adapter topology and identity

    @MainActor
    @Test("A usable main element is managed alone and listened to without any write")
    func adapterMainElement() throws {
        let hal = FakeHAL()
        hal.volumes[7] = [0: 0.53, 1: 0.4]
        hal.settable = [0, 1]
        let snapshot = try adapter(hal, timeout: 1).bind(captureDeviceUID: "mic") {}
        #expect(snapshot == MicInputVolumeSnapshot(deviceUID: "mic", elements: elements([(0, 0.53)]), isSettable: true))
        #expect(hal.writes.isEmpty)
        #expect(hal.listeners.map(\.1.mSelector) == [
            kAudioDevicePropertyVolumeScalar, kAudioHardwarePropertyDefaultInputDevice,
            kAudioDevicePropertyDeviceIsAlive
        ])
    }

    @MainActor
    @Test("Per-channel controls are managed only with complete writable coverage")
    func adapterChannelTopologies() throws {
        let full = FakeHAL()
        full.channels[7] = 2
        full.volumes[7] = [1: 0.5, 2: 0.4]
        full.settable = [1, 2]
        #expect(try adapter(full, timeout: 1).bind(captureDeviceUID: "mic") {} ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: elements([(1, 0.5), (2, 0.4)]), isSettable: true))

        let partial = FakeHAL()
        partial.channels[7] = 2
        partial.volumes[7] = [1: 0.5, 2: 0.4]
        partial.settable = [1]
        #expect(try adapter(partial, timeout: 1).bind(captureDeviceUID: "mic") {}.isSettable == false)
        #expect(partial.listeners.isEmpty)

        let missingChannel = FakeHAL()
        missingChannel.channels[7] = 2
        missingChannel.volumes[7] = [1: 0.5]
        missingChannel.settable = [1]
        #expect(try adapter(missingChannel, timeout: 1).bind(captureDeviceUID: "mic") {}.isSettable == false)

        let readOnlyMain = FakeHAL()
        readOnlyMain.settable = []
        #expect(try adapter(readOnlyMain, timeout: 1).bind(captureDeviceUID: "mic") {} ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: [], isSettable: false))

        let absent = FakeHAL()
        absent.volumes[7] = [:]
        #expect(try adapter(absent, timeout: 1).bind(captureDeviceUID: "mic") {} ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: [], isSettable: false))
        #expect(absent.listeners.isEmpty && absent.writes.isEmpty)
    }

    @MainActor
    @Test("Unknown, mismatched and non-default capture UIDs are rejected as unverified identity")
    func adapterRejectsUncertainIdentity() {
        let unknown = FakeHAL()
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(unknown, timeout: 1).bind(captureDeviceUID: "missing") {}
        }
        let mismatched = FakeHAL()
        mismatched.uids[7] = "renamed"
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(mismatched, timeout: 1).bind(captureDeviceUID: "mic") {}
        }
        let notDefault = FakeHAL()
        notDefault.defaultDevice = 9
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(notDefault, timeout: 1).bind(captureDeviceUID: "mic") {}
        }
        #expect(unknown.listeners.isEmpty && mismatched.listeners.isEmpty && notDefault.listeners.isEmpty)
    }

    // MARK: Adapter writes

    @MainActor
    @Test("A stale expected snapshot is refused before any write")
    func adapterRefusesStaleExpectation() async throws {
        let hal = FakeHAL()
        let volume = adapter(hal, timeout: 1)
        let bound = try volume.bind(captureDeviceUID: "mic") {}
        hal.volumes[7]![0] = 0.6
        await #expect(throws: MicInputVolumeWriteFailure(reason: .staleExpectedValues, effective: [], unresolved: [])) {
            try await volume.setVolumes(elements([(0, 0.58)]), expected: bound)
        }
        #expect(hal.writes.isEmpty)
    }

    @MainActor
    @Test("Quantized asynchronous acknowledgement stores the actual value and is not a manual change")
    func adapterQuantizedAcknowledgement() async throws {
        let hal = FakeHAL()
        hal.response = .quantize(1 / 16)
        let external = ExternalCounter()
        let volume = adapter(hal, timeout: 1)
        let bound = try volume.bind(captureDeviceUID: "mic") { external.count += 1 }
        let effective = try await volume.setVolumes(elements([(0, 0.58)]), expected: bound)
        #expect(effective.elements == elements([(0, 0.5625)]))
        #expect(hal.writes.map(\.0) == [7])
        hal.notify(7, MicInputVolumeAddress.inputVolume(0))
        await drainMainActor()
        #expect(external.count == 0)
        hal.manualChange(0, to: 0.8)
        await drainMainActor()
        #expect(external.count == 1)
    }

    @MainActor
    @Test("No movement, wrong direction, timeout and partial writes fail with their reason")
    func adapterWriteFailures() async throws {
        func attempt(_ configure: (FakeHAL) -> Void, targets: [(UInt32, Float)]) async throws -> MicInputVolumeWriteFailure? {
            let hal = FakeHAL()
            configure(hal)
            let volume = adapter(hal, timeout: 0.05)
            let bound = try volume.bind(captureDeviceUID: "mic") {}
            do throws(MicInputVolumeWriteFailure) {
                _ = try await volume.setVolumes(elements(targets), expected: bound)
                return nil
            } catch {
                return error
            }
        }
        #expect(try await attempt({ $0.response = .ignore }, targets: [(0, 0.58)]) ==
                MicInputVolumeWriteFailure(reason: .noMovement, effective: elements([(0, 0.53)]), unresolved: []))
        #expect(try await attempt({ $0.response = .reverse }, targets: [(0, 0.58)])?.reason == .unexpectedMovement)
        #expect(try await attempt({ $0.response = .silent }, targets: [(0, 0.58)]) ==
                MicInputVolumeWriteFailure(reason: .acknowledgementTimeout, effective: elements([(0, 0.53)]),
                                           unresolved: [0]))
        let partial = try await attempt({
            $0.channels[7] = 2
            $0.volumes[7] = [1: 0.5, 2: 0.4]
            $0.settable = [1, 2]
            $0.setFailures = [2]
        }, targets: [(1, 0.55), (2, 0.45)])
        #expect(partial == MicInputVolumeWriteFailure(
            reason: .partialWrite, effective: elements([(1, 0.55), (2, 0.4)]), unresolved: []
        ))
    }

    @MainActor
    @Test("Unbind removes every registered listener and silences retained blocks")
    func adapterUnbindRemovesListeners() async throws {
        let hal = FakeHAL()
        let external = ExternalCounter()
        let volume = adapter(hal, timeout: 1)
        _ = try volume.bind(captureDeviceUID: "mic") { external.count += 1 }
        let registered = hal.listeners.map { ($0.0, $0.1) }
        let retained = hal.listeners.map(\.2)
        try volume.unbind()
        #expect(hal.removed.map(\.0) == registered.map(\.0))
        #expect(hal.removed.map(\.1) == registered.map(\.1))
        #expect(hal.listeners.isEmpty)
        var address = MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice)
        for block in retained { withUnsafePointer(to: &address) { block(1, $0) } }
        await drainMainActor()
        #expect(external.count == 0)
    }

    @MainActor
    @Test("A default-input change is external and never retargets writes to the new device")
    func adapterDefaultChangeNeverRetargets() async throws {
        let hal = FakeHAL()
        let external = ExternalCounter()
        let volume = adapter(hal, timeout: 1)
        let bound = try volume.bind(captureDeviceUID: "mic") { external.count += 1 }
        hal.defaultDevice = 9
        hal.notify(AudioObjectID(kAudioObjectSystemObject),
                   MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice))
        await drainMainActor()
        #expect(external.count == 1)
        _ = try await volume.setVolumes(elements([(0, 0.5)]), expected: bound)
        #expect(hal.writes.map(\.0) == [7])
        #expect(hal.volumes[9] == [0: 0.2])
    }

    // MARK: Controller

    @MainActor
    @Test("Binding writes nothing; quiet speech raises one linked step; silence keeps it")
    func controllerQuietRiseAndSilence() async {
        let harness = Harness(volume: FakeVolume(values: [0: 0.5]), pendingWriteTimeout: 1)
        #expect(harness.volume!.writes.isEmpty)
        #expect(harness.statuses == [MicInputStatus(warning: nil, adjustment: .active)])
        await harness.raw(from: 0, windows: 50, clipped: 0)
        #expect(harness.volume!.writes.isEmpty)
        await harness.speak(from: 5, windows: 12, dBFS: -40)
        #expect(harness.volume!.writes.count == 1 && close(harness.volume!.writes.first, [(0, 0.55)]))
        #expect(harness.effectiveChanges == 1)
    }

    @MainActor
    @Test("Raw clipping lowers every managed element immediately")
    func controllerClipReduction() async {
        let harness = Harness(volume: FakeVolume(values: [1: 0.5, 2: 0.05]), pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        #expect(harness.volume!.writes.count == 1 && close(harness.volume!.writes.first, [(1, 0.4), (2, 0)]))
    }

    @MainActor
    @Test("With the setting off the recording warns but never binds or writes")
    func controllerDisabledWarnsOnly() async {
        let harness = Harness(volume: nil, pendingWriteTimeout: 1)
        await harness.speak(from: 0, windows: 12, dBFS: -40)
        #expect(harness.statuses.last == MicInputStatus(warning: .low, adjustment: .disabledBySetting))
        await harness.controller.stop()
    }

    @MainActor
    @Test("A device without a settable input volume reports that explicitly and warns only on evidence")
    func controllerUnsupportedDevice() async {
        let volume = FakeVolume(values: [0: 0.5])
        volume.isSettable = false
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        #expect(harness.statuses == [MicInputStatus(warning: nil, adjustment: .unsupportedDevice)])
        #expect(volume.unbinds == 1)
        await harness.speak(from: 0, windows: 12, dBFS: -40)
        #expect(harness.statuses.last == MicInputStatus(warning: .low, adjustment: .unsupportedDevice))
        #expect(volume.writes.isEmpty)
    }

    @MainActor
    @Test("An unverified device mapping is an explicit failure, not a silent downgrade")
    func controllerIdentityFailure() {
        let volume = FakeVolume(values: [0: 0.5])
        volume.bindFailure = .deviceIdentityUnverified
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        #expect(harness.statuses == [MicInputStatus(warning: nil, adjustment: .failed(.deviceIdentityUnverified))])
    }

    @MainActor
    @Test("A manual slider change pauses all writes, including clipping, and is never overwritten")
    func controllerManualSuspension() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        #expect(close(volume.values, [0: 0.4]))
        volume.manualChange(0, to: 0.7)
        #expect(harness.statuses.last?.adjustment == .pausedByExternalChange)
        await harness.raw(from: 1, windows: 20, clipped: 0.01)
        #expect(volume.writes.count == 1)
        #expect(harness.statuses.last == MicInputStatus(warning: .clipping, adjustment: .pausedByExternalChange))
        await harness.controller.stop()
        #expect(volume.values == [0: 0.7])
        #expect(volume.writes.count == 1 && volume.unbinds == 1)
    }

    @MainActor
    @Test("Stop restores only elements still at the app's last value")
    func controllerRestoresOwnedOnly() async {
        let volume = FakeVolume(values: [1: 0.5, 2: 0.4])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.speak(from: 0, windows: 12, dBFS: -40)
        #expect(close(volume.values, [1: 0.55, 2: 0.45]))
        volume.manualChange(2, to: 0.8)
        await harness.controller.stop()
        #expect(volume.writes.last == elements([(1, 0.5)]))
        #expect(volume.values == [1: 0.5, 2: 0.8])
        #expect(volume.unbinds == 1)
    }

    @MainActor
    @Test("Stop compares current values, so a change whose notification never arrived is kept")
    func controllerRestoreChecksCurrentValue() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        volume.values[0] = 0.75
        await harness.controller.stop()
        #expect(volume.writes.count == 1)
        #expect(volume.values == [0: 0.75])
    }

    @MainActor
    @Test("A failed write stops automatic changes for the recording and reports its reason")
    func controllerWriteFailure() async {
        let volume = FakeVolume(values: [0: 0.5])
        volume.writeMode = .fail(.noMovement, applied: false, unresolved: [])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        #expect(harness.statuses.last == MicInputStatus(warning: nil, adjustment: .failed(.noMovement)))
        await harness.raw(from: 1, windows: 20, clipped: 0.01)
        #expect(volume.writes.count == 1)
        #expect(harness.statuses.last == MicInputStatus(warning: .clipping, adjustment: .failed(.noMovement)))
    }

    @MainActor
    @Test("A partial write keeps ownership of the element that moved for restoration")
    func controllerPartialWriteRestore() async {
        let volume = FakeVolume(values: [0: 0.5])
        volume.writeMode = .fail(.acknowledgementTimeout, applied: true, unresolved: [])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        #expect(harness.statuses.last?.adjustment == .failed(.acknowledgementTimeout))
        volume.writeMode = .apply
        await harness.controller.stop()
        #expect(volume.values == [0: 0.5])
    }

    @MainActor
    @Test("Termination relinquishes ownership without an unconfirmed restore write")
    func controllerTerminate() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        harness.controller.terminate()
        #expect(volume.writes.count == 1 && volume.unbinds == 1)
        await harness.raw(from: 1, windows: 5, clipped: 0.01)
        #expect(volume.writes.count == 1)
    }

    @MainActor
    @Test("An unresolved in-flight write is never restored or claimed after stop")
    func controllerUnresolvedPendingWrite() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 0.05)
        await harness.speak(from: 0, windows: 12, dBFS: -40)
        #expect(close(volume.values, [0: 0.55]))
        volume.writeMode = .hang
        await harness.raw(from: 10, windows: 1, clipped: 0.01)
        #expect(volume.writes.count == 2)
        await harness.controller.stop()
        #expect(volume.writes.count == 2)
        #expect(harness.statuses.last?.adjustment == .restoreFailed(.writeUnresolved))
        #expect(volume.unbinds == 1)
        let reported = harness.statuses.count
        volume.releaseHungWrite()
        await drainMainActor()
        #expect(volume.writes.count == 2)
        #expect(harness.statuses.count == reported)
        #expect(harness.effectiveChanges == 1)
    }

    @MainActor
    @Test("A failed restoration is reported explicitly")
    func controllerRestoreFailure() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        volume.writeMode = .fail(.writeRejected, applied: false, unresolved: [])
        await harness.controller.stop()
        #expect(harness.statuses.last?.adjustment == .restoreFailed(.writeRejected))
        #expect(volume.unbinds == 1)
    }

    @MainActor
    @Test("Speech monitoring loss stops speech rises but keeps clipping protection")
    func controllerMonitoringUnavailable() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        harness.controller.speechMonitoringUnavailable()
        #expect(harness.statuses.last == MicInputStatus(warning: .monitoringUnavailable, adjustment: .active))
        await harness.speak(from: 0, windows: 20, dBFS: -40)
        #expect(volume.writes.isEmpty)
        await harness.raw(from: 6, windows: 1, clipped: 0.01)
        #expect(volume.writes.count == 1 && close(volume.writes.first, [(0, 0.4)]))
    }
}
