import Foundation

/// What one local speaker slot of one window produced.
enum Community1SlotObservation {
    /// The slot failed the mask gates, so no embedding was requested.
    case notExtracted
    /// The model returned a nonfinite vector. It still competes in assignment but never trains clusters.
    case nonfinite
    /// A normalized 256-dimensional embedding and its 128-dimensional PLDA rho.
    case finite(embedding: [Float], rho: [Double])
}

/// The stored outcome of one slot; finite slots point at their row in the flat tables.
enum Community1SlotOutcome: Equatable {
    case notExtracted
    case nonfinite
    case finite(row: Int)
}

struct Community1WindowObservation {
    let speakerBits: [UInt8]
    let slots: [Community1SlotOutcome]
}

struct Community1EmbeddingKey: Equatable {
    let window: Int
    let slot: Int
}

/// Everything one diarization run knows about its windows, in chronological order.
///
/// Each window keeps its 589 powerset speaker bitmasks and three slot outcomes. Finite embeddings
/// and rho vectors live in two flat row-major tables, so the training set for clustering is
/// the whole table in order. `append` is the only writer and keeps the `(window, slot)` <-> row
/// relation a bijection.
struct Community1ObservationTable {
    private(set) var windows: [Community1WindowObservation] = []
    private(set) var rowKeys: [Community1EmbeddingKey] = []
    private(set) var extractedSlotCount = 0
    private var embeddings: [Float] = []
    private var rho: [Double] = []

    var rowCount: Int { rowKeys.count }

    mutating func append(speakerBits: [UInt8], slots: [Community1SlotObservation]) {
        precondition(speakerBits.count == Community1Profile.segmentationFrames)
        precondition(slots.count == Community1Profile.localSpeakers)
        let windowIndex = windows.count
        var outcomes: [Community1SlotOutcome] = []
        outcomes.reserveCapacity(Community1Profile.localSpeakers)
        for (slot, observation) in slots.enumerated() {
            switch observation {
            case .notExtracted:
                outcomes.append(.notExtracted)
            case .nonfinite:
                extractedSlotCount += 1
                outcomes.append(.nonfinite)
            case let .finite(embedding, rho):
                precondition(embedding.count == Community1Profile.embeddingDimensions)
                precondition(rho.count == Community1Profile.rhoDimensions)
                extractedSlotCount += 1
                outcomes.append(.finite(row: rowKeys.count))
                rowKeys.append(Community1EmbeddingKey(window: windowIndex, slot: slot))
                embeddings.append(contentsOf: embedding)
                self.rho.append(contentsOf: rho)
            }
        }
        windows.append(Community1WindowObservation(speakerBits: speakerBits, slots: outcomes))
    }

    func embedding(row: Int) -> [Double] {
        let start = row * Community1Profile.embeddingDimensions
        return embeddings[start..<start + Community1Profile.embeddingDimensions].map(Double.init)
    }

    func trainingEmbeddings() -> [[Double]] {
        (0..<rowCount).map { embedding(row: $0) }
    }

    func trainingRho() -> [[Double]] {
        (0..<rowCount).map { row in
            let start = row * Community1Profile.rhoDimensions
            return Array(rho[start..<start + Community1Profile.rhoDimensions])
        }
    }
}
