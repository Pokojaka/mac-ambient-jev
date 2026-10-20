import CoreAudio
import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline
import Testing
@testable import MacAmbientJevCapture

// MARK: Fake HAL
/// The C block type is not Sendable. This immutable delivery models HAL's cross-queue handoff.
private struct ListenerDelivery: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock
    let address: AudioObjectPropertyAddress

    func enqueue(on queue: DispatchQueue) {
        queue.async { @Sendable in
            dispatchPrecondition(condition: .onQueue(queue))
            dispatchPrecondition(condition: .notOnQueue(.main))
            var changed = address
            withUnsafePointer(to: &changed) { block(1, $0) }
        }
    }
}


@MainActor
private final class ManualAcknowledgementDeadlines {
    private(set) var requestedDelays: [TimeInterval] = []
    private var actions: [@MainActor @Sendable () -> Void] = []
    private var scheduledContinuation: CheckedContinuation<Void, Never>?

    func schedule(_ delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        requestedDelays.append(delay)
        actions.append(action)
        guard let continuation = scheduledContinuation else { return }
        scheduledContinuation = nil
        continuation.resume()
    }

    func waitUntilScheduled() async {
        guard actions.isEmpty else { return }
        await withCheckedContinuation { continuation in
            precondition(scheduledContinuation == nil, "確認期限の予約を複数回待機しています")
            scheduledContinuation = continuation
        }
    }

    func fireNext() {
        precondition(!actions.isEmpty, "発火する確認期限がありません")
        let action = actions.removeFirst()
        action()
    }
}

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
    let acknowledgementDeadlines = ManualAcknowledgementDeadlines()
    private(set) var writes: [(AudioObjectID, UInt32, Float)] = []
    private(set) var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock, DispatchQueue)] = []
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
        // Property storage stays main-actor isolated; notifications use the registered HAL queue.
        Task { @MainActor in
            self.volumes[device]![element] = applied
            self.notify(device, MicInputVolumeAddress.inputVolume(element))
        }
    }
    func addListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ queue: DispatchQueue,
                     _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        listeners.append((object, address, block, queue))
    }
    func removeListener(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ queue: DispatchQueue,
                        _ block: @escaping AudioObjectPropertyListenerBlock) throws(MicInputVolumeFailure) {
        removed.append((object, address))
        listeners.removeAll { $0.0 == object && $0.1 == address }
    }

    func notify(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        for (registered, registeredAddress, block, queue) in listeners
        where registered == object && registeredAddress == address {
            ListenerDelivery(block: block, address: address).enqueue(on: queue)
        }
    }

    func manualChange(_ element: UInt32, to value: Float) {
        volumes[7]![element] = value
        notify(7, MicInputVolumeAddress.inputVolume(element))
    }

    func drainNotifications() async {
        for queue in listeners.map(\.3) {
            await withCheckedContinuation { continuation in
                queue.async { @Sendable in continuation.resume() }
            }
        }
        await drainMainActor()
    }
}

@MainActor
private final class ChangeLog {
    var changes: [MicInputVolumeChange] = []
}

@MainActor
private func drainMainActor() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func adapter(_ hal: FakeHAL, timeout: TimeInterval) -> CoreAudioMicInputVolume {
    CoreAudioMicInputVolume(
        hal: hal,
        acknowledgementTimeout: timeout,
        scheduleAcknowledgementTimeout: hal.acknowledgementDeadlines.schedule
    )
}

private func elements(_ pairs: [(UInt32, Float)]) -> [MicInputVolumeElement] {
    pairs.map { MicInputVolumeElement(element: $0.0, scalar: $0.1) }
}

@Suite struct MicInputVolumeTests {
    // MARK: Adapter topology and identity

