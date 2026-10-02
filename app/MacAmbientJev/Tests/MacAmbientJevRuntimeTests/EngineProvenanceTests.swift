import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevRuntime

private struct ResolvedPin: Decodable {
    struct State: Decodable {
        let revision: String
        let version: String?
    }

    let identity: String
    let state: State
}

private struct ResolvedPackages: Decodable {
    let pins: [ResolvedPin]
}

private func resolvedPin(_ identity: String) throws -> ResolvedPin {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resolved = try JSONDecoder().decode(
        ResolvedPackages.self,
        from: Data(contentsOf: packageRoot.appending(path: "Package.resolved"))
    )
    return try #require(resolved.pins.first { $0.identity == identity })
}

@Test
func engineProvenanceNamesTheResolvedDependencyPins() throws {
    let fluidAudio = try #require(try resolvedPin("fluidaudio").state.version)
    let speechSwift = try resolvedPin("speech-swift").state.revision
    let paths = AppPaths(
        applicationSupportURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
        cacheURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    )

    #expect(NativeQwen3ASREngine(modelStore: ModelStore(paths: paths)).provenance.version
        == "speech-swift@\(speechSwift)")
    #expect(FluidOfflineDiarizationEngine(paths: paths).provenance.version == "FluidAudio@\(fluidAudio)")
    #expect(FluidFinalTranscriptVADSegmenter().provenance.version == "FluidAudio@\(fluidAudio)")
}
