import Foundation
import Synchronization
import MacAmbientJevPipeline

final class TestInferenceResourceMonitor: InferenceResourceMonitoring, Sendable {
    private let signalStorage: Mutex<InferenceResourceSignal>
    private let callbacks: Mutex<[UUID: @MainActor @Sendable () -> Void]> = Mutex([:])

    init(_ signal: InferenceResourceSignal) { signalStorage = Mutex(signal) }

    var signal: InferenceResourceSignal { signalStorage.withLock { $0 } }

    @MainActor
    func setSignal(_ signal: InferenceResourceSignal) {
        signalStorage.withLock { $0 = signal }
        let registeredCallbacks = callbacks.withLock { Array($0.values) }
        registeredCallbacks.forEach { $0() }
    }

    @MainActor
    func observeChanges(
        _ onChange: @escaping @MainActor @Sendable () -> Void
    ) -> any InferenceResourceObservation {
        let id = UUID()
        callbacks.withLock { $0[id] = onChange }
        return TestInferenceResourceObservation { [weak self] in
            _ = self?.callbacks.withLock { $0.removeValue(forKey: id) }
        }
    }
}

private final class TestInferenceResourceObservation: InferenceResourceObservation {
    private let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
