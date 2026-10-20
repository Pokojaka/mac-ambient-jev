import Foundation
import Synchronization
import MacAmbientJevCore
import MacAmbientJevPipeline

final class TestThermalMonitor: ThermalMonitoring {
    private struct State: Sendable {
        var pressure: ThermalPressure
        var observers: [UUID: @MainActor @Sendable () -> Void] = [:]
    }

    private let storage: Mutex<State>

    init(_ pressure: ThermalPressure) {
        storage = Mutex(State(pressure: pressure))
    }

    @MainActor
    var pressure: ThermalPressure {
        get { storage.withLock { $0.pressure } }
        set {
            let callbacks = storage.withLock { state -> [@MainActor @Sendable () -> Void] in
                guard state.pressure != newValue else { return [] }
                state.pressure = newValue
                return Array(state.observers.values)
            }
            callbacks.forEach { $0() }
        }
    }

    var isCritical: Bool { storage.withLock { $0.pressure == .critical } }

    var liveASRDecision: LiveASRThermalDecision {
        LiveASRThermalPolicy.decision(pressure: storage.withLock { $0.pressure })
    }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any ThermalStateObservation {
        let id = UUID()
        storage.withLock { $0.observers[id] = onChange }
        return TestThermalStateObservation { [weak self] in
            self?.storage.withLock { $0.observers.removeValue(forKey: id) }
        }
    }
}

private final class TestThermalStateObservation: ThermalStateObservation {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit {
        cancel()
    }
}
