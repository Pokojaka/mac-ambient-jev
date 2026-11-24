import Foundation

public enum ProcessingLogStateError: Error, LocalizedError, Equatable, Sendable {
    case duplicateSuccessfulResult(segmentID: String)
    case missingGeneration
    case incompatibleSettings
    case incompleteRecognition

    public var errorDescription: String? {
        switch self {
        case .duplicateSuccessfulResult(let segmentID):
            "イベントログに区間 \(segmentID) の成功結果が重複しています"
        case .missingGeneration:
            "イベントログにパイプライン世代がありません"
        case .incompatibleSettings:
            "保存されたパイプライン設定が現在の設定と一致しません"
        case .incompleteRecognition:
            "音声認識が完了していないか、入力フレーム数が一致しません"
        }
    }
}

public struct ProcessingLogState: Sendable {
    public let generation: PipelineGeneration
    public let runs: ActiveRuns
    public let segmentationRunID: String
    public let asrRunID: String
    public let segments: [SegmentReference]
    public let pendingSince: [String: Date]
    public let events: [TranscriptEvent]
    public let runStarts: [ProcessingStage: RunProvenance]
    public let runCompletions: [ProcessingStage: ProcessingRunCompletedPayload]
    public let consumedFrames: Int64
    public let sealedFrames: Int64?
    public let segmentationCompleted: Bool
    public let hasUnresolvedASRFailure: Bool
    public var recognitionCompleted: Bool {
        sealedFrames != nil && segmentationCompleted
            && runCompletions[.segmentation] != nil && runCompletions[.asr] != nil
    }
    public init?(eventsURL: URL, sessionID: UUID) throws {
        let data = try SessionWriter.readDurableLog(eventsURL: eventsURL)
        let recovered = try SessionRecovery.recoverJSONL(data)
        try self.init(lines: recovered.lines, sessionID: sessionID)
    }

    public init?(lines: [Data], sessionID: UUID) throws {
        let decoded = try EventLogLine.decode(lines)
        guard let log = try GenerationEventLog(lines: decoded, sessionID: sessionID) else { return nil }
        try self.init(log: log, sessionID: sessionID)
    }

