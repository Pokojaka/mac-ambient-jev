import MacAmbientJevCore
import MacAmbientJevPipeline

/// Models that are already on disk and valid, so a preparation only loads the fake ASR engine.
struct ReadyModelProvisioning: ModelProvisioning {
    func byteCount(_ model: MacModel) -> Int64 { 1 }
    func isFetched(_ model: MacModel) -> Bool { true }
    func fetch(_ model: MacModel, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {}
    func verify(_ model: MacModel) async throws {}
}
