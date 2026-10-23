import Foundation

/// An executor for synchronous blocking work.
///
/// Each scheduled job runs on a new dedicated OS thread rather than a cooperative
/// thread-pool worker. Use it only for a synchronous blocking closure, as in
/// `Task.detached(executorPreference: BlockingIOExecutor.shared) { try blockingCall() }`:
/// every resumption of a task that awaits, yields or sleeps on this executor starts
/// another thread. Execution retains Swift task context for cancellation and does
/// not serialize unrelated jobs.
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
