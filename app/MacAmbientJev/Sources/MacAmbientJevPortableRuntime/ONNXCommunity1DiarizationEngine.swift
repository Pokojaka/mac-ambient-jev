import Foundation
import MacAmbientJevCore
import MacAmbientJevDiarization
import MacAmbientJevONNX

enum ONNXCommunity1DiarizationEngineError: Error, LocalizedError, Equatable {
    case notPrepared

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "ONNX Community-1 diarization engine is not prepared. Call prepare() first."
        }
    }
}

/// One prepared run of the fixed Community-1 kernel over a bounded sample reader.
final class Community1DiarizationKernel {
    typealias Run = (_ sampleCount: Int64, _ readFrames: (Range<Int64>) throws -> [Float]) throws -> [SpeakerSpan]

    let run: Run

    init(run: @escaping Run) {
        self.run = run
    }
}

/// The Linux and Windows diarization engine: the portable Community-1 kernel over ONNX Runtime.
///
/// The actor owns the sessions. The synchronous bodies of `prepare` and `diarize` run on dedicated
/// threads while retaining actor isolation. Neither body suspends internally, so kernel runs remain
/// serialized and `unload` waits for a running kernel. Every `diarize` call builds its own evidence,
/// so a second call never sees the first call's speakers.
public actor ONNXCommunity1DiarizationEngine: DiarizationEngine {
    private nonisolated let provenanceValue: RunProvenance
    private let modelDirectory: URL
    private let loadKernel: @Sendable (URL) throws -> Community1DiarizationKernel
    private var kernel: Community1DiarizationKernel?

    var isPrepared: Bool { kernel != nil }

    public nonisolated var provenance: RunProvenance {
        provenanceValue
    }

    /// `modelDirectory` holds the four pinned files that `scripts/fetch_community1_diarization.py` downloads.
    public init(modelDirectory: URL, intraOpThreads: Int) throws {
        let identity = try Community1Assets.pinnedIdentity()
        self.modelDirectory = modelDirectory
        self.provenanceValue = Self.makeProvenance(identity: identity, intraOpThreads: intraOpThreads)
        self.loadKernel = { directory in
            let assets = try Community1Assets(modelDirectory: directory)
            let environment = try ONNXEnvironment.shared()
            let inference = try Community1ONNXInference(
                environment: environment,
                assets: assets,
                intraOpThreads: intraOpThreads
            )
            let diarizer = assets.diarizer
            return Community1DiarizationKernel { sampleCount, readFrames in
                try diarizer.diarize(sampleCount: sampleCount, readFrames: readFrames, inference: inference)
            }
        }
    }

    init(
        modelDirectory: URL,
        provenance: RunProvenance,
        loadKernel: @escaping @Sendable (URL) throws -> Community1DiarizationKernel
    ) {
        self.modelDirectory = modelDirectory
        self.provenanceValue = provenance
        self.loadKernel = loadKernel
    }

    public func prepare() async throws {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            try prepareSynchronously()
        }
    }

    private func prepareSynchronously() throws {
        if kernel != nil { return }
        kernel = try loadKernel(modelDirectory)
    }

    public func diarize(
        fileURL: URL,
        canonicalSampleRate: Double,
        sessionURL: URL
    ) async throws -> [SpeakerSpan] {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            try diarizeSynchronously(
                fileURL: fileURL,
                canonicalSampleRate: canonicalSampleRate,
                sessionURL: sessionURL
            )
        }
    }

    private func diarizeSynchronously(
        fileURL: URL,
        canonicalSampleRate: Double,
        sessionURL: URL
    ) throws -> [SpeakerSpan] {
        guard canonicalSampleRate == CanonicalAudio.sampleRate else {
            throw CanonicalAudioError.noncanonicalFormat
        }
        guard let kernel else {
            throw ONNXCommunity1DiarizationEngineError.notPrepared
        }
        let reader = try CanonicalCAFReader(url: fileURL, sessionURL: sessionURL)
        return try kernel.run(reader.sampleCount) { range in
            try reader.readSamples(frames: range)
        }
    }

    public func unload() async {
        kernel = nil
    }

    private nonisolated static func makeProvenance(
        identity: Community1ModelIdentity,
        intraOpThreads: Int
    ) -> RunProvenance {
        var configuration: [String: String] = [
            "profile": "FluidAudio 0.15.8 OfflineDiarizerConfig.default",
            "embedding.min_segment_duration_seconds": "0.3",
            "embedding_graph": "wespeaker-multimask-tail",
            "intra_op_threads": String(intraOpThreads),
            "inter_op_threads": String(ONNXSession.interOpThreads),
            "cpu_memory_arena": String(Community1ONNXInference.cpuMemoryArenaEnabled),
        ]
        for (name, sha256) in identity.fileSHA256 {
            configuration["sha256.\(name)"] = sha256
        }
        return RunProvenance(
            engine: "onnxruntime-community1-diarizer",
            model: identity.model,
            version: "onnxruntime-\(ONNXEnvironment.runtimeVersion)",
            configuration: configuration
        )
    }
}
