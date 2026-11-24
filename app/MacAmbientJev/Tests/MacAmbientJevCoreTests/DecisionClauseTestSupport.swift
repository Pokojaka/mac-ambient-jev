import Foundation
@testable import MacAmbientJevCore

/// Deterministic injected decision answers. They are fixtures for code paths, not claims about what
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

let testDecisionIdentity = try! DecisionModelIdentity(backend: "test-backend", model: "test-tagger", modelRevision: String(repeating: "0", count: 64))
let testInputTokens = 10

/// Accepts a candidate after `。？！?!` and rejects one after `、`; continues into the next
/// segment only for sources whose segment ID is in `continuing`.
func punctuationBoundaries(
    continuing: Set<String>,
    fillerRangesBySegment: [String: [TextUTF16Range]]
) -> ScriptedDecisionProvider.BoundaryAnswer {
    { request in
        var probabilities: [String: Double] = [:]
        let utf16 = Array(request.text.utf16)
        for candidate in request.candidates {
            let previous = utf16[candidate.offsetUTF16 - 1]
            probabilities[candidate.id] = previous == "、".utf16.first! ? 0.1 : 0.9
        }
        // An omitted segment explicitly has no F ranges in this fixture.
        let fillerRanges = fillerRangesBySegment[request.source.segmentID] ?? []
        return ClauseBoundaryResponse(
            probabilities: probabilities,
            continuationProbability: request.next.map { _ in continuing.contains(request.source.segmentID) ? 0.9 : 0.1 },
            fillerRanges: fillerRanges,
            inputTokens: testInputTokens
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
    return PriorityBatchResponse(decisions: decisions, inputTokens: testInputTokens)
}

let transcriptRuns = ActiveRuns(segmentation: "seg", asr: "asr")

func temporarySessionRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

/// Writes a schema-4 generation with one segment per text. A nil text leaves the
/// segment without an ASR result and therefore leaves the ASR stage incomplete.
func writeTranscript(
    _ texts: [String?],
    root: URL,
    sessionID: UUID,
    sampleRate: Double = 1_000,
    frameCount: Int64? = nil
) async throws -> [TranscriptEvent] {
    let writer = try SessionWriter(sessionURL: root)
    let provenance = RunProvenance(engine: "test", model: nil, version: "1", configuration: [:])
    let generation = PipelineGeneration(
        id: UUID(), runs: transcriptRuns, sampleRate: sampleRate,
        segmentationProvenance: provenance, asrProvenance: provenance
    )
    try await writer.append(generation.startEvent(sessionID: sessionID))
    for (stage, runID) in [(ProcessingStage.segmentation, "seg"), (.asr, "asr")] {
        try await writer.append(EventDraft(
            eventType: "processing.run.started", sessionID: sessionID, processingRunID: runID,
            payload: ProcessingRunStartedPayload(stage: stage, provenance: provenance)
        ))
    }

    let segments = texts.enumerated().map { index, _ in
        SegmentReference(
            segmentationRunID: "seg", segmentID: String(format: "s%02d", index + 1),
            speechRanges: [Int64(index * 1_000)..<Int64(index * 1_000 + 900)]
        )
    }
    let sealedFrameCount = frameCount ?? (segments.last?.endFrame ?? 0)
    guard segments.allSatisfy({ $0.endFrame <= sealedFrameCount }) else {
        throw ProcessingLogStateError.incompleteRecognition
    }

    var events: [TranscriptEvent] = []
    for segment in segments {
        let created = try await writer.append(EventDraft.segmentCreated(sessionID: sessionID, segment: segment))
        events.append(.segmentCreated(
            seq: created.eventSeq, segmentationRunID: segment.segmentationRunID, segmentID: segment.segmentID,
            startFrame: segment.startFrame, endFrame: segment.endFrame
        ))
    }
    try await writer.append(EventDraft(
        eventType: "segmentation.input.sealed", sessionID: sessionID, segmentationRunID: "seg",
        payload: SegmentationInputSealedPayload(frameCount: sealedFrameCount)
    ))
    try await writer.append(EventDraft(
        eventType: "segmentation.completed", sessionID: sessionID, segmentationRunID: "seg",
        payload: SegmentationCompletedPayload(consumedFrames: sealedFrameCount, segmentCount: segments.count)
    ))
    try await writer.append(EventDraft(
        eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "seg",
        payload: ProcessingRunCompletedPayload(
            stage: .segmentation, succeeded: true, completedCount: segments.count, failedCount: 0
        )
    ))

    for (segment, text) in zip(segments, texts) {
        guard let text else { continue }
        let completed = try await writer.append(EventDraft(
            eventType: "asr.completed", sessionID: sessionID, processingRunID: "asr",
            segmentationRunID: "seg", segmentID: segment.segmentID,
            sourceStartFrame: segment.startFrame, sourceEndFrame: segment.endFrame,
            payload: ASRCompletedEventPayload(text: text, detectedLanguage: "ja", provenance: provenance)
        ))
        events.append(.asrCompleted(
            seq: completed.eventSeq, runID: "asr", segmentationRunID: "seg",
            segmentID: segment.segmentID, text: text, detectedLanguage: "ja"
        ))
    }
    if texts.allSatisfy({ $0 != nil }) {
        try await writer.append(EventDraft(
            eventType: "processing.run.completed", sessionID: sessionID, processingRunID: "asr",
            payload: ProcessingRunCompletedPayload(
                stage: .asr, succeeded: true, completedCount: texts.count, failedCount: 0
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

/// Saves completion status for the currently selected, fully recognized generation.
func saveCompletedStatus(root: URL, sessionID: UUID) throws {
    let stored = try readStored(root: root, sessionID: sessionID)
    guard stored.state.recognitionCompleted, !stored.state.hasUnresolvedASRFailure else {
        throw ProcessingLogStateError.incompleteRecognition
    }
    try ProcessingMetadataStore(sessionURL: root).save(ProcessingMetadata(
        generationID: stored.state.generation.id, state: .complete, failureReason: nil
    ))
}

/// Runs one decision snapshot and appends the event selecting its returned runs.
func buildAndPublish(
    root: URL,
    sessionID: UUID,
    provider: any DecisionProvider,
    scope: DecisionEnrichmentScope,
    reusable: [ExactClauseTextKey: ReusableClauseDecision] = [:],
    counter: DecisionUsageCounter = DecisionUsageCounter(),
    boundaryRunID: String? = nil,
    priorityRunID: String = "priority_\(UUID().uuidString.lowercased())"
) async throws -> DecisionEnrichmentBatchResult {
    let stored = try readStored(root: root, sessionID: sessionID)
    let activeRuns = stored.state.runs
    let coordinator = DecisionEnrichmentCoordinator(
        sessionID: sessionID,
        boundaryRunID: boundaryRunID ?? "boundary_\(UUID().uuidString.lowercased())",
        priorityRunID: priorityRunID,
        writer: try SessionWriter(sessionURL: root),
        decisions: DecisionCoordinator(provider: provider, identity: testDecisionIdentity, usageCounter: counter),
        usageCounter: counter,
        materializer: TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
    )
    let result = try await coordinator.process(
        existingEvents: stored.events, activeRuns: activeRuns, scope: scope,
        reusableDecisions: reusable, onEvent: nil
    )
    let previous: DecisionRunIDs?
    if let boundary = activeRuns.clauseBoundary, let priority = activeRuns.contentPriority {
        previous = DecisionRunIDs(boundary: boundary, priority: priority)
    } else {
        previous = nil
    }
    let replacement = DecisionRunReplacement(
        generationID: stored.state.generation.id, previous: previous,
        replacement: DecisionRunIDs(boundary: result.boundaryRunID, priority: result.priorityRunID)
    )
    try await SessionWriter(sessionURL: root).append(replacement.selectionEvent(sessionID: sessionID))
    await coordinator.recordPublished(result, replacing: stored.pendingDecisions.pendingTargets)
    return result
}

func readStored(root: URL, sessionID: UUID) throws -> StoredTranscriptEvents {
    guard let stored = try EventLogTranscriptReader().read(
        eventsURL: root.appending(path: "events.jsonl"), sessionID: sessionID
    ) else {
        throw ProcessingLogStateError.missingGeneration
    }
    return stored
}

/// The selected transcript read back through the reader and materializer.
func readPublished(root: URL, sessionID: UUID) throws -> [MaterializedTranscriptSegment] {
    let stored = try readStored(root: root, sessionID: sessionID)
    return try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate).materialize(
        events: stored.events, activeRuns: stored.state.runs
    )
}

struct MissingTestValue: Error {}

func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw MissingTestValue() }
    return value
}
