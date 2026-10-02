import Foundation
import MacAmbientJevCore

public struct MicInputVolumeElement: Sendable, Equatable {
    public let element: UInt32
    public let scalar: Float

    public init(element: UInt32, scalar: Float) {
        self.element = element
        self.scalar = scalar
    }
}

public struct MicInputVolumeSnapshot: Sendable, Equatable {
    public let deviceUID: String
    public let elements: [MicInputVolumeElement]
    public let isSettable: Bool

    public init(deviceUID: String, elements: [MicInputVolumeElement], isSettable: Bool) {
        self.deviceUID = deviceUID
        self.elements = elements
        self.isSettable = isSettable
    }
}

/// A failed write. `effective` is the readback after the failure (empty when unreadable);
/// `unresolved` names written elements whose change may still land later.
public struct MicInputVolumeWriteFailure: Error, Sendable, Equatable {
    public let reason: MicInputVolumeFailure
    public let effective: [MicInputVolumeElement]
    public let unresolved: [UInt32]

    public init(reason: MicInputVolumeFailure, effective: [MicInputVolumeElement], unresolved: [UInt32]) {
        self.reason = reason
        self.effective = effective
        self.unresolved = unresolved
    }
}

@MainActor
public protocol MicInputVolumeControlling: AnyObject {
    func bind(captureDeviceUID: String,
              onExternalChange: @escaping @MainActor @Sendable () -> Void) throws(MicInputVolumeFailure)
        -> MicInputVolumeSnapshot
    func snapshot() throws(MicInputVolumeFailure) -> MicInputVolumeSnapshot
    func setVolumes(_ values: [MicInputVolumeElement],
                    expected: MicInputVolumeSnapshot) async throws(MicInputVolumeWriteFailure)
        -> MicInputVolumeSnapshot
    func unbind() throws(MicInputVolumeFailure)
}

/// One recording's ownership of the system input volume. Decisions come from MicGainPolicy;
/// restoration touches only elements whose current value is still the app's last effective write.
@MainActor
final class MicInputVolumeController {
    static let ownershipTolerance: Float = 0.001

    private struct PendingWrite {
        let token: UInt64
        let elements: Set<UInt32>
    }

    let sessionID: UUID
    private let volume: (any MicInputVolumeControlling)?
    private let now: @MainActor () -> Double
    private let onStatus: @MainActor @Sendable (UUID, MicInputStatus) -> Void
    private let onEffectiveChange: @MainActor () -> Void
    private let pendingWriteTimeout: TimeInterval
    private var policy = MicGainPolicy()
    private var adjustment: MicInputAdjustment
    private var active = true
    private var bound = false
    private var monitoringUnavailable = false
    private var policyWarning: MicInputWarning?
    private var lastStatus: MicInputStatus?
    private var current: MicInputVolumeSnapshot?
    private var originals: [UInt32: Float] = [:]
    private var owned: [UInt32: Float] = [:]
    private var relinquished: Set<UInt32> = []
    private var unresolved: Set<UInt32> = []
    private var pending: PendingWrite?
    private var nextToken: UInt64 = 0
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    /// `volume` is nil exactly when automatic adjustment is disabled for this recording.
    init(
        sessionID: UUID, volume: (any MicInputVolumeControlling)?,
        pendingWriteTimeout: TimeInterval,
        now: @escaping @MainActor () -> Double,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void,
        onEffectiveChange: @escaping @MainActor () -> Void
    ) {
        self.sessionID = sessionID
        self.volume = volume
        self.pendingWriteTimeout = pendingWriteTimeout
        self.now = now
        self.onStatus = onStatus
        self.onEffectiveChange = onEffectiveChange
        adjustment = volume == nil ? .disabledBySetting : .active
    }

    var status: MicInputStatus {
        MicInputStatus(
            warning: policyWarning ?? (monitoringUnavailable ? .monitoringUnavailable : nil),
            adjustment: adjustment
        )
    }

