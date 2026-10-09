import Foundation
@testable import MacAmbientJevCore

/// Deterministic injected Jev answers. They are fixtures for code paths, not claims about what
/// the real model answers.
actor ScriptedDecisionProvider: DecisionProvider {
    typealias BoundaryAnswer = @Sendable (ClauseBoundaryRequest) throws -> ClauseBoundaryResponse
    typealias PriorityAnswer = @Sendable ([PriorityTextTarget]) throws -> PriorityBatchResponse

    private let boundary: BoundaryAnswer
    private let priority: PriorityAnswer
    private(set) var boundaryRequests: [ClauseBoundaryRequest] = []
    private(set) var priorityRequests: [[PriorityTextTarget]] = []

    init(boundary: @escaping BoundaryAnswer, priority: @escaping PriorityAnswer) {
        self.boundary = boundary
        self.priority = priority
    }

    func assessBoundaries(_ request: ClauseBoundaryRequest) async throws -> ClauseBoundaryResponse {
        boundaryRequests.append(request)
        return try boundary(request)
    }

    func classifyPriorities(_ targets: [PriorityTextTarget]) async throws -> PriorityBatchResponse {
        priorityRequests.append(targets)
        return try priority(targets)
    }
}

let testMetadata = try! JevResponseMetadata(model: "jev-test", inputTokens: 10, outputTokens: 2)

/// Accepts a candidate after `。？！?!` and rejects one after `、`; continues into the next
/// segment only for sources whose segment ID is in `continuing`.
func punctuationBoundaries(continuing: Set<String>) -> ScriptedDecisionProvider.BoundaryAnswer {
    { request in
        var probabilities: [String: Double] = [:]
        let utf16 = Array(request.text.utf16)
        for candidate in request.candidates {
            let previous = utf16[candidate.offsetUTF16 - 1]
            probabilities[candidate.id] = previous == "、".utf16.first! ? 0.1 : 0.9
        }
        return ClauseBoundaryResponse(
            probabilities: probabilities,
            continuationProbability: request.next.map { _ in continuing.contains(request.source.segmentID) ? 0.9 : 0.1 },
            metadata: testMetadata
        )
    }
}

/// LOW_PRIORITY with confidence 0.95 for texts containing `うん`, PRIMARY otherwise.
let lowForBackchannel: ScriptedDecisionProvider.PriorityAnswer = { targets in
    var decisions: [String: ContentPriorityDecision] = [:]
    for target in targets {
        let low = target.text.contains("うん")
        decisions[target.key] = try ContentPriorityDecision(
            priority: low ? .lowPriority : .primary, confidence: 0.95,
            probabilities: low ? ["PRIMARY": 0.025, "LOW_PRIORITY": 0.975] : ["PRIMARY": 0.975, "LOW_PRIORITY": 0.025]
        )
    }
    return PriorityBatchResponse(decisions: decisions, metadata: testMetadata)
}

let transcriptRuns = ActiveRuns(segmentation: "seg", asr: "asr", diarization: "diar")

func temporarySessionRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

/// Writes one segment per text (time order = array order) with its ASR result, the way a
/// finalization does, and returns the transcript events. A nil text leaves the segment without ASR.
func writeTranscript(_ texts: [String?], root: URL, sessionID: UUID) async throws -> [TranscriptEvent] {
    let writer = try SessionWriter(sessionURL: root)
    var events: [TranscriptEvent] = []
    let provenance = RunProvenance(engine: "test", model: nil, version: "1", configuration: [:])
    let localRuns: [(ProcessingStage, String)] = [
        (.segmentation, "seg"), (.asr, "asr"), (.diarization, "diar")
    ]
    for (stage, runID) in localRuns {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }
    for (index, text) in texts.enumerated() {
        let segmentID = String(format: "s%02d", index + 1)
        let start = Int64(index * 1_000)
        let created = try await writer.append(EventDraft(
            eventType: "segment.created", sessionID: sessionID, segmentationRunID: "seg", segmentID: segmentID,
            sourceStartFrame: start, sourceEndFrame: start + 900, payload: EmptyPayload()
        ))
        events.append(.segmentCreated(seq: created.eventSeq, segmentationRunID: "seg", segmentID: segmentID,
                                      startFrame: start, endFrame: start + 900))
        guard let text else { continue }
        let completed = try await writer.append(EventDraft(
            eventType: "asr.completed", sessionID: sessionID, processingRunID: "asr", segmentationRunID: "seg",
            segmentID: segmentID, sourceStartFrame: start, sourceEndFrame: start + 900,
            payload: ASRCompletedEventPayload(text: text, detectedLanguage: "ja", provenance: provenance)
        ))
        events.append(.asrCompleted(seq: completed.eventSeq, runID: "asr", segmentationRunID: "seg",
                                    segmentID: segmentID, text: text, detectedLanguage: "ja"))
    }
    for (stage, runID) in localRuns {
        let completed: Int
        let failed: Int
        switch stage {
        case .segmentation:
            completed = texts.count
            failed = 0
        case .asr:
            completed = texts.compactMap { $0 }.count
            failed = texts.count - completed
        default:
            completed = 0
            failed = 0
        }
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: stage, succeeded: true, completedCount: completed, failedCount: failed
            )
        ))
    }
    return events
}

