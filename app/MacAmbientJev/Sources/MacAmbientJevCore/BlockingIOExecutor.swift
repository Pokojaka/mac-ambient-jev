import Foundation

/// An executor for synchronous blocking I/O.
///
/// Each scheduled job runs on a dedicated OS thread rather than a cooperative
/// thread-pool worker. Use `Task.detached(executorPreference: BlockingIOExecutor.shared)`
/// for blocking work. Execution retains Swift task context for cancellation
/// boundaries and does not serialize unrelated jobs.
public final class BlockingIOExecutor: TaskExecutor, Sendable {
    public static let shared = BlockingIOExecutor()

    private init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        Thread.detachNewThread { [self] in
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}
