import Foundation
import Testing
@testable import MacAmbientJevCore
@testable import MacAmbientJevRuntime

/// Test-only baseline of the full-rebuild actor update: merge all events, materialize all
/// rows, then publish a snapshot. No baseline implementation is shipped in the runtime.
private actor FullRebuildClauseUpdate {
    private var events: [TranscriptEvent]
    private var rows: [MaterializedTranscriptSegment]
    private let original: LiveASRSnapshot
    private let materializer = TranscriptMaterializer(sampleRate: 16_000)

    init(snapshot: LiveASRSnapshot) {
        original = snapshot
        events = snapshot.events
        rows = snapshot.progress.materializedSegments
    }

    func apply(_ additions: [TranscriptEvent]) throws -> LiveASRSnapshot {
        for event in additions {
            switch event.kind {
            case .clauseBoundaryAssessed, .clauseBoundaryPending, .clauseClosed:
                guard event.processingRunID == original.activeRuns.clauseBoundary else { throw LiveASRSessionError.foreignClauseEvent }
            case .contentPriorityAssigned:
                guard event.processingRunID == original.activeRuns.contentPriority else { throw LiveASRSessionError.foreignClauseEvent }
            default: throw LiveASRSessionError.foreignClauseEvent
            }
        }
        let mergedEvents = events + additions
        let mergedRows = try materializer.materialize(events: mergedEvents, activeRuns: original.activeRuns)
        events = mergedEvents
        rows = mergedRows
        return LiveASRSnapshot(events: events, activeRuns: original.activeRuns,
            progress: LiveASRProgress(materializedSegments: rows, completedCount: original.progress.completedCount,
                failedCount: original.progress.failedCount, pendingCount: original.progress.pendingCount), segments: original.segments)
    }
}

private func microseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000_000 + Double(parts.attoseconds) / 1_000_000_000_000
}

private func timingSummary(_ samples: [Double]) -> [String: Double] {
    let ordered = samples.sorted()
    return ["median_us": ordered[ordered.count / 2], "p90_us": ordered[Int(Double(ordered.count - 1) * 0.9)],
            "min_us": ordered[0], "max_us": ordered[ordered.count - 1]]
}

/// Opt in with CLAUSE_INCREMENTAL_BENCHMARK=1. Only temporary audio/event fixtures and
/// injected ASR are used; no models, network, application storage, or devices are used.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CLAUSE_INCREMENTAL_BENCHMARK"] == "1"))
func liveClauseIncrementalBenchmark() async throws {
    let clock = ContinuousClock()
    for count in [40, 400, 2_500] {
        let fixture = try await incrementalLiveFixture(count: count)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initial = await fixture.session.snapshot()
        let boundaryRun = try #require(initial.activeRuns.clauseBoundary)
        let priorityRun = try #require(initial.activeRuns.contentPriority)
        var assembly = ClauseBoundaryAssembly(boundaryRunID: boundaryRun)
        var seed: [TranscriptEvent] = []
        var seq = try #require(initial.events.map(\.eventSeq).max()) + 1
        let initialRows = initial.progress.materializedSegments
        for index in 0..<(count - 21) {
            let row = initialRows[index]
            let next: (SegmentTextReference, String)? = index + 1 < count
                ? (initialRows[index + 1].source, initialRows[index + 1].text) : nil
            let assessment = try incrementalAssessment(source: row.source, text: row.text, next: next)
            seed.append(.clause(seq: seq, runID: boundaryRun, kind: .clauseBoundaryAssessed(assessment)))
            seq += 1
            let delta = try assembly.consume(ClauseAssemblyInput(source: row.source, text: row.text, state: .assessed(assessment)))
            for unit in delta.closed {
                seed.append(.clause(seq: seq, runID: boundaryRun, kind: .clauseClosed(unit)))
                seq += 1
            }
        }
        let seeded = try await fixture.session.applyClauseEvents(seed)
        let full = FullRebuildClauseUpdate(snapshot: seeded)
        #expect(seeded.progress.materializedSegments == (try TranscriptMaterializer(sampleRate: 16_000)
            .materialize(events: seeded.events, activeRuns: seeded.activeRuns)))
        var before: [Double] = []
        var after: [Double] = []
        // One warmup plus twenty measured boundary/closure/priority batches uses
        // identical source and synthetic clause-event histories in both actors.
        for sample in 0..<21 {
            let index = count - 21 + sample
            let row = initialRows[index]
            let next: (SegmentTextReference, String)? = index + 1 < count
                ? (initialRows[index + 1].source, initialRows[index + 1].text) : nil
            let assessment = try incrementalAssessment(source: row.source, text: row.text, next: next)
            let delta = try assembly.consume(ClauseAssemblyInput(source: row.source, text: row.text, state: .assessed(assessment)))
            let unit = try #require(delta.closed.first)
            let payload = try ClausePriorityBatch.pending(references: [unit.reference], reason: .requestFailed, message: "synthetic priority pending")
            let additions = [
                TranscriptEvent.clause(seq: seq, runID: boundaryRun, kind: .clauseBoundaryAssessed(assessment)),
                .clause(seq: seq + 1, runID: boundaryRun, kind: .clauseClosed(unit)),
                .clause(seq: seq + 2, runID: priorityRun, kind: .contentPriorityAssigned(payload)),
            ]
            seq += 3
            let fullStart = clock.now
            let rebuilt = try await full.apply(additions)
            let fullDuration = fullStart.duration(to: clock.now)
            let incrementalStart = clock.now
            let updated = try await fixture.session.applyClauseEvents(additions)
            let incrementalDuration = incrementalStart.duration(to: clock.now)
            if sample > 0 {
                before.append(microseconds(fullDuration))
                after.append(microseconds(incrementalDuration))
            }
            #expect(updated == rebuilt)
        }
        let report: [String: Any] = ["segments": count, "samples": before.count, "update": "boundary_close_priority_batch",
            "full_rebuild": timingSummary(before), "live_incremental": timingSummary(after),
            "median_speedup": timingSummary(before)["median_us"]! / timingSummary(after)["median_us"]!]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("CLAUSE_INCREMENTAL_MEASUREMENT \(String(decoding: json, as: UTF8.self))")
    }
}
