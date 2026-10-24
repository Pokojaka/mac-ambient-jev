import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevPortableRuntime
@testable import MacAmbientJevEngineHarness

private actor InspectionStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite struct HarnessPortableInferenceTests {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "HarnessPortableInferenceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func configuration(root: URL) -> PortableProcessingConfiguration {
        PortableProcessingConfiguration(
            sileroModelURL: root.appending(path: "silero.onnx"),
            qwen3ModelDirectory: root.appending(path: "asr", directoryHint: .isDirectory),
            qwen3Size: .small,
            diarizationModelDirectory: root.appending(path: "diarization", directoryHint: .isDirectory),
            clauseTaggerModelDirectory: nil,
            threads: 1
        )
    }

    @Test func inspectionUsesExplicitDirectoryWhenConfigurationHasNoTaggerPath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taggerDirectory = root.appending(path: "explicit-tagger", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: taggerDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: taggerDirectory.appending(path: "ClauseTagger.onnx"), options: [])
        let configuration = configuration(root: root)
        let provider = HarnessPortableInferenceProvider(
            configuration: configuration,
            clauseTaggerModelDirectory: taggerDirectory,
            threads: 1
        )
        let usageBefore = try await provider.decisionUsage()

        do {
            _ = try await provider.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded with a malformed explicit tagger directory")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelCorrupt)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == "clause_tagger")
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }

        let usageAfter = try await provider.decisionUsage()
        #expect(configuration.clauseTaggerModelDirectory == nil)
        #expect(provider.configuration.clauseTaggerModelDirectory == nil)
        #expect(usageBefore == usageAfter)
        #expect(usageAfter.sendCount == 0)
        #expect(usageAfter.inputTokens == 0)
        #expect(usageAfter.successCount == 0)
        #expect(usageAfter.failureCount == 0)
        #expect(usageAfter.pendingBoundarySegmentCount == 0)
        #expect(usageAfter.pendingPriorityClauseCount == 0)
        #expect(usageAfter.boundaryRequests.sendCount == 0)
        #expect(usageAfter.boundaryRequests.inputTokens == 0)
        #expect(usageAfter.boundaryRequests.successCount == 0)
        #expect(usageAfter.boundaryRequests.failureCount == 0)
        #expect(usageAfter.priorityRequests.sendCount == 0)
        #expect(usageAfter.priorityRequests.inputTokens == 0)
        #expect(usageAfter.priorityRequests.successCount == 0)
        #expect(usageAfter.priorityRequests.failureCount == 0)
    }

    @Test func missingExplicitInspectionDirectoryHasModelDetails() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingDirectory = root.appending(path: "not-installed", directoryHint: .isDirectory)
        let configuration = configuration(root: root)
        let provider = HarnessPortableInferenceProvider(
            configuration: configuration,
            clauseTaggerModelDirectory: missingDirectory,
            threads: 1
        )

        do {
            _ = try await provider.inspectClauseTagger()
            Issue.record("inspection unexpectedly succeeded without an explicit model directory")
        } catch let error as EngineAdapterError {
            #expect(error.code == .modelMissing)
            #expect(error.recoveryAction == .prepareModels)
            #expect(error.details.first?.domain == "models")
            #expect(error.details.first?.code == "clause_tagger")
        } catch {
            Issue.record("inspection threw an unexpected error: \(error)")
        }

        #expect(provider.configuration.clauseTaggerModelDirectory == nil)
    }

    @Test func preCancelledInspectionPropagatesCancellation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = HarnessPortableInferenceProvider(
            configuration: configuration(root: root),
            clauseTaggerModelDirectory: root.appending(path: "not-installed", directoryHint: .isDirectory),
            threads: 1
        )
        let gate = InspectionStartGate()
        let task = Task {
            await gate.wait()
            return try await provider.inspectClauseTagger()
        }

        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            Issue.record("pre-cancelled inspection unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("pre-cancelled inspection threw an unexpected error: \(error)")
        }
    }
}
