import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

private enum DiagnosticsTestError: Error {
    case unavailableUsage
    case unavailableInspection
    case unexpectedResult
}

private func availableUsage(_ diagnostics: EngineDiagnosticsResult) throws -> EngineDecisionUsageSnapshot {
    guard case let .available(snapshot) = diagnostics.decisionUsage else {
        throw DiagnosticsTestError.unavailableUsage
    }
    return snapshot
}

private func expectZeroUsage(_ snapshot: EngineDecisionUsageSnapshot) {
    #expect(snapshot.sendCount == 0)
    #expect(snapshot.inputTokens == 0)
    #expect(snapshot.successCount == 0)
    #expect(snapshot.failureCount == 0)
    #expect(snapshot.pendingBoundarySegmentCount == 0)
    #expect(snapshot.pendingPriorityClauseCount == 0)
    #expect(snapshot.boundaryRequests.sendCount == 0)
    #expect(snapshot.boundaryRequests.inputTokens == 0)
    #expect(snapshot.boundaryRequests.successCount == 0)
    #expect(snapshot.boundaryRequests.failureCount == 0)
    #expect(snapshot.priorityRequests.sendCount == 0)
    #expect(snapshot.priorityRequests.inputTokens == 0)
    #expect(snapshot.priorityRequests.successCount == 0)
    #expect(snapshot.priorityRequests.failureCount == 0)
}

private func isAnswered<Response: Sendable>(_ outcome: DecisionRequestOutcome<Response>) -> Bool {
    if case .answered = outcome { true } else { false }
}

private func isFailed<Response: Sendable>(_ outcome: DecisionRequestOutcome<Response>) -> Bool {
    if case .failed = outcome { true } else { false }
}

private func expectUsage(
    _ snapshot: EngineDecisionUsageSnapshot,
    send: Int,
    tokens: Int,
    successes: Int,
    failures: Int,
    pendingBoundary: Int = 0,
    pendingPriority: Int = 0,
    boundarySend: Int,
    boundaryTokens: Int,
    boundarySuccesses: Int,
    boundaryFailures: Int,
    prioritySend: Int,
    priorityTokens: Int,
    prioritySuccesses: Int,
    priorityFailures: Int
) {
    #expect(snapshot.sendCount == send)
    #expect(snapshot.inputTokens == tokens)
    #expect(snapshot.successCount == successes)
    #expect(snapshot.failureCount == failures)
    #expect(snapshot.pendingBoundarySegmentCount == pendingBoundary)
    #expect(snapshot.pendingPriorityClauseCount == pendingPriority)
    #expect(snapshot.boundaryRequests.sendCount == boundarySend)
    #expect(snapshot.boundaryRequests.inputTokens == boundaryTokens)
    #expect(snapshot.boundaryRequests.successCount == boundarySuccesses)
    #expect(snapshot.boundaryRequests.failureCount == boundaryFailures)
    #expect(snapshot.priorityRequests.sendCount == prioritySend)
    #expect(snapshot.priorityRequests.inputTokens == priorityTokens)
    #expect(snapshot.priorityRequests.successCount == prioritySuccesses)
    #expect(snapshot.priorityRequests.failureCount == priorityFailures)
}

