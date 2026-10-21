// Orchestration pinned to FluidAudio 0.15.8, revision 87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc:
// OfflineDiarizerManager.swift `cluster(_:)` (:335-460) and `clusterAssignments` (:658-700).
import Foundation
import MacAmbientJevCore

public enum Community1Error: Error, CustomStringConvertible {
    /// No samples, or no slot of any window passed the mask gates (FluidAudio `noSpeechDetected`).
    case noSpeechDetected
    /// Embeddings were extracted but every one is nonfinite, so no cluster can be trained.
    case noFiniteTrainingEmbeddings
    /// The inference implementation returned something that does not match its contract.
    case invalidModelOutput(stage: String, reason: String)
    /// A reconstructed span lies outside the audio and its final-window padding.
    case invalidSpeakerSpan(speakerID: String, startFrame: Int64, endFrame: Int64, totalFrames: Int64)

    public var description: String {
        switch self {
        case .noSpeechDetected:
            return "Community-1 diarization found no speech"
        case .noFiniteTrainingEmbeddings:
            return "Community-1 diarization extracted embeddings but none is finite"
        case let .invalidModelOutput(stage, reason):
            return "Community-1 \(stage) returned invalid output: \(reason)"
        case let .invalidSpeakerSpan(speakerID, startFrame, endFrame, totalFrames):
            return "Community-1 produced span \(speakerID) [\(startFrame), \(endFrame)) outside \(totalFrames) frames"
        }
    }
}

/// The mask of one speaker slot in both forms an embedding model can consume.
public struct SpeakerMask: Sendable {
    /// Cleaned activity at segmentation resolution; a graph that resamples internally takes this.
    public let activity: ActivityMask
    /// The same activity pre-sampled at the pooling positions, for a graph that does not resample.
    public let pooling: PoolingMask

    init(activity: ActivityMask) {
        self.activity = activity
        pooling = Community1Frontend.poolingMask(activity)
    }
}

/// The two model operations the kernel needs. Implementations own tensors, sessions and I/O names.
public protocol Community1Inference {
    /// Powerset log-probabilities for one zero-padded 10 s window.
    func segment(_ window: WindowAudio) throws -> PowersetScores

    /// One raw 256-dimensional vector per supplied mask, in the order of `masks`.
    /// The kernel applies the host L2 normalization with the profile floor.
    func embed(features: Community1FbankFeatures, masks: [SpeakerMask]) throws -> [[Float]]
}

/// The fixed Community-1 offline diarizer: windows, masks, embeddings, global clustering,
/// constrained assignment and reconstruction. Every `diarize` call owns its evidence.
public struct Community1Diarizer: Sendable {
    private let plda: Community1PLDA

    init(plda: Community1PLDA) {
        self.plda = plda
    }

    /// Diarizes `sampleCount` canonical 16 kHz samples and returns spans in ascending
    /// `(startFrame, endFrame)` order, clamped to the final window's padding.
    public func diarize(
        sampleCount: Int64,
        readFrames: (Range<Int64>) throws -> [Float],
        inference: any Community1Inference
    ) throws -> [SpeakerSpan] {
        let plan = try Community1WindowPlan(sampleCount: sampleCount)
        guard plan.count > 0 else { throw Community1Error.noSpeechDetected }

        var table = Community1ObservationTable()
        for index in 0..<plan.count {
            let window = try plan.window(at: index, readFrames: readFrames)
            try table.append(observing: window, inference: inference, plda: plda)
        }
        guard table.extractedSlotCount > 0 else { throw Community1Error.noSpeechDetected }
        guard table.rowCount > 0 else { throw Community1Error.noFiniteTrainingEmbeddings }

        let centroids = try Self.centroids(of: table, phi: plda.phi)
        let reconstructionWindows = try Self.reconstructionWindows(of: table, centroids: centroids, plan: plan)
        let reconstruction = try Community1Reconstruction.reconstruct(
            windows: reconstructionWindows,
            clusterCount: centroids.count,
            frameDuration: Community1Profile.windowDurationSeconds / Double(Community1Profile.segmentationFrames)
        )
        return try Self.spans(from: reconstruction.segments, sampleCount: sampleCount)
    }

    private static func centroids(of table: Community1ObservationTable, phi: [Double]) throws -> [[Double]] {
        let training = table.trainingEmbeddings()
        let rho = table.trainingRho()
        let initialClusters: [Int]
        if training.count >= 2 {
            initialClusters = try Community1AHC.cluster(embeddingFeatures: training).labels
        } else {
            initialClusters = [Int](repeating: 0, count: training.count)
        }
        let vbx = try Community1VBx.refine(rhoFeatures: rho, initialClusters: initialClusters, phi: phi)
        return try Community1Centroids.compute(
            trainingEmbeddings: training,
            rhoFeatures: rho,
            vbx: vbx
        ).centroids
    }