    internal init(log: GenerationEventLog, sessionID: UUID) throws {
        guard let segmentationRunID = log.runs.segmentation, let asrRunID = log.runs.asr else {
            throw ProcessingLogStateError.missingGeneration
        }

        var segments: [String: SegmentReference] = [:]
        var orderedSegments: [SegmentReference] = []
        var pendingSince: [String: Date] = [:]
        var events: [TranscriptEvent] = []
        var successfulSegmentIDs: Set<String> = []
        var failedSegmentIDs: Set<String> = []
        var runStarts: [ProcessingStage: RunProvenance] = [:]
        var runCompletions: [ProcessingStage: ProcessingRunCompletedPayload] = [:]
        var consumedFrames: Int64 = 0
        var sealedFrames: Int64?
        var segmentationCompleted = false

        for line in log.lines {
            switch line.header.eventType {
            case "segmentation.progress", "segmentation.input.sealed", "segmentation.completed":
                guard line.header.segmentationRunID == segmentationRunID else { continue }
                guard runStarts[.segmentation] != nil else { throw Self.invalidSegmentationRecord(line) }
                guard line.header.sessionID == sessionID else { throw Self.invalidSegmentationRecord(line) }
                switch line.header.eventType {
                case "segmentation.progress":
                    let body: PayloadBody<SegmentationProgressPayload>
                    do { body = try line.body(PayloadBody<SegmentationProgressPayload>.self) }
                    catch { throw Self.invalidSegmentationRecord(line) }
                    let cursor = body.payload.consumedFrames
                    guard !segmentationCompleted, cursor >= 0, cursor.isMultiple(of: 4096), cursor > consumedFrames,
                          sealedFrames.map({ cursor <= $0 }) ?? true else {
                        throw Self.invalidSegmentationRecord(line)
                    }
                    consumedFrames = cursor
                case "segmentation.input.sealed":
                    let body: PayloadBody<SegmentationInputSealedPayload>
                    do { body = try line.body(PayloadBody<SegmentationInputSealedPayload>.self) }
                    catch { throw Self.invalidSegmentationRecord(line) }
                    let count = body.payload.frameCount
                    guard sealedFrames == nil, count >= 0, count >= consumedFrames,
                          orderedSegments.allSatisfy({ $0.endFrame <= count }) else {
                        throw Self.invalidSegmentationRecord(line)
                    }
                    sealedFrames = count
                default:
                    let body: PayloadBody<SegmentationCompletedPayload>
                    do { body = try line.body(PayloadBody<SegmentationCompletedPayload>.self) }
                    catch { throw Self.invalidSegmentationRecord(line) }
                    let cursor = body.payload.consumedFrames
                    guard !segmentationCompleted, sealedFrames == cursor, body.payload.segmentCount >= 0,
                          body.payload.segmentCount == orderedSegments.count, cursor >= consumedFrames else {
                        throw Self.invalidSegmentationRecord(line)
                    }
                    consumedFrames = cursor
                    segmentationCompleted = true
                }
            case "segment.created":
                let selectedRunID = try line.requiredSegmentationRunID()
                guard selectedRunID == segmentationRunID else { continue }
                guard runStarts[.segmentation] != nil, !segmentationCompleted else {
                    throw Self.invalidSegmentationRecord(line)
                }
                guard line.header.sessionID == sessionID else { throw line.malformed }
                let envelope: EventEnvelope<SegmentCreatedPayload>
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    envelope = try decoder.decode(EventEnvelope<SegmentCreatedPayload>.self, from: line.data)
                } catch { throw line.malformed }
                guard let segmentID = envelope.segmentID, Self.nonblank(segmentID),
                      SegmentReference.isValid(envelope.payload.speechRanges),
                      let firstRange = envelope.payload.speechRanges.first,
                      let lastRange = envelope.payload.speechRanges.last,
                      envelope.sourceStartFrame == firstRange.lowerBound,
                      envelope.sourceEndFrame == lastRange.upperBound,
                      segments[segmentID] == nil,
                      orderedSegments.last.map({ $0.endFrame <= firstRange.lowerBound }) ?? true else {
                    throw Self.invalidSegmentationRecord(line)
                }
                guard sealedFrames.map({ lastRange.upperBound <= $0 }) ?? true else {
                    throw Self.invalidSegmentationRecord(line)
                }
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

            case "asr.completed", "asr.failed":
                let runID = try line.requiredRunID()
                guard runID == asrRunID else { continue }
                guard runStarts[.asr] != nil, runCompletions[.asr] == nil else { throw line.malformed }
                let selectedSegmentationRunID = try line.requiredSegmentationRunID()
                guard selectedSegmentationRunID == segmentationRunID,
                      line.header.sessionID == sessionID,
                      let segmentID = line.header.segmentID,
                      Self.nonblank(segmentID), let segment = segments[segmentID],
                      segment.segmentationRunID == selectedSegmentationRunID else { throw line.malformed }
                if line.header.eventType == "asr.completed" {
                    let body = try line.body(ASRCompletedBody.self)
                    guard body.segmentID == segmentID,
                          body.outcome == ASRRecognitionOutcome(text: body.text) else {
                        throw EventLogTranscriptReaderError.asrOutcomeMismatch(eventSeq: line.header.eventSeq)
                    }
                    guard successfulSegmentIDs.insert(segmentID).inserted else {
                        throw ProcessingLogStateError.duplicateSuccessfulResult(segmentID: segmentID)
                    }
                    events.append(.asrCompleted(
                        seq: line.header.eventSeq, runID: runID, segmentationRunID: selectedSegmentationRunID,
                        segmentID: segmentID, text: body.text, detectedLanguage: body.detectedLanguage
                    ))
                } else {
                    guard !successfulSegmentIDs.contains(segmentID) else { throw line.malformed }
                    _ = try line.body(PayloadBody<ASRFailedEventPayload>.self)
                    failedSegmentIDs.insert(segmentID)
                }

            case "processing.run.started":
                let runID = try line.requiredRunID()
                let stage: ProcessingStage
                let expectedProvenance: RunProvenance
                if runID == segmentationRunID {
                    stage = .segmentation
                    expectedProvenance = log.generation.segmentationProvenance
                } else if runID == asrRunID {
                    stage = .asr
                    expectedProvenance = log.generation.asrProvenance
                } else {
                    continue
                }
                guard line.header.sessionID == sessionID else { throw line.malformed }
                let body = try line.body(PayloadBody<ProcessingRunStartedPayload>.self).payload
                guard body.stage == stage, body.provenance == expectedProvenance,
                      runStarts[stage] == nil else { throw line.malformed }
                runStarts[stage] = body.provenance

            case "processing.run.completed":
                let runID = try line.requiredRunID()
                let stage: ProcessingStage
                if runID == segmentationRunID { stage = .segmentation }
                else if runID == asrRunID { stage = .asr }
                else { continue }
                guard line.header.sessionID == sessionID else { throw line.malformed }
                let payload = try line.body(PayloadBody<ProcessingRunCompletedPayload>.self).payload
                guard payload.stage == stage, payload.succeeded, payload.failedCount == 0,
                      runStarts[stage] != nil, runCompletions[stage] == nil else { throw line.malformed }
                let expectedCount: Int
                switch stage {
                case .segmentation:
                    guard segmentationCompleted else { throw line.malformed }
                    expectedCount = orderedSegments.count
                case .asr:
                    guard segmentationCompleted, successfulSegmentIDs.count == orderedSegments.count else {
                        throw line.malformed
                    }
                    expectedCount = successfulSegmentIDs.count
                case .clauseBoundary, .contentPriority:
                    throw line.malformed
                }
                guard payload.completedCount == expectedCount else { throw line.malformed }
                runCompletions[stage] = payload

            default:
                continue
            }
        }

        self.generation = log.generation
        self.runs = log.runs
        self.segmentationRunID = segmentationRunID
        self.asrRunID = asrRunID
        self.segments = orderedSegments
        self.pendingSince = pendingSince
        self.events = events
        self.runStarts = runStarts
        self.runCompletions = runCompletions
        self.consumedFrames = consumedFrames
        self.sealedFrames = sealedFrames
        self.segmentationCompleted = segmentationCompleted
        self.hasUnresolvedASRFailure = !failedSegmentIDs.subtracting(successfulSegmentIDs).isEmpty
    }

    public func validateRecognitionCompletion(frameCount: Int64) throws {
        guard recognitionCompleted, sealedFrames == frameCount else {
            throw ProcessingLogStateError.incompleteRecognition
        }
    }

    private static func nonblank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func invalidSegmentationRecord(_ line: EventLogLine) -> SegmentationConsistencyError {
        .invalidRecord(eventSeq: line.header.eventSeq)
    }
}
