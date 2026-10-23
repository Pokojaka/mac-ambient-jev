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

/// A synchronous blocking loop that ends only when its task is cancelled, like chunked file work.
private func blockUntilCancelled(signalling entered: AsyncStream<Void>.Continuation) -> Bool {
    entered.yield()
    while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
    return Task.isCancelled
}

@Test(.timeLimit(.minutes(10)))
func cancellingTheAwaitingParentReachesTheBlockingClosure() async throws {
    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    let parent = Task { () -> Bool in
        let work = Task.detached(executorPreference: BlockingIOExecutor.shared) {
            blockUntilCancelled(signalling: enteredContinuation)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
    for await _ in entered { break }
    parent.cancel()
    #expect(await parent.value)
}
