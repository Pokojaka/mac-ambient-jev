import Testing
@testable import MacAmbientJevCore

@Suite("Live latency trace")
struct LiveLatencyTraceTests {
    @Test("summarizes unsorted update delays with nearest-rank percentiles")
    func summarizesUnsortedUpdateDelays() {
        let events = eventsFor(delays: [5, 1, 4, 2, 3])

        let summary = LiveLatencyTrace.summarize(events: events)

        #expect(summary.attemptCount == 5)
        #expect(summary.updatedCount == 5)
        #expect(summary.p50Seconds == 3)
        #expect(summary.p95Seconds == 5)
        #expect(summary.maximumSeconds == 5)
    }

    @Test("counts a failed first snapshot even when a later snapshot updates")
    func countsFailedFirstSnapshot() {
        let events: [LiveLatencyTraceEvent] = [
            .init(utteranceID: "u1", snapshotID: nil, kind: .speechStart, timestampNanoseconds: 10),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .snapshotRequested, timestampNanoseconds: 20),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .asrReturned, timestampNanoseconds: 30, result: .failed),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .snapshotRequested, timestampNanoseconds: 40),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .asrReturned, timestampNanoseconds: 50, result: .nonEmpty),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .viewModelUpdated, timestampNanoseconds: 60)
        ]

        let summary = LiveLatencyTrace.summarize(events: events)

        #expect(summary.attemptCount == 2)
        #expect(summary.failureCount == 1)
        #expect(summary.updatedCount == 1)
        #expect(summary.p50Seconds == 0.00000005)
    }

    @Test("uses nearest-rank P95 at the five sample boundary")
    func nearestRankP95Boundary() {
        let events = eventsFor(delays: [1, 2, 3, 4, 5])

        let summary = LiveLatencyTrace.summarize(events: events)

        #expect(summary.p95Seconds == 5)
    }

    @Test("counts each successful attempt in percentiles but only one updated utterance")
    func measuresUpdatesPerAttempt() {
        let events: [LiveLatencyTraceEvent] = [
            .init(utteranceID: "u1", snapshotID: nil, kind: .speechStart, timestampNanoseconds: 0),
            .init(utteranceID: "u1", snapshotID: nil, kind: .checkpointCommitted, timestampNanoseconds: 500_000_000),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .snapshotRequested, timestampNanoseconds: 1_000_000_000),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .asrStarted, timestampNanoseconds: 1_100_000_000),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .asrReturned, timestampNanoseconds: 2_500_000_000, result: .nonEmpty),
            .init(utteranceID: "u1", snapshotID: "s1", kind: .viewModelUpdated, timestampNanoseconds: 3_000_000_000),
            .init(utteranceID: "u1", snapshotID: nil, kind: .checkpointCommitted, timestampNanoseconds: 4_000_000_000),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .snapshotRequested, timestampNanoseconds: 4_100_000_000),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .asrStarted, timestampNanoseconds: 4_200_000_000),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .asrReturned, timestampNanoseconds: 4_500_000_000, result: .nonEmpty),
            .init(utteranceID: "u1", snapshotID: "s2", kind: .viewModelUpdated, timestampNanoseconds: 5_000_000_000)
        ]

        let summary = LiveLatencyTrace.summarize(events: events)

        #expect(summary.attemptCount == 2)
        #expect(summary.utteranceCount == 1)
        #expect(summary.updatedCount == 1)
        #expect(summary.p50Seconds == 3)
        #expect(summary.p95Seconds == 5)
        #expect(summary.stageSummaries[.speechStartToCheckpoint]?.p50Seconds == 0.5)
        #expect(summary.stageSummaries[.checkpointToSnapshot]?.p50Seconds == 0.1)
        #expect(summary.stageSummaries[.snapshotToASRStart]?.p50Seconds == 0.1)
        #expect(summary.stageSummaries[.asrToReturn]?.p50Seconds == 0.3)
        #expect(summary.stageSummaries[.returnToViewModel]?.p50Seconds == 0.5)
    }

    @Test("counts failed attempts in the percentile denominator")
    func failedAttemptsStayInPercentileDenominator() {
        let failures = (0..<99).flatMap { index -> [LiveLatencyTraceEvent] in
            [
                .init(utteranceID: "f\(index)", snapshotID: nil, kind: .speechStart, timestampNanoseconds: 0),
                .init(utteranceID: "f\(index)", snapshotID: "s", kind: .snapshotRequested, timestampNanoseconds: 1),
                .init(utteranceID: "f\(index)", snapshotID: "s", kind: .asrReturned, timestampNanoseconds: 2, result: .failed)
            ]
        }

        let summary = LiveLatencyTrace.summarize(events: eventsFor(delays: [1]) + failures)

        #expect(summary.attemptCount == 100)
        #expect(summary.p50Seconds == nil)
        #expect(summary.p95Seconds == nil)
    }

    @Test("reports P95 from successes when an empty attempt falls above the rank")
    func emptyAttemptAboveP95Rank() {
        let empty: [LiveLatencyTraceEvent] = [
            .init(utteranceID: "e", snapshotID: nil, kind: .speechStart, timestampNanoseconds: 0),
            .init(utteranceID: "e", snapshotID: "s", kind: .snapshotRequested, timestampNanoseconds: 1),
            .init(utteranceID: "e", snapshotID: "s", kind: .asrReturned, timestampNanoseconds: 2, result: .empty)
        ]

        let summary = LiveLatencyTrace.summarize(
            events: eventsFor(delays: Array(1...19)) + empty
        )

        #expect(summary.p50Seconds == 10)
        #expect(summary.attemptCount == 20)
        #expect(summary.emptyCount == 1)
        #expect(summary.p95Seconds == 19)

        let secondEmpty: [LiveLatencyTraceEvent] = [
            .init(utteranceID: "e", snapshotID: "s2", kind: .snapshotRequested, timestampNanoseconds: 3),
            .init(utteranceID: "e", snapshotID: "s2", kind: .asrReturned, timestampNanoseconds: 4, result: .empty)
        ]
        let unanswered = LiveLatencyTrace.summarize(
            events: eventsFor(delays: Array(1...19)) + empty + secondEmpty
        )
        #expect(unanswered.attemptCount == 21)
        #expect(unanswered.emptyCount == 2)
        #expect(unanswered.p95Seconds == nil)
    }

    @Test("failed and successful retries on one utterance each occupy an attempt rank")
    func retryAttemptPercentileDenominator() {
        let retry: [LiveLatencyTraceEvent] = [
            .init(utteranceID: "retry", snapshotID: nil, kind: .speechStart, timestampNanoseconds: 0),
            .init(utteranceID: "retry", snapshotID: "failed", kind: .snapshotRequested, timestampNanoseconds: 1),
            .init(utteranceID: "retry", snapshotID: "failed", kind: .asrReturned, timestampNanoseconds: 2, result: .failed),
            .init(utteranceID: "retry", snapshotID: "success1", kind: .snapshotRequested, timestampNanoseconds: 3),
            .init(utteranceID: "retry", snapshotID: "success1", kind: .asrReturned, timestampNanoseconds: 4_000_000_000, result: .nonEmpty),
            .init(utteranceID: "retry", snapshotID: "success1", kind: .viewModelUpdated, timestampNanoseconds: 4_000_000_000),
            .init(utteranceID: "retry", snapshotID: "success2", kind: .snapshotRequested, timestampNanoseconds: 4_000_000_001),
            .init(utteranceID: "retry", snapshotID: "success2", kind: .asrReturned, timestampNanoseconds: 5_000_000_000, result: .nonEmpty),
            .init(utteranceID: "retry", snapshotID: "success2", kind: .viewModelUpdated, timestampNanoseconds: 5_000_000_000)
        ]
        let summary = LiveLatencyTrace.summarize(events: eventsFor(delays: [1, 2, 3]) + retry)

        #expect(summary.attemptCount == 6)
        #expect(summary.utteranceCount == 4)
        #expect(summary.updatedCount == 4)
        #expect(summary.failureCount == 1)
        #expect(summary.noViewModelUpdateCount == 1)
        #expect(summary.p50Seconds == 3)
        #expect(summary.p95Seconds == nil)
        #expect(summary.maximumSeconds == 5)
    }

    private func eventsFor(delays: [UInt64]) -> [LiveLatencyTraceEvent] {
        var events: [LiveLatencyTraceEvent] = []
        for (index, delay) in delays.enumerated() {
            let utteranceID = "u\(index)"
            let snapshotID = "s\(index)"
            let start: UInt64 = 1_000_000_000
            let requestedAt = start + 1
            let completedAt = start + delay * 1_000_000_000
            events.append(LiveLatencyTraceEvent(
                utteranceID: utteranceID,
                snapshotID: nil,
                kind: .speechStart,
                timestampNanoseconds: start
            ))
            events.append(LiveLatencyTraceEvent(
                utteranceID: utteranceID,
                snapshotID: snapshotID,
                kind: .snapshotRequested,
                timestampNanoseconds: requestedAt
            ))
            events.append(LiveLatencyTraceEvent(
                utteranceID: utteranceID,
                snapshotID: snapshotID,
                kind: .asrReturned,
                timestampNanoseconds: completedAt,
                result: .nonEmpty
            ))
            events.append(LiveLatencyTraceEvent(
                utteranceID: utteranceID,
                snapshotID: snapshotID,
                kind: .viewModelUpdated,
                timestampNanoseconds: completedAt
            ))
        }
        return events
    }
}