    private static func reconstructionWindows(
        of table: Community1ObservationTable,
        centroids: [[Double]],
        plan: Community1WindowPlan
    ) throws -> [ReconstructionWindow] {
        let nonfiniteEmbedding = [Double](repeating: .nan, count: Community1Profile.embeddingDimensions)
        var windows: [ReconstructionWindow] = []
        windows.reserveCapacity(table.windows.count)
        for (index, observation) in table.windows.enumerated() {
            try Task.checkCancellation()
            var slotEmbeddings: [[Double]?] = []
            for outcome in observation.slots {
                switch outcome {
                case .notExtracted: slotEmbeddings.append(nil)
                case .nonfinite: slotEmbeddings.append(nonfiniteEmbedding)
                case .finite(let row): slotEmbeddings.append(table.embedding(row: row))
                }
            }
            let assignments: [Int]
            if slotEmbeddings.allSatisfy({ $0 == nil }) {
                assignments = [Int](repeating: -2, count: Community1Profile.localSpeakers)
            } else if centroids.count == 1 {
                // FluidAudio runs the constrained assignment only for two or more centroids; a single
                // centroid takes every extracted slot (OfflineDiarizerManager.swift:658-672).
                assignments = slotEmbeddings.map { $0 == nil ? -2 : 0 }
            } else {
                assignments = try Community1Assignment.assign(embeddings: slotEmbeddings, centroids: centroids)
            }
            windows.append(ReconstructionWindow(
                offsetSeconds: Double(try plan.startFrame(at: index)) / Double(Community1Profile.sampleRate),
                speakerBits: observation.speakerBits,
                assignments: assignments
            ))
        }
        return windows
    }

    private static func spans(
        from segments: [ReconstructedSegment],
        sampleCount: Int64
    ) throws -> [SpeakerSpan] {
        let mapper = SpeakerSpanMapper(sampleRate: Double(Community1Profile.sampleRate))
        return try segments
            .map { segment in
                let span = mapper.map(
                    speakerID: segment.speakerID,
                    startSeconds: Double(segment.startSeconds),
                    endSeconds: Double(segment.endSeconds),
                    confidence: Double(segment.quality)
                )
                guard span.startFrame >= 0,
                      span.startFrame < sampleCount,
                      span.endFrame > span.startFrame,
                      let endFrame = DiarizationFinalWindowPadding.clampedEndFrame(
                          span.endFrame,
                          sampleCount: sampleCount,
                          windowSamples: Int64(Community1Profile.windowSamples),
                          stepSamples: Int64(Community1Profile.stepSamples)
                      ) else {
                    throw Community1Error.invalidSpeakerSpan(
                        speakerID: span.speakerID,
                        startFrame: span.startFrame,
                        endFrame: span.endFrame,
                        totalFrames: sampleCount
                    )
                }
                guard endFrame != span.endFrame else { return span }
                return SpeakerSpan(
                    speakerID: span.speakerID,
                    startFrame: span.startFrame,
                    endFrame: endFrame,
                    confidence: span.confidence
                )
            }
            .sorted {
                if $0.startFrame == $1.startFrame { return $0.endFrame < $1.endFrame }
                return $0.startFrame < $1.startFrame
            }
    }
}

extension Community1ObservationTable {
    /// Segments one window, selects its masks, embeds them and records the three slot outcomes.
    fileprivate mutating func append(
        observing window: WindowAudio,
        inference: any Community1Inference,
        plda: Community1PLDA
    ) throws {
        let activity = Community1Frontend.decode(try inference.segment(window))
        let selected = try Community1Frontend.selectMasks(activity)
        var slots = [Community1SlotObservation](repeating: .notExtracted, count: Community1Profile.localSpeakers)
        if !selected.isEmpty {
            let masks = selected.map { SpeakerMask(activity: $0.mask) }
            let vectors = try inference.embed(features: Community1Fbank.shared.features(of: window), masks: masks)
            guard vectors.count == masks.count else {
                throw Community1Error.invalidModelOutput(
                    stage: "embedding",
                    reason: "returned \(vectors.count) vectors for \(masks.count) masks"
                )
            }
            for (selection, vector) in zip(selected, vectors) {
                slots[selection.speakerIndex] = try Self.observation(of: vector, plda: plda)
            }
        }
        append(speakerBits: activity.speakerBits, slots: slots)
    }

    private static func observation(of vector: [Float], plda: Community1PLDA) throws -> Community1SlotObservation {
        guard vector.count == Community1Profile.embeddingDimensions else {
            throw Community1Error.invalidModelOutput(
                stage: "embedding",
                reason: "vector has \(vector.count) values; expected \(Community1Profile.embeddingDimensions)"
            )
        }
        guard vector.allSatisfy(\.isFinite) else { return .nonfinite }
        var squaredNorm = 0.0
        for value in vector { squaredNorm += Double(value) * Double(value) }
        let denominator = max(squaredNorm.squareRoot(), Double(Community1Profile.embeddingL2Floor))
        let normalized = vector.map { Float(Double($0) / denominator) }
        guard normalized.allSatisfy(\.isFinite) else { return .nonfinite }
        return .finite(embedding: normalized, rho: try plda.rho(embedding: normalized))
    }
}
