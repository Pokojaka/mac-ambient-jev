#if os(Windows)
import Foundation
import Testing
import CMiniaudio
import MacAmbientJevCore

private let errorNotFound: Int32 = 1168
private let errorInvalidParameter: Int32 = 87

private func filter(
    sessions: [UInt32], processes: [(UInt32, UInt32)], current: UInt32
) -> (result: Int32, external: [UInt32]) {
    let infos = processes.map { mja_process_info(process_id: $0.0, parent_process_id: $0.1) }
    var external = [UInt32](repeating: 0, count: 16)
    var count: UInt32 = 0
    let result = mja_output_filter_external_pids(
        sessions, UInt32(sessions.count), infos, UInt32(infos.count), current,
        &external, UInt32(external.count), &count
    )
    return (result, Array(external.prefix(Int(count))).sorted())
}

private final class PublisherBox: @unchecked Sendable {
    let state: OpaquePointer
    private let condition = NSCondition()
    private var stopped = false
    private var finished = false

    init(state: OpaquePointer) { self.state = state }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    func stopAndWait() {
        condition.lock()
        stopped = true
        while !finished {
            condition.wait()
        }
        condition.unlock()
    }

    func markFinished() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}

struct WindowsCaptureEnvironmentTests {
    /// The publisher stores a coherent set (all fields derived from one counter). A reader must
    /// always get a coherent set and never a "retry" error, however the publisher is scheduled.
    @Test func testSnapshotIsAlwaysCoherentAndNeverRetries() async throws {
        // Run the stopAndWait join on the dedicated thread executor.
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            var raw: OpaquePointer?
            #expect(mja_environment_state_create(&raw) == 0)
            let state = try #require(raw)
            defer { mja_environment_state_destroy(state) }
            mja_environment_state_publish(state, 1, 2, 1, 0)

            let box = PublisherBox(state: state)
            let publisher = Thread {
                defer { box.markFinished() }
                var value: UInt64 = 2
                while !box.isStopped {
                    mja_environment_state_publish(box.state, value, value + 1, Int32(value & 1), 0)
                    value += 1
                }
            }
            publisher.start()
            // A stop request is not a join; wait for completion before native state is destroyed.
            defer { box.stopAndWait() }

            var incoherent = 0
            var failed = 0
            for _ in 0..<1_000_000 {
                var observed: UInt64 = 0
                var published: UInt64 = 0
                var outputState: Int32 = 0
                var error: Int32 = 0
                mja_environment_state_snapshot(state, &observed, &published, &outputState, &error)
                if error != 0 { failed += 1 }
                if published != observed + 1 || outputState != Int32(observed & 1) { incoherent += 1 }
            }
            #expect(failed == 0)
            #expect(incoherent == 0)
        }
    }

    @Test func testSnapshotOfMissingStateReportsInvalidParameter() {
        var error: Int32 = 0
        mja_environment_state_snapshot(nil, nil, nil, nil, &error)
        #expect(error == errorInvalidParameter)
    }

    @Test func testSessionProcessThatStartedAfterTheSessionListingIsExternal() {
        let processes: [(UInt32, UInt32)] = [(4, 0), (100, 4), (200, 100), (300, 4)]
        let outcome = filter(sessions: [300], processes: processes, current: 100)
        #expect(outcome.result == 0)
        #expect(outcome.external == [300])
    }

    @Test func testSessionProcessThatExitedBeforeTheProcessSnapshotIsSkipped() {
        let processes: [(UInt32, UInt32)] = [(4, 0), (100, 4)]
        let outcome = filter(sessions: [999, 0], processes: processes, current: 100)
        #expect(outcome.result == 0)
        #expect(outcome.external == [0])
    }

    @Test func testOwnProcessAndDescendantsAreExcludedAtAnyDepth() {
        let processes: [(UInt32, UInt32)] = [(4, 0), (100, 4), (200, 100), (210, 200), (300, 4)]
        let outcome = filter(sessions: [100, 200, 210, 300], processes: processes, current: 100)
        #expect(outcome.result == 0)
        #expect(outcome.external == [300])
    }

    @Test func testMissingOwnProcessIsAnInconsistentSnapshot() {
        let outcome = filter(sessions: [300], processes: [(4, 0), (300, 4)], current: 100)
        #expect(outcome.result == errorNotFound)
    }

    @Test func testExternalListLargerThanCapacityIsReportedNotTruncated() {
        let infos = [
            mja_process_info(process_id: 100, parent_process_id: 0),
            mja_process_info(process_id: 7, parent_process_id: 0),
            mja_process_info(process_id: 8, parent_process_id: 0)
        ]
        var external = [UInt32](repeating: 0, count: 1)
        var count: UInt32 = 0
        let result = mja_output_filter_external_pids(
            [0, 7, 8], 3, infos, 3, 100, &external, 1, &count
        )
        #expect(result != 0)
        #expect(count == 3)
    }
}
#endif
