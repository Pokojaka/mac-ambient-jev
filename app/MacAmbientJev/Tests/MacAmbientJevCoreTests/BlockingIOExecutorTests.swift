import Foundation
import Testing
import MacAmbientJevCore

private final class BlockingIOExecutorTestError: Error, @unchecked Sendable {}

@Test
func detachedTaskReturnsTypedResultAndPropagatesOriginalErrorIdentity() async throws {
    let successfulTask = Task.detached(executorPreference: BlockingIOExecutor.shared) { () -> Int in
        42
    }
    let result = await successfulTask.value
    #expect(result == 42)

    let originalError = BlockingIOExecutorTestError()
    let failingTask = Task.detached(executorPreference: BlockingIOExecutor.shared) { () throws -> Int in
        throw originalError
    }
    do {
        _ = try await failingTask.value
        Issue.record("Expected the detached task to throw")
    } catch {
        #expect((error as? BlockingIOExecutorTestError) === originalError)
    }
}

@Test
func detachedTaskRetainsCancellationContextOnBlockingIOExecutor() async throws {
    let task = Task.detached(executorPreference: BlockingIOExecutor.shared) {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        try Task.checkCancellation()
    }

    do {
        _ = try await task.value
        Issue.record("Expected cancellation to throw")
    } catch is CancellationError {
        // Expected cancellation from the current task context.
    }

    #expect(task.isCancelled)
}