    @MainActor
    @Test("A usable main element is managed alone and listened to without any write")
    func adapterMainElement() throws {
        let hal = FakeHAL()
        hal.volumes[7] = [0: 0.53, 1: 0.4]
        hal.settable = [0, 1]
        let snapshot = try adapter(hal, timeout: 1).bind(captureDeviceUID: "mic") { _ in }
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
        #expect(try adapter(full, timeout: 1).bind(captureDeviceUID: "mic") { _ in } ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: elements([(1, 0.5), (2, 0.4)]), isSettable: true))

        let partial = FakeHAL()
        partial.channels[7] = 2
        partial.volumes[7] = [1: 0.5, 2: 0.4]
        partial.settable = [1]
        #expect(try adapter(partial, timeout: 1).bind(captureDeviceUID: "mic") { _ in }.isSettable == false)
        #expect(partial.listeners.isEmpty)

        let missingChannel = FakeHAL()
        missingChannel.channels[7] = 2
        missingChannel.volumes[7] = [1: 0.5]
        missingChannel.settable = [1]
        #expect(try adapter(missingChannel, timeout: 1).bind(captureDeviceUID: "mic") { _ in }.isSettable == false)

        let readOnlyMain = FakeHAL()
        readOnlyMain.settable = []
        #expect(try adapter(readOnlyMain, timeout: 1).bind(captureDeviceUID: "mic") { _ in } ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: [], isSettable: false))

        let absent = FakeHAL()
        absent.volumes[7] = [:]
        #expect(try adapter(absent, timeout: 1).bind(captureDeviceUID: "mic") { _ in } ==
                MicInputVolumeSnapshot(deviceUID: "mic", elements: [], isSettable: false))
        #expect(absent.listeners.isEmpty && absent.writes.isEmpty)
    }

    @MainActor
    @Test("Unknown, mismatched and non-default capture UIDs are rejected as unverified identity")
    func adapterRejectsUncertainIdentity() {
        let unknown = FakeHAL()
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(unknown, timeout: 1).bind(captureDeviceUID: "missing") { _ in }
        }
        let mismatched = FakeHAL()
        mismatched.uids[7] = "renamed"
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(mismatched, timeout: 1).bind(captureDeviceUID: "mic") { _ in }
        }
        let notDefault = FakeHAL()
        notDefault.defaultDevice = 9
        #expect(throws: MicInputVolumeFailure.deviceIdentityUnverified) {
            try adapter(notDefault, timeout: 1).bind(captureDeviceUID: "mic") { _ in }
        }
        #expect(unknown.listeners.isEmpty && mismatched.listeners.isEmpty && notDefault.listeners.isEmpty)
    }

    // MARK: Adapter writes

    @MainActor
    @Test("A stale expected snapshot is refused before any write")
    func adapterRefusesStaleExpectation() async throws {
        let hal = FakeHAL()
        let volume = adapter(hal, timeout: 1)
        let bound = try volume.bind(captureDeviceUID: "mic") { _ in }
        hal.volumes[7]![0] = 0.6
        await #expect(throws: MicInputVolumeWriteFailure(reason: .staleExpectedValues, effective: [], unresolved: [])) {
            try await volume.setVolumes(elements([(0, 0.58)]), expected: bound)
        }
        #expect(hal.writes.isEmpty)
    }

    @MainActor
    @Test("Background HAL callbacks acknowledge own writes and report external changes")
    func adapterQuantizedAcknowledgement() async throws {
        let hal = FakeHAL()
        hal.response = .quantize(1 / 16)
        let external = ChangeLog()
        let volume = adapter(hal, timeout: 1)
        let bound = try volume.bind(captureDeviceUID: "mic") { external.changes.append($0) }
        let effective = try await volume.setVolumes(elements([(0, 0.58)]), expected: bound)
        #expect(effective.elements == elements([(0, 0.5625)]))
        #expect(hal.writes.map(\.0) == [7])
        hal.notify(7, MicInputVolumeAddress.inputVolume(0))
        await hal.drainNotifications()
        #expect(external.changes.isEmpty)
        hal.manualChange(0, to: 0.8)
        await hal.drainNotifications()
        #expect(external.changes == [.controls])
    }

    @MainActor
    @Test("No movement, wrong direction, timeout and partial writes fail with their reason")
    func adapterWriteFailures() async throws {
        func attempt(_ configure: (FakeHAL) -> Void, targets: [(UInt32, Float)]) async throws -> MicInputVolumeWriteFailure? {
            let hal = FakeHAL()
            configure(hal)
            let volume = adapter(hal, timeout: 0.05)
            let bound = try volume.bind(captureDeviceUID: "mic") { _ in }
            let writeTask = Task<MicInputVolumeWriteFailure?, Never> { @MainActor in
                do throws(MicInputVolumeWriteFailure) {
                    _ = try await volume.setVolumes(elements(targets), expected: bound)
                    return nil
                } catch {
                    return error
                }
            }
            await hal.acknowledgementDeadlines.waitUntilScheduled()
            if case .silent = hal.response {
                hal.acknowledgementDeadlines.fireNext()
            }
            let failure = await writeTask.value
            #expect(hal.acknowledgementDeadlines.requestedDelays == [0.05])
            return failure
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
        let external = ChangeLog()
        let volume = adapter(hal, timeout: 1)
        _ = try volume.bind(captureDeviceUID: "mic") { external.changes.append($0) }
        let registered = hal.listeners.map { ($0.0, $0.1) }
        let retained = hal.listeners.map { ($0.2, $0.3) }
        try volume.unbind()
        #expect(hal.removed.map(\.0) == registered.map(\.0))
        #expect(hal.removed.map(\.1) == registered.map(\.1))
        #expect(hal.listeners.isEmpty)
        let address = MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice)
        for (block, queue) in retained {
            ListenerDelivery(block: block, address: address).enqueue(on: queue)
            await withCheckedContinuation { continuation in
                queue.async { @Sendable in continuation.resume() }
            }
        }
        await drainMainActor()
        #expect(external.changes.isEmpty)
    }

    @MainActor
    @Test("A default-input change is reported as such, separately from control changes")
    func adapterReportsDefaultInputChange() async throws {
        let hal = FakeHAL()
        let external = ChangeLog()
        let volume = adapter(hal, timeout: 1)
        _ = try volume.bind(captureDeviceUID: "mic") { external.changes.append($0) }
        hal.defaultDevice = 9
        hal.notify(AudioObjectID(kAudioObjectSystemObject),
                   MicInputVolumeAddress.global(kAudioHardwarePropertyDefaultInputDevice))
        await hal.drainNotifications()
        #expect(external.changes == [.defaultInputDevice])
        #expect(hal.writes.isEmpty)
    }

}
