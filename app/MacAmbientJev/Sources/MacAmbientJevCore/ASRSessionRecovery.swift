import Foundation

public enum ASRSessionRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case duplicateSuccessfulResult(segmentID: String)

    public var errorDescription: String? {
        switch self {
        case .duplicateSuccessfulResult(let segmentID):
            "イベントログに区間 \(segmentID) の成功結果が重複しています"
        }
    }
}

public struct ASRSessionRecovery: Sendable {
    public let segments: [SegmentReference]
    public let pendingSince: [String: Date]
    public let events: [TranscriptEvent]
    public let runStarted: Bool

    public init(eventsURL: URL, sessionID: UUID, segmentationRunID: String, asrRunID: String) throws {
        let data = try SessionWriter.readDurableLog(eventsURL: eventsURL)
        let recovered = try SessionRecovery.recoverJSONL(data)
        let lines = try EventLogLine.decode(recovered.lines)
        var segments: [String: SegmentReference] = [:]
        var orderedSegments: [SegmentReference] = []
        var pendingSince: [String: Date] = [:]
        var events: [TranscriptEvent] = []
        var successfulSegmentIDs: Set<String> = []
        var runStarted = false

        for line in lines {
            switch line.header.eventType {
            case "segment.created":
                let selectedSegmentationRunID = try line.requiredSegmentationRunID()
                guard selectedSegmentationRunID == segmentationRunID else { continue }
                guard line.header.sessionID == sessionID else { throw line.malformed }
                let envelope: EventEnvelope<SegmentCreatedPayload>
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    envelope = try decoder.decode(EventEnvelope<SegmentCreatedPayload>.self, from: line.data)
                } catch { throw line.malformed }
                guard let segmentID = envelope.segmentID,
                      SegmentReference.isValid(envelope.payload.speechRanges),
                      let firstRange = envelope.payload.speechRanges.first,
                      let lastRange = envelope.payload.speechRanges.last,
                      envelope.sourceStartFrame == firstRange.lowerBound,
                      envelope.sourceEndFrame == lastRange.upperBound,
                      segments[segmentID] == nil else { throw line.malformed }

                let segment = SegmentReference(
                    segmentationRunID: segmentationRunID, segmentID: segmentID,
                    speechRanges: envelope.payload.speechRanges
                )
                segments[segmentID] = segment
                orderedSegments.append(segment)
                pendingSince[segmentID] = envelope.createdAt
                events.append(.segmentCreated(
                    seq: envelope.eventSeq, segmentationRunID: segmentationRunID,
                    segmentID: segmentID, startFrame: segment.startFrame, endFrame: segment.endFrame
                ))

            case "asr.completed":
                let runID = try line.requiredRunID()
                guard runID == asrRunID else { continue }
                let selectedSegmentationRunID = try line.requiredSegmentationRunID()
                guard selectedSegmentationRunID == segmentationRunID,
                      line.header.sessionID == sessionID else { throw line.malformed }
                let body = try line.body(ASRCompletedBody.self)
                guard body.outcome == ASRRecognitionOutcome(text: body.text) else {
                    throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: line.header.eventSeq)
                }
                guard successfulSegmentIDs.insert(body.segmentID).inserted else {
                    throw ASRSessionRecoveryError.duplicateSuccessfulResult(segmentID: body.segmentID)
                }
                events.append(.asrCompleted(
                    seq: line.header.eventSeq, runID: runID, segmentationRunID: selectedSegmentationRunID,
                    segmentID: body.segmentID, text: body.text, detectedLanguage: body.detectedLanguage
                ))

            case "processing.run.started":
                let runID = try line.requiredRunID()
                guard runID == asrRunID else { continue }
                guard line.header.sessionID == sessionID else { throw line.malformed }
                let body = try line.body(PayloadBody<ProcessingRunStartedPayload>.self)
                guard body.payload.stage == .asr, !runStarted else { throw line.malformed }
                runStarted = true

            default:
                continue
            }
        }

        self.segments = orderedSegments
        self.pendingSince = pendingSince
        self.events = events
        self.runStarted = runStarted
    }
}
