import Foundation

public enum RecoverableAudioSource: Sendable, Equatable {
    case processingTimeline(AudioCheckpoint)
    case importedOriginal(URL)
}

public enum RecoverableProcessingAction: Sendable, Equatable {
    case reprocess
    case resumeASR(ASRRecoveryPlan)
    case selectCompletedASR(ASRRecoveryPlan)
    case runDiarization(ASRRecoveryPlan)
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

public struct SessionRecoveryScanner: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
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

        var candidates: [RecoverableSession] = []

        for sessionURL in sessionURLs {
            let values = try sessionURL.resourceValues(
                forKeys: [.isDirectoryKey]
            )
            guard values.isDirectory == true else { continue }

            let manifestURL = sessionURL.appending(path: "session.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                continue
            }

            let manifest = try decodeManifest(at: manifestURL)
            let recoveredLines = try recoverEventLog(sessionURL: sessionURL)
            let latestASRPlan = try EventLogRecoveryAnalyzer().latestASRPlan(
                lines: recoveredLines
            )
            let metadata = try ProcessingMetadataStore(
                sessionURL: sessionURL
            ).load()

            let action: RecoverableProcessingAction?
            if let plan = latestASRPlan {
                if metadata?.activeRuns?.asr == plan.asrRunID {
                    if metadata?.activeRuns?.diarization == nil,
                       plan.pendingSegments.isEmpty,
                       plan.runSucceeded,
                       !plan.hasFailures {
                        action = .runDiarization(plan)
                    } else {
                        action = nil
                    }
                } else if !plan.pendingSegments.isEmpty && !plan.hasFailures {
                    action = .resumeASR(plan)
                } else if plan.pendingSegments.isEmpty
                            && plan.runSucceeded
                            && !plan.hasFailures {
                    action = .selectCompletedASR(plan)
                } else if metadata?.activeRuns?.asr == nil {
                    action = .reprocess
                } else {
                    // A failed reprocessing run must not displace the existing
                    // active run or be retried indefinitely on every launch.
                    action = nil
                }
            } else if metadata?.activeRuns?.asr == nil {
                action = .reprocess
            } else {
                action = nil
            }

            guard let action else { continue }

            if let checkpoint = try loadCheckpoint(sessionURL: sessionURL) {
                candidates.append(
                    RecoverableSession(
                        manifest: manifest,
                        sessionURL: sessionURL,
                        source: .processingTimeline(checkpoint),
                        action: action
                    )
                )
                continue
            }

            if manifest.sourceKind == .importedFile,
               let original = try findOriginalAudio(sessionURL: sessionURL) {
                candidates.append(
                    RecoverableSession(
                        manifest: manifest,
                        sessionURL: sessionURL,
                        source: .importedOriginal(original),
                        action: action
                    )
                )
            }
        }

        return candidates.sorted {
            $0.manifest.createdAt < $1.manifest.createdAt
        }
    }

    private func decodeManifest(at url: URL) throws -> SessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SessionManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private func recoverEventLog(sessionURL: URL) throws -> [Data] {
        let eventsURL = sessionURL.appending(path: "events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            return []
        }

        let recovered = try SessionRecovery.recoverJSONL(
            Data(contentsOf: eventsURL)
        )
        if recovered.droppedIncompleteTail {
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
        let url = sessionURL
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
            .appending(path: DurableAudioWriter.checkpointFilename)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try JSONDecoder().decode(
            AudioCheckpoint.self,
            from: Data(contentsOf: url)
        )
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