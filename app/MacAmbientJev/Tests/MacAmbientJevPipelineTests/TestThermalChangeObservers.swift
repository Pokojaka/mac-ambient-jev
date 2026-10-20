import Foundation
import Synchronization
import MacAmbientJevPipeline

final class TestThermalChangeObservers: Sendable {
    private let callbacks: Mutex<[UUID: @MainActor @Sendable () -> Void]> = Mutex([:])

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        let id = UUID()
        callbacks.withLock { $0[id] = onChange }
        return TestThermalChangeObservation { [weak self] in
            self?.callbacks.withLock { $0.removeValue(forKey: id) }
        }
    }

    @MainActor
    func notify() {
        let registeredCallbacks = callbacks.withLock { Array($0.values) }
        // Invoke outside the lock so callbacks can cancel their observations safely.
        registeredCallbacks.forEach { $0() }
    }
}

private final class TestThermalChangeObservation: ThermalStateObservation {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit {
        cancel()
    }
}
