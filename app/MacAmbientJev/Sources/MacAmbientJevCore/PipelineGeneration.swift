import Foundation

public struct PipelineGeneration: Codable, Sendable, Equatable {
    public let id: UUID
    public let runs: ActiveRuns
    public let sampleRate: Double
    public let segmentationProvenance: RunProvenance
    public let asrProvenance: RunProvenance

    private enum CodingKeys: String, CodingKey {
        case id, runs
        case sampleRate = "sample_rate"
        case segmentationProvenance = "segmentation_provenance"
        case asrProvenance = "asr_provenance"
    }

    public init(id: UUID, runs: ActiveRuns, sampleRate: Double,
                segmentationProvenance: RunProvenance, asrProvenance: RunProvenance) {
        self.id = id
        self.runs = runs
        self.sampleRate = sampleRate
        self.segmentationProvenance = segmentationProvenance
        self.asrProvenance = asrProvenance
    }

    public func startEvent(sessionID: UUID) -> EventDraft<PipelineGeneration> {
        EventDraft(eventType: "pipeline.started", sessionID: sessionID, payload: self)
    }
}

public struct DecisionRunIDs: Codable, Sendable, Equatable {
    public let boundary: String
    public let priority: String

    public init(boundary: String, priority: String) {
        self.boundary = boundary
        self.priority = priority
    }
}

public struct DecisionRunReplacement: Codable, Sendable, Equatable {
    public let generationID: UUID
    public let previous: DecisionRunIDs?
    public let replacement: DecisionRunIDs

    private enum CodingKeys: String, CodingKey {
        case generationID = "generation_id", previous, replacement
    }

    public init(generationID: UUID, previous: DecisionRunIDs?, replacement: DecisionRunIDs) {
        self.generationID = generationID
        self.previous = previous
        self.replacement = replacement
    }

    public func selectionEvent(sessionID: UUID) -> EventDraft<DecisionRunReplacement> {
        EventDraft(eventType: "pipeline.decisions.replaced", sessionID: sessionID, payload: self)
    }
}

struct GenerationEventLog {
    let generation: PipelineGeneration
    let runs: ActiveRuns
    let lines: [EventLogLine]
    let selectionSeq: UInt64

    init?(lines: [EventLogLine], sessionID: UUID) throws {
        guard let start = lines.filter({ $0.header.eventType == "pipeline.started" })
            .max(by: { $0.header.eventSeq < $1.header.eventSeq }) else { return nil }
        guard start.header.sessionID == sessionID, Self.hasNoRunIDs(start) else { throw start.malformed }
        let generation = try start.body(PayloadBody<PipelineGeneration>.self).payload
        let initial = generation.runs
        guard generation.sampleRate.isFinite, generation.sampleRate > 0,
              let segmentation = initial.segmentation, Self.nonblank(segmentation),
              let asr = initial.asr, Self.nonblank(asr),
              (initial.clauseBoundary == nil) == (initial.contentPriority == nil) else { throw start.malformed }
        let initialIDs = [segmentation, asr] + [initial.clauseBoundary, initial.contentPriority].compactMap { $0 }
        guard Set(initialIDs).count == initialIDs.count,
              initialIDs.allSatisfy(Self.nonblank) else { throw start.malformed }

        let after = lines.filter { $0.header.eventSeq > start.header.eventSeq }
            .sorted { $0.header.eventSeq < $1.header.eventSeq }
        var selected = initial
        var selectionSeq = start.header.eventSeq
        var selectedPriorities = Set([initial.contentPriority].compactMap { $0 })
        for line in after where line.header.eventType == "pipeline.decisions.replaced" {
            guard line.header.sessionID == sessionID, Self.hasNoRunIDs(line) else { throw line.malformed }
            let event = try line.body(PayloadBody<DecisionRunReplacement>.self).payload
            let ids = event.replacement
            guard event.generationID == generation.id,
                  event.previous == Self.decisionIDs(selected),
                  Self.nonblank(ids.boundary), Self.nonblank(ids.priority),
                  ids.boundary != ids.priority,
                  ids.boundary != segmentation, ids.boundary != asr,
                  ids.priority != segmentation, ids.priority != asr,
                  !selectedPriorities.contains(ids.priority) else { throw line.malformed }
            selected = selected.withDecisionRuns(clauseBoundary: ids.boundary, contentPriority: ids.priority)
            selectedPriorities.insert(ids.priority)
            selectionSeq = line.header.eventSeq
        }
        self.generation = generation
        self.runs = selected
        self.lines = after
        self.selectionSeq = selectionSeq
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasNoRunIDs(_ line: EventLogLine) -> Bool {
        line.header.processingRunID == nil && line.header.segmentationRunID == nil && line.header.segmentID == nil
    }

    private static func decisionIDs(_ runs: ActiveRuns) -> DecisionRunIDs? {
        guard let boundary = runs.clauseBoundary, let priority = runs.contentPriority else { return nil }
        return DecisionRunIDs(boundary: boundary, priority: priority)
    }
}
