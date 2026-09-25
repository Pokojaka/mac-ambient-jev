import Foundation

public enum LiveLatencyTraceKind: String, Codable, Sendable, Equatable {
    case speechStart
    case checkpointCommitted
    case snapshotRequested
    case asrStarted
    case asrReturned
    case viewModelUpdated
}

public enum LiveLatencyResult: String, Codable, Sendable, Equatable {
    case nonEmpty
    case empty
    case failed
}

public struct LiveLatencyTraceEvent: Codable, Sendable, Equatable {
    public let utteranceID: String
    public let snapshotID: String?
    public let kind: LiveLatencyTraceKind
    public let timestampNanoseconds: UInt64
    public let result: LiveLatencyResult?

    public init(
        utteranceID: String,
        snapshotID: String?,
        kind: LiveLatencyTraceKind,
        timestampNanoseconds: UInt64,
        result: LiveLatencyResult? = nil
    ) {
        self.utteranceID = utteranceID
        self.snapshotID = snapshotID
        self.kind = kind
        self.timestampNanoseconds = timestampNanoseconds
        self.result = result
    }
}

public struct LiveLatencyTraceSummary: Sendable, Equatable {
    public let attemptCount: Int
    public let utteranceCount: Int
    public let updatedCount: Int
    public let emptyCount: Int
    public let failureCount: Int
    public let noViewModelUpdateCount: Int
    public let utterancesWithoutFirstUpdate: Int
    public let p50Seconds: TimeInterval?
    public let p95Seconds: TimeInterval?
    public let maximumSeconds: TimeInterval?
    public let stageSummaries: [LiveLatencyStage: LiveLatencyStageSummary]

    public init(
        attemptCount: Int,
        utteranceCount: Int,
        updatedCount: Int,
        emptyCount: Int,
        failureCount: Int,
        noViewModelUpdateCount: Int,
        utterancesWithoutFirstUpdate: Int,
        p50Seconds: TimeInterval?,
        p95Seconds: TimeInterval?,
        maximumSeconds: TimeInterval?,
        stageSummaries: [LiveLatencyStage: LiveLatencyStageSummary]
    ) {
        self.attemptCount = attemptCount
        self.utteranceCount = utteranceCount
        self.updatedCount = updatedCount
        self.emptyCount = emptyCount
        self.failureCount = failureCount
        self.noViewModelUpdateCount = noViewModelUpdateCount
        self.utterancesWithoutFirstUpdate = utterancesWithoutFirstUpdate
        self.p50Seconds = p50Seconds
        self.p95Seconds = p95Seconds
        self.maximumSeconds = maximumSeconds
        self.stageSummaries = stageSummaries
    }
}

public enum LiveLatencyStage: String, Codable, Sendable, Equatable, Hashable {
    case speechStartToCheckpoint = "speech_start_to_checkpoint"
    case checkpointToSnapshot = "checkpoint_to_snapshot"
    case snapshotToASRStart = "snapshot_to_asr_start"
    case asrToReturn = "asr_to_return"
    case returnToViewModel = "return_to_view_model"
}

public struct LiveLatencyStageSummary: Codable, Sendable, Equatable {
    public let count: Int
    public let p50Seconds: TimeInterval?
    public let p95Seconds: TimeInterval?
    public let maximumSeconds: TimeInterval?

    public init(
        count: Int,
        p50Seconds: TimeInterval?,
        p95Seconds: TimeInterval?,
        maximumSeconds: TimeInterval?
    ) {
        self.count = count
        self.p50Seconds = p50Seconds
        self.p95Seconds = p95Seconds
        self.maximumSeconds = maximumSeconds
    }
}

