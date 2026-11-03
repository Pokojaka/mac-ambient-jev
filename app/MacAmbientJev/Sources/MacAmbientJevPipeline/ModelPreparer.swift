import Foundation
import MacAmbientJevCore

/// How the preparer reaches the three model directories. The Mac app implements it over its
/// model store; tests use stand-ins.
public protocol ModelProvisioning: Sendable {
    func byteCount(_ model: MacModel) -> Int64
    /// A cheap check: every manifest file exists with its byte count. It does not hash.
    func isFetched(_ model: MacModel) -> Bool
    func fetch(_ model: MacModel, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
    /// Hashes the files against the manifest.
    func verify(_ model: MacModel) async throws
}

/// Owns fetching, verifying and loading all three models. One run at a time; callers that arrive
/// while a run is going join it.
///
/// A run fetches the models that are not on disk, smallest first and one at a time, and only then
/// verifies each model and loads the ASR model. A failure stops the run and is kept in `status`.
/// After a failure only `retry` starts a run again, so queued work and new recordings never loop.
@MainActor
public final class ModelPreparer {
    public private(set) var status = ModelPreparationStatus.initial {
        didSet { if status != oldValue { onChange?(status) } }
    }
    public var onChange: (@MainActor (ModelPreparationStatus) -> Void)?
    public private(set) var runTask: Task<Void, Never>?

    private let provisioning: any ModelProvisioning
    private let asr: any ASREngine
    private var failedSinceRetry = false
    private var refetch = Set<MacModel>()

    public init(provisioning: any ModelProvisioning, asr: any ASREngine) {
        self.provisioning = provisioning
        self.asr = asr
    }

    public var isRunning: Bool { runTask != nil }

    /// The automatic trigger: recording start and queued finalization. It starts a run only when
    /// none is running, the models are not ready, and no run has failed since the last `retry`.
    public func ensurePrepared(after earlierRelease: Task<Void, Never>?) {
        guard !failedSinceRetry else { return }
        start(after: earlierRelease)
    }

    /// The user's trigger: clears the failure and starts a run.
    public func retry(after earlierRelease: Task<Void, Never>?) {
        failedSinceRetry = false
        start(after: earlierRelease)
    }

    /// The ASR model was unloaded, so the next run loads it again. A failure stays visible.
    public func didUnload() {
        if status.phase == .ready { status = .initial }
    }

    private func start(after earlierRelease: Task<Void, Never>?) {
        guard runTask == nil, status.phase != .ready else { return }
        let order = MacModel.allCases.sorted { provisioning.byteCount($0) < provisioning.byteCount($1) }
        let toFetch = order.filter { refetch.contains($0) || !provisioning.isFetched($0) }
        var next = ModelPreparationStatus.initial
        for model in toFetch { next.models[model] = .downloading }
        if toFetch.isEmpty {
            for model in order { next.models[model] = .verifying }
        }
        next.bytesTotal = toFetch.reduce(0) { $0 + provisioning.byteCount($1) }
        status = next
        runTask = Task { [weak self] in
            await earlierRelease?.value
            await self?.run(order: order, toFetch: toFetch)
        }
    }

    private func run(order: [MacModel], toFetch: [MacModel]) async {
        var current = toFetch.first ?? order[0]
        do {
            var done: Int64 = 0
            for model in toFetch {
                current = model
                let base = done
                try await provisioning.fetch(model) { [weak self] progress in
                    Task { @MainActor in self?.recordProgress(base + progress.bytesDone) }
                }
                done += provisioning.byteCount(model)
                refetch.remove(model)
                status.bytesDone = max(status.bytesDone, done)
                status.models[model] = .idle
            }
            for model in order {
                current = model
                status.models[model] = .verifying
                if model == .asr {
                    try await asr.prepare()
                } else {
                    try await provisioning.verify(model)
                }
                status.models[model] = .ready
            }
            runTask = nil
        } catch {
            runTask = nil
            if Task.isCancelled || error is CancellationError {
                status = .initial
                return
            }
            failedSinceRetry = true
            refetch.insert(current)
            var failed = status
            for model in order where failed.state(model) != .ready { failed.models[model] = .idle }
            failed.models[current] = .failed(Self.reason(error, model: current))
            status = failed
        }
    }

    private func recordProgress(_ done: Int64) {
        guard status.phase == .downloading, done > status.bytesDone else { return }
        status.bytesDone = done
    }

    private static func reason(_ error: Error, model: MacModel) -> String {
        let text = error.localizedDescription
        return text.contains(model.displayName) ? text : "\(model.displayName): \(text)"
    }
}
