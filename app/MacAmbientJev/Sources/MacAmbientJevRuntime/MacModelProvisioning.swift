import MacAmbientJevCore
import MacAmbientJevPipeline

/// Connects `ModelPreparer` to the pinned Mac model files and the network.
public struct MacModelProvisioning: ModelProvisioning {
    private let store: MacModelStore
    private let transport: any ModelDownloadTransport

    public init(store: MacModelStore, transport: any ModelDownloadTransport) {
        self.store = store
        self.transport = transport
    }

    public func byteCount(_ model: MacModel) -> Int64 {
        store.entry(model).files.reduce(0) { $0 + $1.byteCount }
    }

    public func isFetched(_ model: MacModel) -> Bool { store.isFetched(model) }

    public func fetch(
        _ model: MacModel, progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        try await store.fetch(model, transport: transport, progress: progress)
    }

    public func verify(_ model: MacModel) async throws {
        _ = try await store.verifiedDirectory(model)
    }
}