func eventLines(_ root: URL) throws -> [Data] {
    try SessionRecovery.recoverJSONL(Data(contentsOf: root.appending(path: "events.jsonl"))).lines
}

func eventObjects(_ root: URL) throws -> [[String: Any]] {
    try eventLines(root).map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
}

func source(_ segmentID: String, in events: [TranscriptEvent]) throws -> SegmentTextReference {
    guard let event = events.first(where: { $0.segmentID == segmentID && $0.processingRunID == "asr" }),
          let source = try event.asrSource() else {
        throw TranscriptMaterializationError.missingClauseSource
    }
    return source
}

/// Saves local metadata as a completed finalization would publish it.
func publishLocal(root: URL, events: [TranscriptEvent]) throws -> ProcessingMetadata {
    let pending = try TranscriptMaterializer(sampleRate: 1_000).materialize(events: events, activeRuns: transcriptRuns)
        .filter(\.hasRecognizedText).map(\.source)
    let metadata = ProcessingMetadata(
        finalizationAttempt: FinalizationAttempt(attemptID: "attempt", state: .complete, failureReason: nil),
        activeRuns: transcriptRuns,
        pendingClauseBoundarySegments: pending,
        pendingContentPriorityClauses: []
    )
    try ProcessingMetadataStore(sessionURL: root).save(metadata)
    return metadata
}

/// Runs one Jev snapshot through the coordinator and publishes it the way the processor does.
func buildAndPublish(
    root: URL,
    sessionID: UUID,
    provider: (any DecisionProvider)?,
    scope: JevEnrichmentScope,
    reusable: [ExactClauseTextKey: ReusableClauseDecision] = [:],
    counter: JevUsageCounter = JevUsageCounter(),
    boundaryRunID: String? = nil,
    priorityRunID: String = "priority_\(UUID().uuidString.lowercased())"
) async throws -> JevEnrichmentBatchResult {
    let store = ProcessingMetadataStore(sessionURL: root)
    let metadata = try requireValue(try store.load())
    let activeRuns = try requireValue(metadata.activeRuns)
    let events = try EventLogTranscriptReader().events(lines: eventLines(root), activeRuns: activeRuns)
    let coordinator = JevEnrichmentCoordinator(
        sessionID: sessionID,
        boundaryRunID: boundaryRunID ?? "boundary_\(UUID().uuidString.lowercased())",
        priorityRunID: priorityRunID,
        writer: try SessionWriter(sessionURL: root),
        decisions: provider.map { JevDecisionCoordinator(provider: $0, usageCounter: counter) },
        usageCounter: counter,
        materializer: TranscriptMaterializer(sampleRate: 1_000)
    )
    let result = try await coordinator.process(
        existingEvents: events, activeRuns: activeRuns, scope: scope, reusableDecisions: reusable, onEvent: nil
    )
    try store.publishJevSnapshot(
        basedOn: activeRuns,
        clauseBoundaryRunID: result.boundaryRunID,
        contentPriorityRunID: result.priorityRunID,
        pendingClauseBoundarySegments: result.pendingBoundarySegments,
        pendingContentPriorityClauses: result.pendingPriorityClauses
    )
    await coordinator.recordPublished(result, replacing: metadata.pendingJevTargets)
    return result
}

/// The published transcript read back through the reader and materializer.
func readPublished(root: URL) throws -> [MaterializedTranscriptSegment] {
    let activeRuns = try requireValue(try ProcessingMetadataStore(sessionURL: root).load()?.activeRuns)
    return try TranscriptMaterializer(sampleRate: 1_000).materialize(
        events: try EventLogTranscriptReader().events(lines: eventLines(root), activeRuns: activeRuns),
        activeRuns: activeRuns
    )
}

struct MissingTestValue: Error {}

func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingTestValue() }
    return value
}
