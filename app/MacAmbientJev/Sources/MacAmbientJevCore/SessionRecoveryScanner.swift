import Foundation

public enum RecoverableAudioSource: Sendable, Equatable {
    case processingTimeline(AudioCheckpoint)
    case importedOriginal(URL)
}

public enum RecoverableProcessingAction: Sendable, Equatable {
    case finalize
    case reprocess
    case resumeASR(ASRRecoveryPlan)
    case selectCompletedASR(ASRRecoveryPlan)
    case runDiarization(ASRRecoveryPlan)
    case retryContentPriority(segmentIDs: [String])
}

public struct RecoverableSession: Sendable, Equatable {
    public let manifest: SessionManifest
    public let sessionURL: URL
    public let source: RecoverableAudioSource
    public let action: RecoverableProcessingAction

    public init(
        manifest: SessionManifest,
        sessionURL: URL,
        source: RecoverableAudioSource,
        action: RecoverableProcessingAction
    ) {
        self.manifest = manifest
        self.sessionURL = sessionURL
        self.source = source
        self.action = action
    }
}

public enum SessionRecoveryScannerError: Error, Equatable {
    case sessionIDMismatch
    case missingAudio
}

public struct SessionRecoveryScanner: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    public func inspect(sessionID: UUID) throws -> RecoverableSession? {
        let url = sessionsRoot.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try candidate(at: url, repairEventLog: false)
    }

    public func pendingSessions() throws -> [RecoverableSession] {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else {
            return []
        }

        let sessionURLs = try FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return sessionURLs
            .compactMap { try? candidate(at: $0, repairEventLog: true) }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    private func candidate(
        at sessionURL: URL,
        repairEventLog: Bool
    ) throws -> RecoverableSession? {
        let values = try sessionURL.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard values.isDirectory == true else { return nil }

        let manifestURL = sessionURL.appending(path: "session.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let manifest = try decodeManifest(at: manifestURL)
        guard UUID(uuidString: sessionURL.lastPathComponent) == manifest.sessionID else {
            throw SessionRecoveryScannerError.sessionIDMismatch
        }
        let recoveredLines = try recoverEventLog(
            sessionURL: sessionURL,
            repair: repairEventLog
        )
        let analyzer = EventLogRecoveryAnalyzer()
        let latestASRPlan = try analyzer.latestASRPlan(
            lines: recoveredLines
        )
        let metadata = try ProcessingMetadataStore(
            sessionURL: sessionURL
        ).load()
        let activeASRPlan: ASRRecoveryPlan?
        if let activeASRRunID = metadata?.activeRuns?.asr {
            activeASRPlan = try analyzer.asrPlan(
                runID: activeASRRunID,
                lines: recoveredLines
            )
        } else {
            activeASRPlan = nil
        }

        let action: RecoverableProcessingAction?
        if metadata?.finalizationAttempt?.state == .running {
            action = .finalize
        } else if metadata?.finalizationAttempt?.state == .failed {
            action = nil
        } else if let activePlan = activeASRPlan,
           activePlan.pendingSegments.isEmpty,
           activePlan.runSucceeded,
           !activePlan.hasFailures {
            // Scope is the final mandatory local stage. If it was not
            // selected, rerun diarization and all later local stages from
            // the known-good active ASR run. This deliberately trades some
            // duplicate computation for simple, crash-safe recovery.
            if metadata?.activeRuns?.scope == nil {
                action = .runDiarization(activePlan)
            } else {
                let jevState = try JevRetryAnalyzer()
                    .contentPriorityState(
                        lines: recoveredLines
                    )
                let metadataPendingIDs = metadata?
                    .pendingContentPrioritySegmentIDs ?? []
                let pendingPriorityIDs = metadataPendingIDs.isEmpty
                    ? jevState.pendingSegmentIDs
                    : metadataPendingIDs

                if !pendingPriorityIDs.isEmpty {
                    let activePriorityRunID =
                        metadata?.activeRuns?.contentPriority

                    if !jevState.hasAssignments
                        || jevState.latestRunID == activePriorityRunID {
                        action = .retryContentPriority(
                            segmentIDs: pendingPriorityIDs
                        )
                    } else {
                        // A newer priority run exists in the log but was
                        // never selected, which indicates an interrupted
                        // retry. Rebuild a complete fresh run rather than
                        // adopting a possibly partial result.
                        let allSegmentIDs = activePlan
                            .transcriptEvents
                            .compactMap { event -> String? in
                                if case .segmentCreated = event.kind {
                                    return event.segmentID
                                }
                                return nil
                            }
                        action = allSegmentIDs.isEmpty
                            ? nil
                            : .retryContentPriority(
                                segmentIDs: allSegmentIDs
                            )
                    }
                } else {
                    action = nil
                }
            }
        } else if let plan = latestASRPlan {
            if metadata?.activeRuns?.asr == plan.asrRunID {
                action = nil
            } else if plan.pendingSegments.isEmpty
                        && plan.runSucceeded
                        && !plan.hasFailures {
                action = .selectCompletedASR(plan)
            } else if !plan.hasFailures
                        && (!plan.pendingSegments.isEmpty
                            || !plan.asrRunID.hasPrefix("asr_live_")) {
                action = .resumeASR(plan)
            } else if metadata?.activeRuns?.asr == nil {
                action = .reprocess
            } else {
                // A failed reprocessing run must not displace the existing
                // active run or be retried indefinitely on every launch.
                action = nil
            }
        } else if metadata?.activeRuns?.scope != nil {
            action = nil
        } else if metadata?.activeRuns?.asr == nil {
            action = .reprocess
        } else {
            action = nil
        }

        guard let action else { return nil }

        let checkpoint = Result { try loadCheckpoint(sessionURL: sessionURL) }
        let source: RecoverableAudioSource
        if case .success(let checkpoint?) = checkpoint {
            source = .processingTimeline(checkpoint)
        } else if manifest.sourceKind == .importedFile,
                  let original = try findOriginalAudio(sessionURL: sessionURL) {
            source = .importedOriginal(original)
        } else {
            _ = try checkpoint.get()
            throw SessionRecoveryScannerError.missingAudio
        }

        return RecoverableSession(
            manifest: manifest,
            sessionURL: sessionURL,
            source: source,
            action: action
        )
    }

    private func decodeManifest(at url: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SessionManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func recoverEventLog(sessionURL: URL, repair: Bool) throws -> [Data] {
        let eventsURL = sessionURL.appending(path: "events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            return []
        }

        let recovered = try SessionRecovery.recoverJSONL(
            Data(contentsOf: eventsURL)
        )
        if repair && recovered.droppedIncompleteTail {
            try recovered.normalizedData.write(
                to: eventsURL,
                options: .atomic
            )
        }
        return recovered.lines
    }

    private func loadCheckpoint(
        sessionURL: URL
    ) throws -> AudioCheckpoint? {
        let directory = sessionURL
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
        guard let checkpoint = try AudioCheckpoint.loadRecovered(from: directory) else {
            return nil
        }
        try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint)
            .validateChunkFiles()
        return checkpoint
    }

    private func findOriginalAudio(
        sessionURL: URL
    ) throws -> URL? {
        let audioURL = sessionURL.appending(
            path: "audio",
            directoryHint: .isDirectory
        )
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return nil
        }

        return try FileManager.default.contentsOfDirectory(
            at: audioURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .first { url in
            guard url.lastPathComponent == "original"
                    || url.lastPathComponent.hasPrefix("original.")
            else {
                return false
            }

            return (try? url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) == true
        }
    }
}