@MainActor
@Suite(.timeLimit(.minutes(10)))
struct EngineApplicationDiagnosticsTests {
    @Test
    func preSettingsDiagnosticsAreRealZerosAndReadOnlyCommandsDoNotCountRequests() async throws {
        let inference = try DiagnosticsInferenceProvider()
        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            #expect(try await harness.state().setup == .settingsRequired)

            let initial = try await harness.diagnostics()
            #expect(initial.scope == .engineProcess)
            #expect(initial.automaticInputVolume == .none)
            #expect(initial.thermalMonitoring == .none)
            expectZeroUsage(try availableUsage(initial))

            _ = try await harness.state()
            _ = try await harness.state()
            let repeated = try await harness.diagnostics()
            expectZeroUsage(try availableUsage(repeated))

            let inspection = try await harness.inspectModels()
            guard case let .validated(identity) = inspection.clauseTagger else {
                throw DiagnosticsTestError.unavailableInspection
            }
            #expect(identity.backend == "host-test")
            #expect(identity.modelID == "test-tagger")
            #expect(identity.revision == String(repeating: "a", count: 64))
            #expect(identity.tokenizerSHA256 == String(repeating: "b", count: 64))
            _ = try await harness.inspectModels()
            _ = try await harness.state()
            _ = try await harness.state()

            expectZeroUsage(try availableUsage(try await harness.diagnostics()))
            #expect(inference.calls.count("providerLoad") == 1)
            #expect(inference.calls.count("prepare") == 0)
            #expect(inference.calls.count("makeInference") == 0)
            #expect(inference.calls.count("boundary") == 0)
            #expect(inference.calls.count("priority") == 0)
            #expect(inference.calls.count("asr") == 0)
            #expect(inference.calls.count("diarization") == 0)
        }
    }

    @Test
    func decisionFactoryCountsRequestsAndTokensOnceAndAccumulatesForTheProcess() async throws {
        let inference = try DiagnosticsInferenceProvider()
        inference.setFailurePlan(DiagnosticsDecisionFailurePlan(
            boundaryCallNumbers: [2], priorityCallNumbers: [2]
        ))

        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            try await harness.replaceSettings(try diagnosticsEngineSettings(), expectedRevision: nil)
            try await harness.prepareModels()

            let request = try diagnosticsBoundaryRequest()
            let targets = diagnosticsPriorityTargets()
            #expect(request.candidates.count == 2)
            #expect(targets.count == 2)
            let coordinator = try inference.makeDecisionCoordinator()

            let boundarySuccess = await coordinator.assessBoundaries(request)
            #expect(isAnswered(boundarySuccess))
            let boundaryFailure = await coordinator.assessBoundaries(request)
            #expect(isFailed(boundaryFailure))
            let prioritySuccess = await coordinator.classifyPriorities(targets)
            #expect(isAnswered(prioritySuccess))
            let priorityFailure = await coordinator.classifyPriorities(targets)
            #expect(isFailed(priorityFailure))

            let afterFourCalls = try availableUsage(try await harness.diagnostics())
            expectUsage(
                afterFourCalls, send: 4, tokens: 28, successes: 2, failures: 2,
                boundarySend: 2, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 1,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )
            #expect(inference.calls.count("providerLoad") == 1)
            #expect(inference.calls.count("boundary") == 2)
            #expect(inference.calls.count("priority") == 2)

            let sessionID = UUID()
            let boundaryReference = request.source
            let priorityReference = try ClauseReference(boundaryRunID: "boundary-run", clauseID: "clause-1")
            let deferred: Set<DecisionPendingTarget> = [
                .boundary(boundaryReference), .priority(priorityReference)
            ]
            await inference.usageCounter.recordDeferred(sessionID: sessionID, targets: deferred)
            await inference.usageCounter.recordDeferred(sessionID: sessionID, targets: deferred)
            let withPending = try availableUsage(try await harness.diagnostics())
            expectUsage(
                withPending, send: 4, tokens: 28, successes: 2, failures: 2,
                pendingBoundary: 1, pendingPriority: 1,
                boundarySend: 2, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 1,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )

            await inference.usageCounter.clearDeferred(
                sessionID: sessionID, targets: [.priority(priorityReference)]
            )
            let priorityResolved = try availableUsage(try await harness.diagnostics())
            #expect(priorityResolved.pendingBoundarySegmentCount == 1)
            #expect(priorityResolved.pendingPriorityClauseCount == 0)
            #expect(priorityResolved.sendCount == 4)
            #expect(priorityResolved.inputTokens == 28)
            await inference.usageCounter.clearDeferred(
                sessionID: sessionID, targets: [.boundary(boundaryReference)]
            )
            let resolved = try availableUsage(try await harness.diagnostics())
            expectUsage(
                resolved, send: 4, tokens: 28, successes: 2, failures: 2,
                boundarySend: 2, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 1,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )

            // A profile change and repeated preparation replace inference without replacing process usage.
            try await harness.replaceSettings(
                try diagnosticsEngineSettings(asrSize: .large), expectedRevision: 1
            )
            try await harness.prepareModels()
            try await harness.call("models.prepare")
            let afterPreparation = try availableUsage(try await harness.diagnostics())
            expectUsage(
                afterPreparation, send: 4, tokens: 28, successes: 2, failures: 2,
                boundarySend: 2, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 1,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )
            #expect(inference.calls.count("prepare") == 3)
            #expect(inference.calls.count("makeInference") == 3)

            let secondCoordinator = try inference.makeDecisionCoordinator()
            let finalBoundary = await secondCoordinator.assessBoundaries(request)
            #expect(isAnswered(finalBoundary))
            expectUsage(
                try availableUsage(try await harness.diagnostics()),
                send: 5, tokens: 39, successes: 3, failures: 2,
                boundarySend: 3, boundaryTokens: 22, boundarySuccesses: 2, boundaryFailures: 1,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )
            #expect(inference.calls.count("providerLoad") == 1)
            #expect(inference.calls.count("boundary") == 3)

            let freshInference = try DiagnosticsInferenceProvider()
            try await withDiagnosticsHarness(inference: freshInference) { freshHarness in
                try await freshHarness.hello()
                expectZeroUsage(try availableUsage(try await freshHarness.diagnostics()))
                #expect(freshInference.calls.count("boundary") == 0)
                #expect(freshInference.calls.count("priority") == 0)
            }
        }
    }

    @Test
    func usageCollectionFailureIsUnavailableWithJapaneseErrorAndDetails() async throws {
        let inference = try DiagnosticsInferenceProvider()
        inference.failDecisionUsage(with: DiagnosticsUsageFailure())

        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            let diagnostics = try await harness.diagnostics()
            #expect(diagnostics.scope == .engineProcess)
            guard case let .unavailable(failure) = diagnostics.decisionUsage else {
                throw DiagnosticsTestError.unexpectedResult
            }
            #expect(failure.code == .internalError)
            #expect(failure.message.contains("発話文判定の利用状況を取得できません"))
            #expect(failure.message.contains("host-test decision usage collection failure"))
            #expect(!failure.details.isEmpty)
            #expect(failure.details[0].message == "host-test decision usage collection failure")
            #expect(inference.calls.count("boundary") == 0)
            #expect(inference.calls.count("priority") == 0)
        }
    }

    @Test
    func malformedCoreUsageSnapshotIsUnavailableRatherThanZero() async throws {
        let inference = try DiagnosticsInferenceProvider()
        let emptyRequests = DecisionRequestUsageSnapshot(sendCount: 0, inputTokens: 0, successCount: 0, failureCount: 0)
        inference.returnMalformedDecisionUsage(DecisionUsageSnapshot(
            sendCount: 1, inputTokens: 0, successCount: 0, failureCount: 0,
            pendingBoundarySegmentCount: 0, pendingPriorityClauseCount: 0,
            boundaryRequests: emptyRequests, priorityRequests: emptyRequests
        ))

        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            let diagnostics = try await harness.diagnostics()
            guard case let .unavailable(failure) = diagnostics.decisionUsage else {
                throw DiagnosticsTestError.unexpectedResult
            }
            #expect(failure.code == .internalError)
            #expect(failure.message.contains("発話文判定の利用状況を取得できません"))
            #expect(!failure.details.isEmpty)
            #expect(inference.calls.count("boundary") == 0)
            #expect(inference.calls.count("priority") == 0)
        }
    }

    @Test
    func modelInspectionIsValidatedReadOnlyAndPreservesNativeFailureDetails() async throws {
        let inference = try DiagnosticsInferenceProvider()
        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            let beforeSettings = try await harness.inspectModels()
            guard case let .validated(identity) = beforeSettings.clauseTagger else {
                throw DiagnosticsTestError.unavailableInspection
            }
            #expect(identity.backend == "host-test")
            #expect(identity.modelID == "test-tagger")
            #expect(identity.revision == String(repeating: "a", count: 64))
            #expect(identity.tokenizerSHA256 == String(repeating: "b", count: 64))
            _ = try await harness.inspectModels()
            #expect(inference.calls.count("providerLoad") == 1)

            let request = try diagnosticsBoundaryRequest()
            let boundary = await (try inference.makeDecisionCoordinator()).assessBoundaries(request)
            #expect(isAnswered(boundary))
            let priorities = await (try inference.makeDecisionCoordinator()).classifyPriorities(diagnosticsPriorityTargets())
            #expect(isAnswered(priorities))
            let usageBeforeInspection = try availableUsage(try await harness.diagnostics())
            let inspectedAfterCalls = try await harness.inspectModels()
            guard case let .validated(afterCallsIdentity) = inspectedAfterCalls.clauseTagger else {
                throw DiagnosticsTestError.unavailableInspection
            }
            #expect(afterCallsIdentity == identity)
            let usageAfterInspection = try availableUsage(try await harness.diagnostics())
            #expect(usageAfterInspection == usageBeforeInspection)

            let nativeDetail = EngineAdapterError.detail(
                domain: "host-test-native", code: "TAGGER_CORRUPT", message: "native tokenizer metadata detail"
            )
            inference.failInspection(with: EngineAdapterError(
                code: .modelCorrupt,
                message: "句節タグ付けモデルの検証に失敗しました",
                recoveryAction: .prepareModels,
                details: [nativeDetail]
            ))
            let failedInspection = try await harness.inspectModels()
            guard case let .invalid(failure) = failedInspection.clauseTagger else {
                throw DiagnosticsTestError.unexpectedResult
            }
            #expect(failure.code == .modelCorrupt)
            #expect(failure.message == "句節タグ付けモデルの検証に失敗しました")
            #expect(failure.stage == .validatingModels)
            #expect(failure.requestID == nil)
            #expect(failure.sessionID == nil)
            #expect(failure.recoveryAction == .prepareModels)
            #expect(failure.details == [nativeDetail])
            #expect(try availableUsage(try await harness.diagnostics()) == usageBeforeInspection)

            #expect(inference.calls.count("providerLoad") == 1)
            #expect(inference.calls.count("prepare") == 0)
            #expect(inference.calls.count("makeInference") == 0)
            #expect(inference.calls.count("boundary") == 1)
            #expect(inference.calls.count("priority") == 1)
            #expect(inference.calls.count("asr") == 0)
            #expect(inference.calls.count("diarization") == 0)
        }
    }

    @Test
    func importedPipelinePublishesPendingPriorityThenRetryResolvesIt() async throws {
        let inference = try DiagnosticsInferenceProvider()
        inference.setFailurePlan(DiagnosticsDecisionFailurePlan(priorityCallNumbers: [1]))

        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            try await harness.replaceSettings(try diagnosticsEngineSettings(decisions: true), expectedRevision: nil)
            try await harness.prepareModels()

            let fixture = harness.root.appending(path: "tiny-import.wav")
            #expect(FileManager.default.createFile(
                atPath: fixture.path, contents: Data("RIFF-not-decoded-by-the-fake-timeline".utf8)
            ))
            guard case let .sessionImport(imported) = try await harness.call(
                "session.import", payload: "{\"input_path\":\(try diagnosticsJSONString(fixture.path))}"
            ) else {
                throw DiagnosticsTestError.unexpectedResult
            }
            let finalized = try await harness.waitForSession(status: .finalized)
            #expect(finalized.sessionID == imported.sessionID)

            let sessionURL = harness.paths.sessionsRoot.appending(
                path: finalized.folderID, directoryHint: .isDirectory
            )
            let pendingMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
            #expect(pendingMetadata.pendingClauseBoundarySegments.isEmpty)
            #expect(pendingMetadata.pendingContentPriorityClauses.count == 1)
            expectUsage(
                try availableUsage(try await harness.diagnostics()),
                send: 2, tokens: 11, successes: 1, failures: 1,
                pendingPriority: 1,
                boundarySend: 1, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 0,
                prioritySend: 1, priorityTokens: 0, prioritySuccesses: 0, priorityFailures: 1
            )

            try await harness.call("session.retry_decisions", payload: "{\"session_id\":\(try diagnosticsJSONString(imported.sessionID))}")
            let resolvedMetadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
            #expect(resolvedMetadata.pendingClauseBoundarySegments.isEmpty)
            #expect(resolvedMetadata.pendingContentPriorityClauses.isEmpty)
            expectUsage(
                try availableUsage(try await harness.diagnostics()),
                send: 3, tokens: 28, successes: 2, failures: 1,
                boundarySend: 1, boundaryTokens: 11, boundarySuccesses: 1, boundaryFailures: 0,
                prioritySend: 2, priorityTokens: 17, prioritySuccesses: 1, priorityFailures: 1
            )
            #expect(inference.calls.count("boundary") == 1)
            #expect(inference.calls.count("priority") == 2)
        }
    }

    @Test
    func importedPipelinePublishesPendingBoundaryWhenBoundaryInferenceFails() async throws {
        let inference = try DiagnosticsInferenceProvider()
        inference.setFailurePlan(DiagnosticsDecisionFailurePlan(boundaryCallNumbers: [1]))

        try await withDiagnosticsHarness(inference: inference) { harness in
            try await harness.hello()
            try await harness.replaceSettings(try diagnosticsEngineSettings(decisions: true), expectedRevision: nil)
            try await harness.prepareModels()

            let fixture = harness.root.appending(path: "tiny-boundary-import.wav")
            #expect(FileManager.default.createFile(
                atPath: fixture.path, contents: Data("RIFF-not-decoded-by-the-fake-timeline".utf8)
            ))
            guard case let .sessionImport(imported) = try await harness.call(
                "session.import", payload: "{\"input_path\":\(try diagnosticsJSONString(fixture.path))}"
            ) else {
                throw DiagnosticsTestError.unexpectedResult
            }
            let finalized = try await harness.waitForSession(status: .finalized)
            #expect(finalized.sessionID == imported.sessionID)

            let sessionURL = harness.paths.sessionsRoot.appending(
                path: finalized.folderID, directoryHint: .isDirectory
            )
            let metadata = try #require(try ProcessingMetadataStore(sessionURL: sessionURL).load())
            #expect(metadata.pendingClauseBoundarySegments.count == 1)
            #expect(metadata.pendingContentPriorityClauses.isEmpty)
            expectUsage(
                try availableUsage(try await harness.diagnostics()),
                send: 1, tokens: 0, successes: 0, failures: 1,
                pendingBoundary: 1,
                boundarySend: 1, boundaryTokens: 0, boundarySuccesses: 0, boundaryFailures: 1,
                prioritySend: 0, priorityTokens: 0, prioritySuccesses: 0, priorityFailures: 0
            )
            #expect(inference.calls.count("boundary") == 1)
            #expect(inference.calls.count("priority") == 0)
        }
    }
}
