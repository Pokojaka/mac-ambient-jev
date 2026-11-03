import Foundation
import Synchronization
import MacAmbientJevCore
import MacAmbientJevPipeline

private typealias ResourceChangeCallback = @MainActor @Sendable () -> Void

public final class WindowsInferenceResourceMonitor: InferenceResourceMonitoring, InferenceMemoryProbing, Sendable {
    private struct State: Sendable {
        var low: UInt?
        var high: UInt?
        var signal: InferenceResourceSignal = .monitorFailed("Resource monitor initialization incomplete")
        var slow = 0
        var stopped = false
        var healthySince: Double?
        var observers: [UUID: ResourceChangeCallback] = [:]
    }

    private let calls: WindowsResourceMonitorCalls
    private let state = Mutex(State())

    public convenience init() {
        self.init(calls: .live, startWorker: true)
    }

    internal init(calls: WindowsResourceMonitorCalls, startWorker: Bool) {
        self.calls = calls
        var low: UInt?
        var high: UInt?
        do {
            let lowHandle = try calls.create(true)
            low = lowHandle
            let highHandle = try calls.create(false)
            high = highHandle
            state.withLock { value in
                value.low = lowHandle
                value.high = highHandle
            }
            let sampled = try sample(low: lowHandle, high: highHandle)
            let adequate = try inferenceMemoryHeadroomIsAdequate(
                physicalMemoryBytes: sampled.facts.physicalMemoryBytes,
                freePhysicalMemoryBytes: sampled.facts.freePhysicalMemoryBytes,
                commitHeadroomBytes: sampled.facts.commitHeadroomBytes
            )
            state.withLock { value in
                value.signal = sampled.lowSignal || !adequate ? .pressure : .healthy
            }
        } catch {
            let messages = [Self.diagnostic(error)] + closeHandles(low, high)
            state.withLock { value in
                value.low = nil
                value.high = nil
                value.signal = .monitorFailed(messages.joined(separator: "; "))
            }
        }

        if startWorker, state.withLock({ Self.failure($0.signal) == nil }) {
            Thread.detachNewThread { [weak self] in
                while let snapshot = self.map({ $0.workerSnapshot() }), snapshot.1 {
                    let deadline = snapshot.0.now() + 0.250
                    snapshot.0.sleep(0.250)
                    guard let running = self.map({ $0.probe(deadline: deadline) }), running else {
                        return
                    }
                }
            }
        }
    }

    deinit {
        stop()
    }

    public var signal: InferenceResourceSignal {
        state.withLock { $0.signal }
    }

    public func stop() {
        let changed = state.withLock { value -> [UUID] in
            guard !value.stopped else {
                return []
            }
            value.stopped = true
            var errors: [String] = []
            for handle in [value.low, value.high].compactMap({ $0 }) {
                do {
                    try calls.close(handle)
                } catch {
                    errors.append(Self.diagnostic(error))
                }
            }
            value.low = nil
            value.high = nil
            if !errors.isEmpty {
                let messages = (Self.failure(value.signal).map { [$0] } ?? []) + errors
                return Self.change(.monitorFailed(messages.joined(separator: "; ")), &value)
            }
            return Self.failure(value.signal) == nil
                ? Self.change(.monitorFailed("Resource monitor stopped"), &value)
                : []
        }
        notify(changed)
    }

    public func memoryFacts() throws -> InferenceMemoryFacts {
        var changed: [UUID] = []
        let result = state.withLock { value -> Result<InferenceMemoryFacts, WindowsResourceMonitorError> in
            guard !value.stopped, Self.failure(value.signal) == nil else {
                return .failure(.init(diagnostic: Self.failure(value.signal) ?? "Resource monitor stopped"))
            }
            do {
                guard let low = value.low, let high = value.high else {
                    throw Self.error("Resource monitor handles unavailable")
                }
                let sampled = try sample(low: low, high: high)
                let adequate = try inferenceMemoryHeadroomIsAdequate(
                    physicalMemoryBytes: sampled.facts.physicalMemoryBytes,
                    freePhysicalMemoryBytes: sampled.facts.freePhysicalMemoryBytes,
                    commitHeadroomBytes: sampled.facts.commitHeadroomBytes
                )
                if sampled.lowSignal || !adequate {
                    value.healthySince = nil
                    changed = Self.change(.pressure, &value)
                }
                return .success(sampled.facts)
            } catch {
                let message = Self.diagnostic(error)
                changed = Self.change(.monitorFailed(message), &value)
                return .failure(.init(diagnostic: message))
            }
        }
        notify(changed)
        return try result.get()
    }

