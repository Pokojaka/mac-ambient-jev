import Foundation
import Testing
@testable import MacAmbientJevCore

private func makeRecoveryEventLog(
    at sessionURL: URL,
    completeSecond: Bool,
    markRunSuccessful: Bool
) async throws -> RecoveredJSONL {
    let writer = try SessionWriter(sessionURL: sessionURL)
    let sessionID = UUID()
    let segmentationRunID = "seg_run_recovery"
    let asrRunID = "asr_run_recovery"

    for index in 0..<2 {
        let segmentID = String(format: "seg_%06d", index + 1)
        let start = Int64(index * 100)
        let end = start + 100

        _ = try await writer.append(EventDraft(
            eventType: "segment.created",
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            sourceStartFrame: start,
            sourceEndFrame: end,
            payload: EmptyPayload()
        ))
        _ = try await writer.append(EventDraft(
            eventType: "asr.pending",
            sessionID: sessionID,
            processingRunID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: segmentID,
            sourceStartFrame: start,
            sourceEndFrame: end,
            payload: EmptyPayload()
        ))
    }

    _ = try await writer.append(EventDraft(
        eventType: "asr.completed",
        sessionID: sessionID,
        processingRunID: asrRunID,
        segmentationRunID: segmentationRunID,
        segmentID: "seg_000001",
        sourceStartFrame: 0,
        sourceEndFrame: 100,
        payload: ASRCompletedEventPayload(
            text: "一つ目",
            detectedLanguage: "ja",
            engine: "qwen3-asr",
            model: "test"
        )
    ))

    if completeSecond {
        _ = try await writer.append(EventDraft(
            eventType: "asr.completed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            segmentationRunID: segmentationRunID,
            segmentID: "seg_000002",
            sourceStartFrame: 100,
            sourceEndFrame: 200,
            payload: ASRCompletedEventPayload(
                text: "二つ目",
                detectedLanguage: "ja",
                engine: "qwen3-asr",
                model: "test"
            )
        ))
    }

    if markRunSuccessful {
        _ = try await writer.append(EventDraft(
            eventType: "processing.run.completed",
            sessionID: sessionID,
            processingRunID: asrRunID,
            payload: ProcessingRunCompletedPayload(
                stage: .asr,
                succeeded: true,
                completedCount: 2,
                failedCount: 0
            )
        ))
    }

    return try SessionRecovery.recoverJSONL(
        Data(contentsOf: sessionURL.appending(path: "events.jsonl"))
    )
}

@Test
func eventLogRecoveryFindsOnlyStillPendingASRSegments() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let recovered = try await makeRecoveryEventLog(
        at: root,
        completeSecond: false,
        markRunSuccessful: false
    )
    let plan = try EventLogRecoveryAnalyzer().latestASRPlan(
        lines: recovered.lines
    )

    #expect(plan?.segmentationRunID == "seg_run_recovery")
    #expect(plan?.asrRunID == "asr_run_recovery")
    #expect(plan?.pendingSegments.map(\.segmentID) == ["seg_000002"])
    #expect(plan?.runSucceeded == false)

    let completedEvents = plan?.transcriptEvents.filter {
        if case .asrCompleted = $0.kind { return true }
        return false
    }
    #expect(completedEvents?.count == 1)
}

@Test
func eventLogRecoveryRecognizesCompletedUnselectedRun() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let recovered = try await makeRecoveryEventLog(
        at: root,
        completeSecond: true,
        markRunSuccessful: true
    )
    let plan = try EventLogRecoveryAnalyzer().latestASRPlan(
        lines: recovered.lines
    )

    #expect(plan?.pendingSegments.isEmpty == true)
    #expect(plan?.runSucceeded == true)
    #expect(plan?.hasFailures == false)
    #expect(plan?.transcriptEvents.count == 4)
}
