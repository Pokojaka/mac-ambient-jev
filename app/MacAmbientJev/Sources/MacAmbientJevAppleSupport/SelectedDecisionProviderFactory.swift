import Foundation
import MacAmbientJevCore

public enum SelectedDecisionProviderAvailability: Sendable {
    case available(DecisionCoordinator)
    case unconfigured
    case stopped
}

/// Creates the configured decision provider without coupling routing to the runtime.
public final class SelectedDecisionProviderFactory: @unchecked Sendable {
    private let paths: AppPaths
    private let defaults: UserDefaults
    private let secretStore: any SecretStore
    private let usageCounter: DecisionUsageCounter
    private let loadLocalTagger: @Sendable (URL) throws -> LocalClauseTagger

    private let state = NSLock()
    private var cachedLocalTagger: Result<LocalClauseTagger, any Error>?
    private var pendingLoad: PendingLocalTaggerLoad?
    private var lastSelection: DecisionEngineChoice?

    public init(
        paths: AppPaths,
        defaults: UserDefaults,
        secretStore: any SecretStore,
        usageCounter: DecisionUsageCounter,
        loadLocalTagger: @escaping @Sendable (URL) throws -> LocalClauseTagger = {
            try LocalClauseTagger(modelDirectory: $0)
        }
    ) {
        self.paths = paths
        self.defaults = defaults
        self.secretStore = secretStore
        self.usageCounter = usageCounter
        self.loadLocalTagger = loadLocalTagger
    }

    public func makeCoordinator() throws -> SelectedDecisionProviderAvailability {
        let choice = try DecisionEnginePreference.load(defaults: defaults)
        observeSelection(choice)
        let isPaused = try DecisionEnginePreference.isPaused(defaults: defaults)
        guard !isPaused else {
            return .stopped
        }

        switch choice {
        case .jev:
            guard let apiKey = try secretStore.load(account: "jev-api-key")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !apiKey.isEmpty else {
                return .unconfigured
            }
            return .available(
                DecisionCoordinator(
                    provider: JevClient(
                        apiKey: apiKey,
                        transport: URLSessionJevHTTPTransport(session: .shared)
                    ),
                    identity: .jev,
                    usageCounter: usageCounter
                )
            )
        case .localModel:
            let tagger = try localTagger()
            return .available(
                DecisionCoordinator(
                    provider: tagger,
                    identity: tagger.identity.decisionIdentity,
                    usageCounter: usageCounter
                )
            )
        }
    }

    /// Validates the selected local model using the same cached load as the coordinator.
    /// This deliberately ignores the pause setting and does not access credentials or usage state.
    public func localModelIdentity() throws -> ClauseTaggerModelIdentity {
        let choice = try DecisionEnginePreference.load(defaults: defaults)
        observeSelection(choice)
        guard choice == .localModel else {
            throw SelectedDecisionProviderFactoryError.localModelNotSelected
        }
        return try localTagger().identity
    }

    /// Stores the engine choice and invalidates the local load only when the selection changes.
    /// Never waits for a model load.
    public func selectEngine(_ choice: DecisionEngineChoice) throws {
        state.lock()
        defer { state.unlock() }
        let persistedChoice = try DecisionEnginePreference.load(defaults: defaults)
        let preferenceChanged = persistedChoice != choice
        let observedSelectionChanged = lastSelection.map { $0 != choice } ?? false
        if preferenceChanged || observedSelectionChanged {
            invalidateLocalTaggerLocked()
        }
        defaults.set(choice.rawValue, forKey: DecisionEnginePreference.key)
        lastSelection = choice
    }

    private func observeSelection(_ choice: DecisionEngineChoice) {
        state.lock()
        defer { state.unlock() }
        if let lastSelection, lastSelection != choice {
            invalidateLocalTaggerLocked()
        }
        lastSelection = choice
    }

    private func invalidateLocalTaggerLocked() {
        cachedLocalTagger = nil
        pendingLoad = nil
    }

    /// Compiles and loads the model outside `state`, so selection changes never wait on it.
    /// Concurrent callers share one load, and its result stays cached until the selection changes.
    private func localTagger() throws -> LocalClauseTagger {
        state.lock()
        if let cachedLocalTagger {
            state.unlock()
            return try cachedLocalTagger.get()
        }
        if let pendingLoad {
            state.unlock()
            return try pendingLoad.wait().get()
        }
        let load = PendingLocalTaggerLoad()
        pendingLoad = load
        state.unlock()

        let result: Result<LocalClauseTagger, any Error>
        do {
            result = .success(try loadLocalTagger(LocalClauseTagger.modelDirectory(paths: paths)))
        } catch {
            result = .failure(error)
        }

        state.lock()
        if pendingLoad === load {
            pendingLoad = nil
            cachedLocalTagger = result
        }
        state.unlock()
        load.complete(result)
        return try result.get()
    }
}

private final class PendingLocalTaggerLoad: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<LocalClauseTagger, any Error>?

    func wait() -> Result<LocalClauseTagger, any Error> {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result { return result }
            condition.wait()
        }
    }

    func complete(_ result: Result<LocalClauseTagger, any Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }
}

private enum SelectedDecisionProviderFactoryError: LocalizedError {
    case localModelNotSelected

    var errorDescription: String? {
        "ローカルモデルが選択されていません。"
    }
}
