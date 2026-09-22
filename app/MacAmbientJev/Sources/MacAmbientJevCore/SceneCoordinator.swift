import Foundation

public struct SceneBatchResult: Sendable, Equatable {
    public let transitions: [SceneTransition]
    public let events: [TranscriptEvent]
    public let materializedSegments: [MaterializedTranscriptSegment]

    public init(
        transitions: [SceneTransition],
        events: [TranscriptEvent],
        materializedSegments: [MaterializedTranscriptSegment]
    ) {
        self.transitions = transitions
        self.events = events
        self.materializedSegments = materializedSegments
    }
}

public actor SceneCoordinator {
    private let sessionID: UUID
    private let runID: String
    private let writer: SessionWriter
    private let materializer: TranscriptMaterializer
    private let config: SceneStateMachineConfig
    private let windowSeconds: Double
    private let hopSeconds: Double

    public init(
        sessionID: UUID,
        runID: String,
        writer: SessionWriter,
        materializer: TranscriptMaterializer,
        config: SceneStateMachineConfig = .production,
        windowSeconds: Double = 20,
        hopSeconds: Double = 1
    ) {
        precondition(windowSeconds > 0)
        precondition(hopSeconds > 0)

        self.sessionID = sessionID
        self.runID = runID
        self.writer = writer
        self.materializer = materializer
        self.config = config
        self.windowSeconds = windowSeconds
        self.hopSeconds = hopSeconds
    }

    public func process(
        speakerSpans: [SpeakerSpan],
        totalFrames: Int64,
        sampleRate: Double,
        existingEvents: [TranscriptEvent],
        activeRuns: ActiveRuns
    ) async throws -> SceneBatchResult {
        precondition(sampleRate > 0)
        precondition(totalFrames >= 0)

        var events = existingEvents
        var transitions: [SceneTransition] = []
        var machine = SceneStateMachine(
            state: .lecture,
            config: config
        )

        let initial = try await writer.append(EventDraft(
            eventType: "scene.changed",
            sessionID: sessionID,
            processingRunID: runID,
            sourceStartFrame: 0,
            payload: SceneState.lecture
        ))
        events.append(.sceneChanged(
            seq: initial.eventSeq,
            runID: runID,
            atFrame: 0,
            scene: .lecture
        ))

        let windowFrames = max(
            1,
            Int64((windowSeconds * sampleRate).rounded())
        )
        let hopFrames = max(
            1,
            Int64((hopSeconds * sampleRate).rounded())
        )
        let extractor = AcousticSceneFeatureExtractor()

        var endFrame = min(windowFrames, totalFrames)
        if totalFrames > 0 {
            while endFrame <= totalFrames {
                let startFrame = max(0, endFrame - windowFrames)
                let features = extractor.extract(
                    speakerSpans: speakerSpans,
                    window: startFrame..<endFrame,
                    sampleRate: sampleRate
                )

                if let transition = machine.observe(features) {
                    transitions.append(transition)

                    let envelope = try await writer.append(EventDraft(
                        eventType: "scene.changed",
                        sessionID: sessionID,
                        processingRunID: runID,
                        sourceStartFrame: endFrame,
                        payload: transition.to
                    ))
                    events.append(.sceneChanged(
                        seq: envelope.eventSeq,
                        runID: runID,
                        atFrame: endFrame,
                        scene: transition.to
                    ))
                }

                if endFrame == totalFrames {
                    break
                }
                endFrame = min(totalFrames, endFrame + hopFrames)
            }
        }

        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: runID,
            payload: ProcessingRunCompletedPayload(
                stage: .scene,
                succeeded: true,
                completedCount: transitions.count + 1,
                failedCount: 0
            )
        ))

        var selectedRuns = activeRuns
        selectedRuns.markCompleted(
            stage: .scene,
            runID: runID,
            succeeded: true
        )
        try selectedRuns.select(stage: .scene, runID: runID)

        let materialized = materializer.materialize(
            events: events,
            activeRuns: selectedRuns
        )

        return SceneBatchResult(
            transitions: transitions,
            events: events,
            materializedSegments: materialized
        )
    }
}
