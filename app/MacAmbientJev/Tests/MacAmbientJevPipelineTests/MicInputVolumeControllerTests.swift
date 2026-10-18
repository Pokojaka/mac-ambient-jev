import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPipeline

@MainActor
private func drainMainActor() async {
    for _ in 0..<20 { await Task.yield() }
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
    private var onChange: (@MainActor @Sendable (MicInputVolumeChange) -> Void)?
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
              onChange: @escaping @MainActor @Sendable (MicInputVolumeChange) -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot {
        binds += 1
        if let bindFailure { throw bindFailure }
        self.onChange = onChange
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
        onChange?(.controls)
    }

    func changeDefaultInputDevice() {
        onChange?(.defaultInputDevice)
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

@Suite struct MicInputVolumeControllerTests {

    @MainActor
    @Test("Binding writes nothing; quiet speech raises one linked step; silence keeps it")
    func controllerQuietRiseAndSilence() async {
        let harness = Harness(volume: FakeVolume(values: [0: 0.5]), pendingWriteTimeout: 1)
        #expect(harness.volume!.writes.isEmpty)
        #expect(harness.statuses == [MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .active)])
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
        #expect(harness.statuses.last == MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .disabledBySetting))
        await harness.controller.stop()
    }

    @MainActor
    @Test("A device without a settable input volume reports that explicitly and warns only on evidence")
    func controllerUnsupportedDevice() async {
        let volume = FakeVolume(values: [0: 0.5])
        volume.isSettable = false
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        #expect(harness.statuses == [MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .unsupportedDevice)])
        #expect(volume.unbinds == 1)
        await harness.speak(from: 0, windows: 12, dBFS: -40)
        #expect(harness.statuses.last == MicInputStatus(warning: .low, speechMonitoringUnavailable: false, adjustment: .unsupportedDevice))
        #expect(volume.writes.isEmpty)
    }

    @MainActor
    @Test("An unverified device mapping is an explicit failure, not a silent downgrade")
    func controllerIdentityFailure() {
        let volume = FakeVolume(values: [0: 0.5])
        volume.bindFailure = .deviceIdentityUnverified
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        #expect(harness.statuses == [MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .failed(.deviceIdentityUnverified))])
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
        #expect(harness.statuses.last == MicInputStatus(warning: .clipping, speechMonitoringUnavailable: false, adjustment: .pausedByExternalChange))
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
        #expect(harness.statuses.last == MicInputStatus(warning: nil, speechMonitoringUnavailable: false, adjustment: .failed(.noMovement)))
        await harness.raw(from: 1, windows: 20, clipped: 0.01)
        #expect(volume.writes.count == 1)
        #expect(harness.statuses.last == MicInputStatus(warning: .clipping, speechMonitoringUnavailable: false, adjustment: .failed(.noMovement)))
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
        #expect(harness.statuses.last == MicInputStatus(warning: nil, speechMonitoringUnavailable: true, adjustment: .active))
        await harness.speak(from: 0, windows: 20, dBFS: -40)
        #expect(volume.writes.isEmpty)
        await harness.raw(from: 6, windows: 1, clipped: 0.01)
        #expect(volume.writes.count == 1 && close(volume.writes.first, [(0, 0.4)]))
        await harness.raw(from: 7, windows: 20, clipped: 0.01)
        #expect(harness.statuses.last?.warning == .clipping)
        #expect(harness.statuses.last?.speechMonitoringUnavailable == true)
    }

    @MainActor
    @Test("A default-input change ends ownership: no later write and no restore at stop")
    func controllerDefaultInputChangeAbandonsOwnership() async {
        let volume = FakeVolume(values: [0: 0.5])
        let harness = Harness(volume: volume, pendingWriteTimeout: 1)
        await harness.raw(from: 0, windows: 1, clipped: 0.01)
        #expect(close(volume.values, [0: 0.4]))
        volume.changeDefaultInputDevice()
        #expect(harness.statuses.last?.adjustment == .pausedByDefaultDeviceChange)
        volume.manualChange(0, to: 0.4)
        #expect(harness.statuses.last?.adjustment == .pausedByDefaultDeviceChange)
        await harness.raw(from: 1, windows: 20, clipped: 0.01)
        await harness.controller.stop()
        #expect(volume.writes.count == 1)
        #expect(close(volume.values, [0: 0.4]))
        #expect(harness.statuses.last?.adjustment == .pausedByDefaultDeviceChange)
        #expect(volume.unbinds == 1)
    }
}
