import Foundation
import MacAmbientJevCore

/// Serializes provisional Jev work independently of live ASR and recording drain.
public actor LiveContentPrioritySession {
    public typealias DecisionFactory = @Sendable () throws -> JevDecisionCoordinator?
    public typealias StatusHandler = @Sendable (String) async -> Void
    public typealias UpdateHandler = @Sendable (LiveASRSnapshot) async -> Void

    public nonisolated let runID: String

    private struct Work: Sendable {
        let segmentID: String
        let events: [TranscriptEvent]
        let activeRuns: ActiveRuns
        let onStatus: StatusHandler
        let onUpdate: UpdateHandler
    }

    private let sessionID: UUID
    private let writer: SessionWriter
    private let liveASR: LiveASRSession
    private let sampleRate: Double
    private let makeDecisions: DecisionFactory
    private var coordinator: JevEnrichmentCoordinator?
    private var queue: [Work] = []
    private var nextWorkIndex = 0
    private var enqueuedSegmentIDs: Set<String> = []
    /// Rows recognized by live ASR whose Jev decision has not arrived. They are not displayed.
    private var awaitingSegmentIDs: Set<String> = []
    private var worker: Task<Void, Never>?
    private var stopReason: JevBatchStopReason?
    private var stopped = false

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        liveASR: LiveASRSession,
        sampleRate: Double,
        makeDecisions: @escaping DecisionFactory
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.liveASR = liveASR
        self.sampleRate = sampleRate
        self.makeDecisions = makeDecisions
    }

    /// Queues only the newly recognized row and returns without waiting for Jev.
    public func enqueue(
        segmentID: String,
        snapshot: LiveASRSnapshot,
        onStatus: @escaping StatusHandler,
        onUpdate: @escaping UpdateHandler
    ) {
        guard !stopped,
              !enqueuedSegmentIDs.contains(segmentID),
              snapshot.progress.materializedSegments.contains(where: {
                  $0.segmentID == segmentID && $0.hasRecognizedText
              }) else { return }
        enqueuedSegmentIDs.insert(segmentID)
        awaitingSegmentIDs.insert(segmentID)
        queue.append(Work(
            segmentID: segmentID,
            events: snapshot.events.filter { $0.segmentID == segmentID },
            activeRuns: snapshot.activeRuns,
            onStatus: onStatus,
            onUpdate: onUpdate
        ))
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    /// The rows to display: everything before the earliest row still waiting for its decision,
    /// so a waiting row never lets a later row jump ahead of it.
    public func displayable(_ segments: [MaterializedTranscriptSegment]) -> [MaterializedTranscriptSegment] {
        guard !awaitingSegmentIDs.isEmpty else { return segments }
        return Array(segments.prefix { !awaitingSegmentIDs.contains($0.segmentID) })
    }

    /// Stops immediately even if a provider ignores task cancellation.
    /// Durable decisions already saved remain available to finalization.
    public func stop() {
        stopped = true
        worker?.cancel()
        worker = nil
        queue.removeAll()
        nextWorkIndex = 0
        awaitingSegmentIDs.removeAll()
    }

    private func drain() async {
        defer {
            queue.removeAll()
            nextWorkIndex = 0
            worker = nil
        }
        while !stopped && !Task.isCancelled && nextWorkIndex < queue.count {
            let work = queue[nextWorkIndex]
            nextWorkIndex += 1
            await classify(work)
            guard !stopped && !Task.isCancelled else { return }
            await release(work)
        }
    }

    /// Every outcome except cancellation ends with the row displayable: a decision, or
    /// a normal row when Jev is off, failed, deferred, or stopped.
    private func classify(_ work: Work) async {
        // Recheck current settings for every queued row, even after the run starts.
        let available: JevDecisionCoordinator
        do {
            guard let decisions = try makeDecisions() else {
                await reportPending(work: work)
                return
            }
            available = decisions
        } catch {
            await report(
                "\(UserFacingStatus.jevDeferred.text)。意味分類器を初期化できませんでした: \(error.localizedDescription)",
                work: work
            )
            return
        }

        do {
            try Task.checkCancellation()
            guard !stopped else { return }
            let enrichment: JevEnrichmentCoordinator
            if let coordinator {
                enrichment = coordinator
            } else {
                _ = try await writer.append(EventDraft(
                    eventType: "processing.run.started",
                    sessionID: sessionID,
                    processingRunID: runID,
                    segmentationRunID: work.activeRuns.segmentation,
                    payload: ProcessingRunStartedPayload(
                        stage: .contentPriority,
                        provenance: Self.provenance
                    )
                ))
                try Task.checkCancellation()
                guard !stopped else { return }
                enrichment = JevEnrichmentCoordinator(
                    sessionID: sessionID,
                    runID: runID,
                    writer: writer,
                    decisions: available,
                    materializer: TranscriptMaterializer(sampleRate: sampleRate)
                )
                coordinator = enrichment
            }
            if stopReason == nil {
                await report(UserFacingStatus.classifyingWithJev.text, work: work)
            }
            try Task.checkCancellation()
            guard !stopped else { return }
            let result = try await enrichment.process(
                existingEvents: work.events,
                activeRuns: work.activeRuns,
                scope: .all,
                reusableDecisions: [:],
                completeRun: false,
                onAssignment: { event, _ in
                    await self.applyAssignment(event, work: work)
                }
            )
            try Task.checkCancellation()
            guard !stopped else { return }
            stopReason = result.stopReason
            if !result.retryPendingSegmentIDs.isEmpty {
                await reportPending(work: work)
            }
        } catch {
            guard !stopped && !Task.isCancelled else { return }
            await report(
                "\(UserFacingStatus.jevDeferred.text)。意味分類を保存できませんでした: \(error.localizedDescription)",
                work: work
            )
        }
    }

    private func release(_ work: Work) async {
        guard awaitingSegmentIDs.remove(work.segmentID) != nil else { return }
        await work.onUpdate(await liveASR.snapshot())
    }

    private func applyAssignment(_ event: TranscriptEvent, work: Work) async {
        guard !stopped && !Task.isCancelled else { return }
        let snapshot = await liveASR.applyContentPriority(event: event)
        guard !stopped && !Task.isCancelled else { return }
        awaitingSegmentIDs.remove(work.segmentID)
        await work.onUpdate(snapshot)
    }

    private func reportPending(work: Work) async {
        await report(
            stopReason == .authorizationRejected
                ? UserFacingStatus.jevAuthorizationRequired.text
                : UserFacingStatus.jevDeferred.text,
            work: work
        )
    }

    private func report(_ text: String, work: Work) async {
        guard !stopped && !Task.isCancelled else { return }
        await work.onStatus(text)
    }

    private static let provenance = RunProvenance(
        engine: "jev",
        model: nil,
        version: "1",
        configuration: [
            "mode": "live",
            "endpoint": JevClient.endpoint.absoluteString,
            "minimum_demotion_confidence": String(ContentPriorityPolicy.minimumDemotionConfidence),
        ]
    )
}