    /// Reads the bound device's controls; never writes.
    func bind(captureDeviceUID: String) {
        defer { publishStatus() }
        guard let volume else { return }
        let snapshot: MicInputVolumeSnapshot
        do throws(MicInputVolumeFailure) {
            snapshot = try volume.bind(captureDeviceUID: captureDeviceUID) { [weak self] in
                self?.externalChange()
            }
        } catch {
            adjustment = .failed(error)
            return
        }
        bound = true
        guard snapshot.deviceUID == captureDeviceUID else {
            adjustment = .failed(.deviceIdentityUnverified)
            release(volume)
            return
        }
        guard snapshot.isSettable, !snapshot.elements.isEmpty else {
            adjustment = .unsupportedDevice
            release(volume)
            return
        }
        current = snapshot
        originals = Dictionary(uniqueKeysWithValues: snapshot.elements.map { ($0.element, $0.scalar) })
    }

    func consumeSpeech(_ windows: [MicLevelWindow]) {
        guard !monitoringUnavailable else { return }
        for window in windows { observe(window) }
    }

    func consumeRaw(_ windows: [MicLevelWindow]) {
        for window in windows { observe(window) }
    }

    func speechMonitoringUnavailable() {
        guard active else { return }
        monitoringUnavailable = true
        publishStatus()
    }

    private func observe(_ window: MicLevelWindow) {
        // Windows during a write predate its settling interval and are discarded after it.
        guard active, pending == nil else { return }
        let canAdjust = adjustment == .active
        let decision = policy.observe(
            window, currentScalars: canAdjust ? current!.elements.map(\.scalar) : [],
            canAdjust: canAdjust, nowSeconds: now()
        )
        policyWarning = decision.warning
        if canAdjust, let delta = decision.volumeDelta { write(delta: delta) }
        publishStatus()
    }

    private func write(delta: Float) {
        guard let volume, let expected = current else {
            preconditionFailure("An active adjustment always has a bound control snapshot")
        }
        let targets = expected.elements.map {
            MicInputVolumeElement(element: $0.element, scalar: min(1, max(0, $0.scalar + delta)))
        }
        let changed = Set(zip(expected.elements, targets)
            .filter { abs($0.scalar - $1.scalar) > Self.ownershipTolerance }.map(\.0.element))
        guard !changed.isEmpty else { return }
        nextToken += 1
        let token = nextToken
        pending = PendingWrite(token: token, elements: changed)
        Task { [weak self] in
            let result: Result<MicInputVolumeSnapshot, MicInputVolumeWriteFailure>
            do throws(MicInputVolumeWriteFailure) {
                result = .success(try await volume.setVolumes(targets, expected: expected))
            } catch {
                result = .failure(error)
            }
            self?.finishWrite(token: token, expected: expected, targets: targets, result: result)
        }
    }

    private func finishWrite(
        token: UInt64, expected: MicInputVolumeSnapshot, targets: [MicInputVolumeElement],
        result: Result<MicInputVolumeSnapshot, MicInputVolumeWriteFailure>
    ) {
        guard pending?.token == token else { return }
        pending = nil
        defer { resumeWaiters() }
        let target = Dictionary(uniqueKeysWithValues: targets.map { ($0.element, $0.scalar) })
        let effective: [MicInputVolumeElement]
        switch result {
        case .success(let snapshot):
            guard snapshot.deviceUID == expected.deviceUID,
                  snapshot.elements.map(\.element) == expected.elements.map(\.element) else {
                unresolved.formUnion(expected.elements.map(\.element))
                fail(.deviceIdentityUnverified)
                return
            }
            effective = snapshot.elements
        case .failure(let failure):
            effective = failure.effective
            unresolved.formUnion(failure.unresolved)
        }
        var moved = false
        var unexpected = false
        for element in effective {
            guard let before = expected.elements.first(where: { $0.element == element.element })?.scalar,
                  let wanted = target[element.element] else { continue }
            let change = element.scalar - before
            guard abs(change) > Self.ownershipTolerance else { continue }
            if (change > 0) == (wanted > before), !relinquished.contains(element.element) {
                owned[element.element] = element.scalar
                moved = true
            } else {
                relinquished.insert(element.element)
                owned.removeValue(forKey: element.element)
                unexpected = true
            }
        }
        if !effective.isEmpty {
            current = MicInputVolumeSnapshot(
                deviceUID: expected.deviceUID, elements: effective, isSettable: expected.isSettable
            )
        }
        if case .failure(let failure) = result {
            fail(failure.reason)
            return
        }
        guard moved, !unexpected else {
            fail(moved ? .unexpectedMovement : .noMovement)
            return
        }
        guard active else { return }
        policy.didApplyVolumeChange(atSeconds: now())
        onEffectiveChange()
        publishStatus()
    }