    @discardableResult
    internal func probe(deadline: Double) -> Bool {
        var changed: [UUID] = []
        let running = state.withLock { value -> Bool in
            guard !value.stopped, Self.failure(value.signal) == nil else {
                return false
            }
            do {
                let now = calls.now()
                guard now.isFinite, deadline.isFinite else {
                    throw Self.error("Monotonic resource-monitor clock returned a non-finite time")
                }
                let delay = max(0, now - deadline)
                value.slow = delay > 0.500 ? min(3, value.slow + 1) : 0
                guard let low = value.low, let high = value.high else {
                    throw Self.error("Resource monitor handles unavailable")
                }
                let sampled = try sample(low: low, high: high)
                let adequate = try inferenceMemoryHeadroomIsAdequate(
                    physicalMemoryBytes: sampled.facts.physicalMemoryBytes,
                    freePhysicalMemoryBytes: sampled.facts.freePhysicalMemoryBytes,
                    commitHeadroomBytes: sampled.facts.commitHeadroomBytes
                )
                guard !sampled.lowSignal, adequate, value.slow < 3 else {
                    value.healthySince = nil
                    changed = Self.change(.pressure, &value)
                    return true
                }
                if value.signal == .pressure {
                    guard sampled.highSignal, delay < 0.100 else {
                        value.healthySince = nil
                        return true
                    }
                    if let since = value.healthySince {
                        guard now >= since else {
                            throw Self.error("Monotonic resource-monitor clock moved backwards")
                        }
                        if now - since >= 10 {
                            value.healthySince = nil
                            changed = Self.change(.healthy, &value)
                        }
                    } else {
                        value.healthySince = now
                    }
                } else {
                    changed = Self.change(.healthy, &value)
                }
                return true
            } catch {
                value.healthySince = nil
                changed = Self.change(.monitorFailed(Self.diagnostic(error)), &value)
                return false
            }
        }
        notify(changed)
        return running
    }

    @MainActor
    public func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any InferenceResourceObservation {
        let id = UUID()
        state.withLock { $0.observers[id] = onChange }
        return WindowsResourceObservationToken { [weak self] in
            self?.removeObserver(id)
        }
    }

    private func sample(
        low: UInt,
        high: UInt
    ) throws -> (lowSignal: Bool, highSignal: Bool, facts: InferenceMemoryFacts) {
        let lowSignal = try calls.query(low)
        let highSignal = try calls.query(high)
        let raw = try calls.memory()
        return (
            lowSignal: lowSignal,
            highSignal: highSignal,
            facts: InferenceMemoryFacts(
                physicalMemoryBytes: raw.physicalMemoryBytes,
                freePhysicalMemoryBytes: raw.freePhysicalMemoryBytes,
                commitHeadroomBytes: raw.commitHeadroomBytes,
                lowMemorySignal: lowSignal
            )
        )
    }

    private func closeHandles(_ low: UInt?, _ high: UInt?) -> [String] {
        var errors: [String] = []
        for handle in [low, high].compactMap({ $0 }) {
            do {
                try calls.close(handle)
            } catch {
                errors.append(Self.diagnostic(error))
            }
        }
        return errors
    }

    private func workerSnapshot() -> (WindowsResourceMonitorCalls, Bool) {
        (
            calls,
            state.withLock { !$0.stopped && Self.failure($0.signal) == nil }
        )
    }

    private func removeObserver(_ id: UUID) {
        _ = state.withLock { $0.observers.removeValue(forKey: id) }
    }

    private func notify(_ ids: [UUID]) {
        guard !ids.isEmpty else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let callbacks = state.withLock { value in
                ids.compactMap { value.observers[$0] }
            }
            for callback in callbacks {
                callback()
            }
        }
    }

    private static func change(_ signal: InferenceResourceSignal, _ state: inout State) -> [UUID] {
        guard state.signal != signal else {
            return []
        }
        state.signal = signal
        return Array(state.observers.keys)
    }

    private static func failure(_ signal: InferenceResourceSignal) -> String? {
        guard case .monitorFailed(let message) = signal else {
            return nil
        }
        return message
    }

    private static func error(_ message: String) -> WindowsResourceMonitorError {
        .init(diagnostic: message)
    }

    private static func diagnostic(_ error: Error) -> String {
        (error as? WindowsResourceMonitorError)?.diagnostic ?? String(describing: error)
    }
}

private final class WindowsResourceObservationToken: InferenceResourceObservation {
    private let remove: @Sendable () -> Void

    init(remove: @escaping @Sendable () -> Void) {
        self.remove = remove
    }

    deinit {
        remove()
    }
}