/// Collects monotonic timestamps for provisional live transcript attempts.
/// Recording is separate from audio persistence and is safe to call from
/// scheduler, inference, and main-actor callbacks.
public actor LiveLatencyTrace {
    private var events: [LiveLatencyTraceEvent] = []

    public init() {}

    public func record(_ event: LiveLatencyTraceEvent) {
        events.append(event)
    }

    public func recordedEvents() -> [LiveLatencyTraceEvent] {
        events
    }

    public func summary() -> LiveLatencyTraceSummary {
        Self.summarize(events: events)
    }

    public static func summarize(
        events: [LiveLatencyTraceEvent]
    ) -> LiveLatencyTraceSummary {
        struct AttemptKey: Hashable {
            let utteranceID: String
            let snapshotID: String
        }

        struct Attempt {
            var requested = false
            var requestedAt: UInt64?
            var asrStartedAt: UInt64?
            var asrReturnedAt: UInt64?
            var updatedAt: UInt64?
            var result: LiveLatencyResult?
        }

        var speechStarts: [String: UInt64] = [:]
        var checkpoints: [String: [UInt64]] = [:]
        var attempts: [AttemptKey: Attempt] = [:]

        for event in events.sorted(by: {
            $0.timestampNanoseconds < $1.timestampNanoseconds
        }) {
            if event.kind == .speechStart {
                if let current = speechStarts[event.utteranceID] {
                    speechStarts[event.utteranceID] = min(
                        current,
                        event.timestampNanoseconds
                    )
                } else {
                    speechStarts[event.utteranceID] = event.timestampNanoseconds
                }
            }

            if event.kind == .checkpointCommitted {
                checkpoints[event.utteranceID, default: []].append(
                    event.timestampNanoseconds
                )
            }

            guard let snapshotID = event.snapshotID else { continue }
            let key = AttemptKey(
                utteranceID: event.utteranceID,
                snapshotID: snapshotID
            )
            var attempt = attempts[key, default: Attempt()]
            switch event.kind {
            case .snapshotRequested:
                attempt.requested = true
                attempt.requestedAt = event.timestampNanoseconds
            case .asrStarted:
                attempt.asrStartedAt = event.timestampNanoseconds
            case .asrReturned:
                attempt.asrReturnedAt = event.timestampNanoseconds
                attempt.result = event.result
            case .viewModelUpdated:
                attempt.updatedAt = event.timestampNanoseconds
            case .speechStart, .checkpointCommitted:
                break
            }
            attempts[key] = attempt
        }

        let requested = attempts.filter { $0.value.requested }
        var delaysByUtterance: [String: TimeInterval] = [:]
        var emptyCount = 0
        var failureCount = 0
        var noViewModelUpdateCount = 0
        var stageSamples: [LiveLatencyStage: [TimeInterval]] = [:]

        for (key, attempt) in requested {
            if attempt.updatedAt == nil {
                noViewModelUpdateCount += 1
            }

            switch attempt.result {
            case .empty:
                emptyCount += 1
            case .failed:
                failureCount += 1
            case .nonEmpty, .none:
                if let updatedAt = attempt.updatedAt,
                   let speechStart = speechStarts[key.utteranceID],
                   updatedAt >= speechStart {
                    let delay = TimeInterval(updatedAt - speechStart) / 1_000_000_000
                    if let current = delaysByUtterance[key.utteranceID] {
                        delaysByUtterance[key.utteranceID] = min(current, delay)
                    } else {
                        delaysByUtterance[key.utteranceID] = delay
                    }
                }
            }

            guard let requestedAt = attempt.requestedAt,
                  let speechStart = speechStarts[key.utteranceID] else {
                continue
            }
            if let checkpoint = checkpoints[key.utteranceID]?.last(where: {
                $0 >= speechStart && $0 <= requestedAt
            }) {
                appendDuration(
                    from: checkpoint,
                    to: requestedAt,
                    as: .checkpointToSnapshot,
                    into: &stageSamples
                )
            }
            appendDuration(
                from: requestedAt,
                to: attempt.asrStartedAt,
                as: .snapshotToASRStart,
                into: &stageSamples
            )
            appendDuration(
                from: attempt.asrStartedAt,
                to: attempt.asrReturnedAt,
                as: .asrToReturn,
                into: &stageSamples
            )
            appendDuration(
                from: attempt.asrReturnedAt,
                to: attempt.updatedAt,
                as: .returnToViewModel,
                into: &stageSamples
            )
        }

        for (utteranceID, speechStart) in speechStarts {
            if let checkpoint = checkpoints[utteranceID]?.first(where: {
                $0 >= speechStart
            }) {
                appendDuration(
                    from: speechStart,
                    to: checkpoint,
                    as: .speechStartToCheckpoint,
                    into: &stageSamples
                )
            }
        }

        let sorted = delaysByUtterance.values.sorted()
        let stageSummaries = Dictionary(
            uniqueKeysWithValues: stageSamples.map { stage, values in
                (stage, summarizeStage(values))
            }
        )
        return LiveLatencyTraceSummary(
            attemptCount: requested.count,
            utteranceCount: speechStarts.count,
            updatedCount: delaysByUtterance.count,
            emptyCount: emptyCount,
            failureCount: failureCount,
            noViewModelUpdateCount: noViewModelUpdateCount,
            utterancesWithoutFirstUpdate: max(
                0,
                speechStarts.count - delaysByUtterance.count
            ),
            p50Seconds: percentile(sorted, probability: 0.50),
            p95Seconds: percentile(sorted, probability: 0.95),
            maximumSeconds: sorted.last,
            stageSummaries: stageSummaries
        )
    }

    private static func appendDuration(
        from start: UInt64?,
        to end: UInt64?,
        as stage: LiveLatencyStage,
        into samples: inout [LiveLatencyStage: [TimeInterval]]
    ) {
        guard let start, let end, end >= start else { return }
        samples[stage, default: []].append(
            TimeInterval(end - start) / 1_000_000_000
        )
    }

    private static func summarizeStage(
        _ values: [TimeInterval]
    ) -> LiveLatencyStageSummary {
        let sorted = values.sorted()
        return LiveLatencyStageSummary(
            count: sorted.count,
            p50Seconds: percentile(sorted, probability: 0.50),
            p95Seconds: percentile(sorted, probability: 0.95),
            maximumSeconds: sorted.last
        )
    }

    private static func percentile(
        _ sorted: [TimeInterval],
        probability: Double
    ) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int(ceil(probability * Double(sorted.count))))
        return sorted[min(rank - 1, sorted.count - 1)]
    }
}