    private func fail(_ failure: MicInputVolumeFailure) {
        if case .failed = adjustment { return }
        adjustment = .failed(failure)
        publishStatus()
    }

    private func externalChange() {
        guard bound, let volume else { return }
        adjustment = .pausedByExternalChange
        do throws(MicInputVolumeFailure) {
            let snapshot = try volume.snapshot()
            for element in snapshot.elements {
                if let value = owned[element.element],
                   abs(value - element.scalar) > Self.ownershipTolerance {
                    owned.removeValue(forKey: element.element)
                    relinquished.insert(element.element)
                }
            }
        } catch {
            relinquished.formUnion(owned.keys)
            owned.removeAll()
            adjustment = .failed(error)
        }
        publishStatus()
    }

    /// Stops decisions, settles any in-flight write, then restores app-owned controls.
    func stop() async {
        active = false
        await quiescePending()
        guard let volume, bound else { return }
        if !unresolved.isEmpty { reportStop(.restoreFailed(.writeUnresolved)) }
        await restoreOwned(volume)
        release(volume)
    }

    private func restoreOwned(_ volume: any MicInputVolumeControlling) async {
        let restorable = owned.filter { !unresolved.contains($0.key) && !relinquished.contains($0.key) }
        guard !restorable.isEmpty else { return }
        let snapshot: MicInputVolumeSnapshot
        do throws(MicInputVolumeFailure) {
            snapshot = try volume.snapshot()
        } catch {
            reportStop(.restoreFailed(error))
            return
        }
        let targets = snapshot.elements.compactMap { element -> MicInputVolumeElement? in
            guard let ownedValue = restorable[element.element],
                  abs(ownedValue - element.scalar) <= Self.ownershipTolerance,
                  let original = originals[element.element],
                  abs(original - element.scalar) > Self.ownershipTolerance else { return nil }
            return MicInputVolumeElement(element: element.element, scalar: original)
        }
        guard !targets.isEmpty else { return }
        do throws(MicInputVolumeWriteFailure) {
            _ = try await volume.setVolumes(targets, expected: snapshot)
            owned.removeAll()
        } catch {
            reportStop(.restoreFailed(error.reason))
        }
    }

    /// Orderly termination cannot await a confirmed restore; it relinquishes ownership only.
    func terminate() {
        active = false
        if let pending {
            unresolved.formUnion(pending.elements)
            self.pending = nil
            resumeWaiters()
        }
        guard let volume, bound else { return }
        release(volume)
    }

    private func release(_ volume: any MicInputVolumeControlling) {
        guard bound else { return }
        bound = false
        do throws(MicInputVolumeFailure) {
            try volume.unbind()
        } catch {
            reportStop(.failed(error))
        }
    }

    private func quiescePending() async {
        guard let pending else { return }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + pendingWriteTimeout) { [weak self] in
                MainActor.assumeIsolated { self?.abandonPending(token: pending.token) }
            }
        }
    }

    private func abandonPending(token: UInt64) {
        guard let pending, pending.token == token else { return }
        unresolved.formUnion(pending.elements)
        self.pending = nil
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = pendingWaiters
        pendingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func publishStatus() {
        guard active else { return }
        emit(status)
    }

    /// Stop-time outcomes are reported even though decisions have ended.
    private func reportStop(_ adjustment: MicInputAdjustment) {
        self.adjustment = adjustment
        emit(status)
    }

    private func emit(_ status: MicInputStatus) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus(sessionID, status)
    }
}
