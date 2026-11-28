import Foundation
import Testing
@testable import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevTestSupport

private final class ControllerReliableWaits: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
        changes.signal()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class ControllerShutdownWaitPasses: @unchecked Sendable {
    let changes = ChangeSignal()
    private let lock = NSLock()
    private var passes: [[UInt64]] = []

    func record(_ requestIDs: [EngineID]) {
        lock.lock()
        passes.append(requestIDs.map(\.value))
        lock.unlock()
        changes.signal()
    }

    func contains(_ expected: [UInt64]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return passes.contains(expected)
    }

    func waitFor(_ requestIDs: [UInt64]) async throws {
        try await changes.wait("shutdown wait pass \(requestIDs)") { contains(requestIDs) }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(10))) struct EngineControllerTests {
    private func hello(_ h: EngineHarness) async throws {
        h.send(1, "hello")
        try await h.waitForOutputs("hello completed") { $0.contains { if case .completed = $0.event { true } else { false } } }
    }

    @Test func readyIsAnnouncedBeforeAnyRequest() async throws {
        let h = EngineHarness()
        h.start()
        try await h.waitForOutputs("ready") { !$0.isEmpty }
        let first = try h.outputs[0]
        guard case .ready = first.event else { Issue.record("first event is not ready"); return }
        #expect(first.requestID == nil)
        h.source.finish()
        #expect(await h.exit() == .inputClosed)
    }

    @Test func helloMustBeFirst() async throws {
        let h = EngineHarness()
        h.start()
        h.send(1, "state.get")
        try await h.waitForOutputs("hello_required") { $0.count >= 2 }
        #expect(try h.events(for: 1) == ["error:hello_required"])
        #expect(h.fake.calls.filter { $0 == "state.get" }.isEmpty)
        h.send(1, "hello")
        try await h.waitForOutputs("hello completed") { $0.count >= 4 }
        #expect(try h.events(for: 1) == ["error:hello_required", "accepted", "completed"])
        h.source.finish()
        _ = await h.exit()
    }

    @Test func helloCompletionHookRunsAfterCompletedIsQueued() async throws {
        let h = EngineHarness()
        let state = try sampleState(revision: 42)
        let emitter = EngineEventEmitter(transport: h.transport)
        h.fake.onHelloDidComplete = { try? emitter.state(state) }
        h.start()
        h.send(1, "hello")

        try await h.waitForOutputs("hello completion and unsolicited state") { outputs in
            outputs.contains { output in
                if case .state = output.event { true } else { false }
            }
        }

        let outputs = try h.outputs
        let completedIndex = try #require(outputs.firstIndex { output in
            output.requestID?.value == 1 && { if case .completed(.hello) = output.event { true } else { false } }()
        })
        let stateIndex = try #require(outputs.firstIndex { output in
            output.requestID == nil && { if case let .state(value) = output.event { value == state } else { false } }()
        })
        #expect(completedIndex < stateIndex)
        #expect(h.fake.helloCompletionCount == 1)

        h.source.finish()
        _ = await h.exit()
    }

    @Test func heldHelloDoesNotCompleteUntilItsHandlerReturns() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["hello"]
        h.start()
        h.send(1, "hello")
        try await h.fake.changes.wait("hello handler to be held") { h.fake.heldCount == 1 }

        var mainActorTaskRan = false
        let mainActorTask = Task { @MainActor in mainActorTaskRan = true }
        await mainActorTask.value
        #expect(mainActorTaskRan)
        #expect(h.fake.helloCompletionCount == 0)

        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await h.waitForOutputs("held hello completion") { outputs in
            outputs.contains { output in
                output.requestID?.value == 1 && { if case .completed(.hello) = output.event { true } else { false } }()
            }
        }
        try await h.fake.changes.wait("held hello completion hook") { h.fake.helloCompletionCount == 1 }
        h.source.finish()
        _ = await h.exit()
    }

    @Test func failingHelloDoesNotRunCompletionHook() async throws {
        let h = EngineHarness()
        h.fake.failingCommands["hello"] = FakeFailure()
        h.start()
        h.send(1, "hello")
        try await h.waitForOutputs("failed hello") { outputs in
            outputs.contains { output in
                output.requestID?.value == 1 && { if case .error = output.event { true } else { false } }()
            }
        }
        #expect(try h.events(for: 1) == ["accepted", "error:internal_error"])
        #expect(h.fake.helloCompletionCount == 0)
        h.source.finish()
        _ = await h.exit()
    }

    @Test func cancelledHeldHelloCannotRunCompletionHookAfterShutdown() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["hello"]
        h.start()
        h.send(1, "hello")
        try await h.fake.changes.wait("hello handler to be held") { h.fake.heldCount == 1 }

        h.send(2, "shutdown")
        #expect(await h.exit() == .shutdownRequested)
        #expect(try h.events(for: 1) == ["accepted", "error:cancelled"])
        #expect(h.fake.helloCompletionCount == 0)

        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(h.fake.helloCompletionCount == 0)
        #expect(try h.events(for: 1) == ["accepted", "error:cancelled"])
        #expect(try h.outputs.filter { output in
            if case .state = output.event { true } else { false }
        }.isEmpty)
    }

    @Test func shutdownPreservesAClaimedTerminalReplyOverGenericCancellation() async throws {
        let h = EngineHarness()
        h.fake.heldAfterTerminalClaimCommands = ["session.reprocess"]
        h.start()
        try await hello(h)
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        try await h.fake.changes.wait("recorded reprocess result before handler returns") {
            h.fake.terminalReplyClaimCount == 1 && h.fake.heldCount == 1
        }

        h.send(3, "shutdown")
        try await h.fake.changes.wait("shutdown handler to run") {
            h.fake.shutdownReasons == [.requested]
        }
        #expect(try h.events(for: 2) == ["accepted"])

        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await h.waitForOutputs("claimed reprocess and shutdown terminals") { outputs in
            let completed: (UInt64) -> Bool = { id in
                outputs.contains { output in
                    output.requestID?.value == id && { if case .completed = output.event { true } else { false } }()
                }
            }
            return completed(2) && completed(3)
        }
        #expect(try h.events(for: 2) == ["accepted", "completed"])
        #expect(try h.events(for: 3) == ["accepted", "completed"])
        #expect(await h.exit() == .shutdownRequested)
    }

    @Test func shutdownWaitsForClaimedReplyWhileItsReliableSendIsSuspended() async throws {
        let reliableWaits = ControllerReliableWaits()
        let sink = ScriptedSink()
        let h = EngineHarness(
            limits: testLimits(maxRecords: 3, reservedRecords: 1), sink: sink,
            onReliableWait: { reliableWaits.record() }
        )
        h.start()
        try await hello(h)
        sink.block()
        h.fake.heldAfterTerminalClaimCommands = ["session.reprocess"]
        h.fake.holdShutdownHandler = true
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        try await h.fake.changes.wait("reprocess result claimed") {
            h.fake.terminalReplyClaimCount == 1 && h.fake.heldCount == 1
        }

        h.send(3, "shutdown")
        try await h.fake.changes.wait("shutdown handler held") { h.fake.shutdownHandlerIsHeld }
        try h.transport.sendReplaceable(.state(try sampleState(revision: 2)), requestID: nil)
        try await h.transport.send(.ready(try sampleReady()), requestID: nil)
        h.fake.releaseAll()
        try await reliableWaits.changes.wait("claimed terminal reply waiting for output space") {
            reliableWaits.value > 0
        }

        h.fake.releaseShutdownHandler()
        sink.release()
        #expect(await h.exit() == .shutdownRequested)
        #expect(try h.events(for: 2) == ["accepted", "completed"])
        #expect(try h.events(for: 3) == ["accepted", "completed"])
        let outputs = try h.outputs
        let reprocessReply = try #require(outputs.firstIndex { output in
            output.requestID?.value == 2 && { if case .completed = output.event { true } else { false } }()
        })
        let shutdownReply = try #require(outputs.firstIndex { output in
            output.requestID?.value == 3 && { if case .completed = output.event { true } else { false } }()
        })
        #expect(reprocessReply < shutdownReply)
        #expect(outputs.filter { output in
            output.requestID?.value == 2 && { if case .completed = output.event { true } else { false } }()
        }.count == 1)
    }

    @Test func cancellationSweepDoesNotReplaceAClaimMadeDuringAnEarlierCancellationSend() async throws {
        let reliableAppendGate = EngineApplicationTestGate()
        let waitPasses = ControllerShutdownWaitPasses()
        let h = EngineHarness(
            limits: testLimits(), admission: .production, sink: ScriptedSink(),
            deadlineClock: ManualWriteDeadlineClock(), onReliableWait: {},
            beforeReliableAppend: { requestID in
                guard requestID?.value == 2 else { return }
                await reliableAppendGate.suspendIfArmed()
            },
            onShutdownWaitPass: { requestIDs in waitPasses.record(requestIDs) }
        )
        h.start()
        try await hello(h)
        h.fake.heldBeforeTerminalClaimRequestIDs = [2, 3]
        h.fake.heldAfterTerminalClaimRequestIDs = [3]
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        h.send(3, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        try await h.fake.changes.wait("both handlers to wait before claiming") {
            h.fake.heldBeforeTerminalClaimIDs == [2, 3]
        }
        await reliableAppendGate.arm()
        h.send(4, "shutdown")
        await reliableAppendGate.waitUntilSuspended()

        h.fake.releaseBeforeTerminalClaim(requestID: 3)
        try await h.fake.changes.wait("request 3 to claim during request 2 cancellation send") {
            h.fake.terminalReplyClaimCount == 1 && h.fake.heldCount == 1
        }
        await reliableAppendGate.release()
        h.fake.releaseBeforeTerminalClaim(requestID: 2)
        try await waitPasses.waitFor([3])
        h.fake.releaseAll()

        #expect(await h.exit() == .shutdownRequested)
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])
        #expect(try h.events(for: 3) == ["accepted", "completed"])
        #expect(try h.events(for: 4) == ["accepted", "completed"])
    }

    @Test func shutdownWaitsForRepliesClaimedWhileAnEarlierReplyIsSending() async throws {
        let reliableAppendGate = EngineApplicationTestGate()
        let waitPasses = ControllerShutdownWaitPasses()
        let h = EngineHarness(
            limits: testLimits(), admission: .production, sink: ScriptedSink(),
            deadlineClock: ManualWriteDeadlineClock(), onReliableWait: {},
            beforeReliableAppend: { requestID in
                guard requestID?.value == 3 else { return }
                await reliableAppendGate.suspendIfArmed()
            },
            onShutdownWaitPass: { requestIDs in waitPasses.record(requestIDs) }
        )
        h.start()
        try await hello(h)
        h.fake.heldAfterTerminalClaimRequestIDs = [2]
        h.fake.heldBeforeTerminalClaimRequestIDs = [3]
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        try await h.fake.changes.wait("request 2 to claim and hold") {
            h.fake.terminalReplyClaimCount == 1 && h.fake.heldCount == 1
        }
        h.send(3, "session.reprocess", payload: "{\"session_id\":\"session-1\"}")
        try await h.fake.changes.wait("request 3 to wait before claiming") {
            h.fake.heldBeforeTerminalClaimIDs.contains(3)
        }
        h.send(4, "shutdown")
        try await waitPasses.waitFor([2])

        await reliableAppendGate.arm()
        h.fake.releaseBeforeTerminalClaim(requestID: 3)
        await reliableAppendGate.waitUntilSuspended()
        h.fake.releaseAll()
        try await waitPasses.waitFor([3])

        let outputsWhileThirdReplyIsGated = try h.outputs
        #expect(!outputsWhileThirdReplyIsGated.contains { output in
            output.requestID?.value == 4 && { if case .completed(.shutdown) = output.event { true } else { false } }()
        })
        await reliableAppendGate.release()

        #expect(await h.exit() == .shutdownRequested)
        let outputs = try h.outputs
        #expect(try h.events(for: 2) == ["accepted", "completed"])
        #expect(try h.events(for: 3) == ["accepted", "completed"])
        #expect(try h.events(for: 4) == ["accepted", "completed"])
        let shutdownReply = try #require(outputs.firstIndex { output in
            output.requestID?.value == 4 && { if case .completed(.shutdown) = output.event { true } else { false } }()
        })
        let request2Replies = outputs.enumerated().filter { _, output in
            output.requestID?.value == 2 && { if case .completed = output.event { true } else { false } }()
        }
        let request3Replies = outputs.enumerated().filter { _, output in
            output.requestID?.value == 3 && { if case .completed = output.event { true } else { false } }()
        }
        #expect(request2Replies.count == 1)
        #expect(request3Replies.count == 1)
        #expect(request2Replies[0].offset < shutdownReply)
        #expect(request3Replies[0].offset < shutdownReply)
    }

    @Test func firstRequestIDMustBeOne() async throws {
        let h = EngineHarness()
        h.start()
        h.send(2, "hello")
        try await h.waitForOutputs("invalid id") { $0.count >= 2 }
        #expect(try h.events(for: 2) == ["error:invalid_request_id"])
        h.source.finish()
        _ = await h.exit()
    }

    @Test func duplicateAndOldRequestIDsAreRejectedWithoutSideEffects() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        h.send(5, "state.get")
        try await h.waitForOutputs("5 completed") { $0.contains { $0.requestID?.value == 5 && { if case .completed = $0.event { true } else { false } }($0) } }
        h.send(5, "state.get")
        h.send(3, "state.get")
        h.send(1, "state.get")
        h.send(6, "state.get")
        try await h.waitForOutputs("6 completed") { $0.contains { $0.requestID?.value == 6 && { if case .completed = $0.event { true } else { false } }($0) } }
        #expect(try h.events(for: 5) == ["accepted", "completed", "error:invalid_request_id"])
        #expect(try h.events(for: 3) == ["error:invalid_request_id"])
        #expect(h.fake.calls.filter { $0 == "state.get" }.count == 2)
        h.source.finish()
        _ = await h.exit()
    }

    @Test func aSecondHelloIsRejected() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        h.send(2, "hello")
        try await h.waitForOutputs("second hello") { $0.contains { $0.requestID?.value == 2 } }
        #expect(try h.events(for: 2) == ["error:invalid_request"])
        h.source.finish()
        _ = await h.exit()
    }

    @Test func everyAdmittedRequestGetsAcceptedThenExactlyOneTerminal() async throws {
        let h = EngineHarness()
        h.fake.failingCommands["session.list"] = try EngineCommandError(
            code: .filesystem, message: "一覧を読めません", stage: .maintenance, sessionID: nil,
            severity: .error, recoveryAction: .retry, details: [], cleanupErrors: []
        )
        h.fake.failingCommands["devices.list"] = FakeFailure()
        h.fake.failingCommands["transcript.read"] = CancellationError()
        h.start()
        try await hello(h)
        h.send(2, "session.list", payload: "{\"cursor\":null,\"limit\":10}")
        h.send(3, "devices.list", payload: "{\"source\":\"microphone\"}")
        h.send(4, "transcript.read", payload: "{\"session_id\":\"s\",\"revision\":null,\"cursor\":null,\"limit\":5}")
        h.send(5, "state.get")
        try await h.waitForOutputs("all terminals") { outputs in
            [2, 3, 4, 5].allSatisfy { id in outputs.contains { $0.requestID?.value == UInt64(id) && !{ if case .accepted = $0.event { true } else { false } }($0) } }
        }
        #expect(try h.events(for: 2) == ["accepted", "error:filesystem"])
        #expect(try h.events(for: 3) == ["accepted", "error:internal_error"])
        #expect(try h.events(for: 4) == ["accepted", "error:cancelled"])
        #expect(try h.events(for: 5) == ["accepted", "completed"])
        let internalFailure = try h.outputs.compactMap { output -> EngineFailure? in
            if output.requestID?.value == 3, case let .error(failure) = output.event { failure } else { nil }
        }.first
        #expect(internalFailure?.details.first?.message.contains("FakeFailure") == true)
        h.source.finish()
        _ = await h.exit()
    }

    @Test func everyCommandRoutesToItsHandler() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        let table: [(String, String, String)] = [
            ("state.get", "{}", "state.get"),
            ("devices.list", "{\"source\":\"system_audio\"}", "devices.list"),
            ("recording.start", "{\"source\":\"microphone\",\"device\":{\"kind\":\"default\"}}", "recording.start"),
            ("recording.stop", "{\"session_id\":\"s\"}", "recording.stop"),
            ("session.import", "{\"input_path\":\"/a.wav\"}", "session.import"),
            ("session.reprocess", "{\"session_id\":\"s\"}", "session.reprocess"),
            ("session.retry_decisions", "{\"session_id\":\"s\"}", "session.retry_decisions"),
            ("session.list", "{\"cursor\":null,\"limit\":1}", "session.list"),
            ("transcript.read", "{\"session_id\":\"s\",\"revision\":null,\"cursor\":null,\"limit\":1}", "transcript.read"),
            ("transcript.watch", "{\"session_id\":\"s\"}", "transcript.watch"),
            ("session.export", "{\"session_id\":\"s\",\"destination_path\":\"/out\"}", "session.export"),
            ("settings.get", "{}", "settings.get"),
            ("models.prepare", "{}", "models.prepare"),
        ]
        for (index, entry) in table.enumerated() {
            h.send(UInt64(index + 2), entry.0, payload: entry.1)
        }
        let settings = try String(decoding: EngineCodec.encodeRequest(EngineRequest(
            version: 1, requestID: EngineID(UInt64(table.count + 2)),
            command: .settingsReplace(EngineSettingsReplacePayload(expectedRevision: EngineID(1), settings: sampleSettings()))
        )), as: UTF8.self)
        h.source.feed(settings)
        try await h.waitForOutputs("all completed") { outputs in
            outputs.filter { if case .completed = $0.event { true } else { false } }.count == table.count + 2
        }
        let results = try h.outputs.compactMap { output -> EngineCommandName? in
            if case let .completed(result) = output.event { result.command } else { nil }
        }
        #expect(results.sorted { $0.rawValue < $1.rawValue } == (table.map { EngineCommandName(rawValue: $0.0)! } + [.hello, .settingsReplace]).sorted { $0.rawValue < $1.rawValue })
        for entry in table { #expect(h.fake.calls.contains(entry.2)) }
        #expect(h.fake.calls.contains("settings.replace"))
        h.source.finish()
        _ = await h.exit()
    }

    @Test func handlerProgressIsCorrelatedToItsRequest() async throws {
        let h = EngineHarness()
        h.fake.progressOnPrepare = true
        h.start()
        try await hello(h)
        h.send(2, "models.prepare")
        try await h.waitForOutputs("prepare completed") { $0.contains { $0.requestID?.value == 2 && { if case .completed = $0.event { true } else { false } }($0) } }
        #expect(try h.events(for: 2) == ["accepted", "progress", "completed"])
        h.source.finish()
        _ = await h.exit()
    }

    @Test func admissionOverflowAnswersBusyAndReservesStopAndShutdown() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["session.reprocess", "recording.stop"]
        h.start()
        try await hello(h)
        for id in 2...15 { h.send(UInt64(id), "session.reprocess", payload: "{\"session_id\":\"s\"}") }
        try await h.fake.changes.wait("14 held") { h.fake.heldCount == 14 }
        h.send(16, "session.reprocess", payload: "{\"session_id\":\"s\"}")
        h.send(17, "recording.stop", payload: "{\"session_id\":\"s\"}")
        h.send(18, "recording.stop", payload: "{\"session_id\":\"s\"}")
        h.send(19, "recording.stop", payload: "{\"session_id\":\"s\"}")
        try await h.waitForOutputs("busy answers") { outputs in
            [16, 19].allSatisfy { id in outputs.contains { $0.requestID?.value == UInt64(id) } }
        }
        #expect(try h.events(for: 16) == ["error:busy"])
        #expect(try h.events(for: 17) == ["accepted"])
        #expect(try h.events(for: 18) == ["accepted"])
        #expect(try h.events(for: 19) == ["error:busy"])
        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await h.waitForOutputs("all terminals") { outputs in
            (2...15).map(UInt64.init).appending(17).appending(18).allSatisfy { id in
                outputs.contains { $0.requestID?.value == id && { if case .completed = $0.event { true } else { false } }($0) }
            }
        }
        for id in (2...15).map(UInt64.init) + [17, 18] {
            #expect(try h.events(for: id) == ["accepted", "completed"])
        }
        h.source.finish()
        _ = await h.exit()
    }

    @Test func shutdownStopsHandlersCancelsInFlightWorkAndExitsZero() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["session.reprocess"]
        h.start()
        try await hello(h)
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"s\"}")
        try await h.fake.changes.wait("held") { h.fake.heldCount == 1 }
        h.send(3, "shutdown")
        let exit = await h.exit()
        #expect(exit == .shutdownRequested)
        #expect(exit.processExitCode == 0)
        #expect(h.fake.shutdownReasons == [.requested])
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])
        #expect(try h.events(for: 3) == ["accepted", "completed"])
        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])
        #expect(h.sink.closed)
    }

    @Test func captureFailureShutsDownCancelsInFlightWorkAndExitsSeven() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["session.reprocess"]
        h.start()
        try await hello(h)
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"s\"}")
        try await h.fake.changes.wait("held") { h.fake.heldCount == 1 }

        let reason = "audio capture device was lost"
        h.transport.captureFailed(reason)
        let exit = await h.exit()

        #expect(exit == .captureFailed(reason))
        #expect(exit.processExitCode == 7)
        #expect(h.fake.shutdownReasons == [.captureFailed])
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])
        h.fake.heldCommands = []
        h.fake.releaseAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])

        let bytes = h.sink.received
        #expect(bytes.last == 0x0A)
        #expect(!bytes.contains(0x0D))
        let outputs = try ScriptedSink.decodeOutputs(bytes)
        #expect(outputs.map(\.sequence.value) == Array(1...UInt64(outputs.count)))
        #expect(outputs.contains { $0.requestID?.value == 2 && { if case .error = $0.event { true } else { false } }($0) })
        #expect(h.sink.closed)
    }

    @Test func aFailingShutdownHandlerIsAnExplicitNonZeroExit() async throws {
        let h = EngineHarness()
        h.fake.shutdownError = FakeFailure()
        h.start()
        try await hello(h)
        h.send(2, "shutdown")
        let exit = await h.exit()
        guard case .shutdownFailed = exit else { Issue.record("exit was \(exit)"); return }
        #expect(exit.processExitCode != 0)
        #expect(try h.events(for: 2) == ["accepted", "error:internal_error"])
    }

    @Test func endOfInputIsASafeDisconnectShutdown() async throws {
        let h = EngineHarness()
        h.fake.heldCommands = ["session.reprocess"]
        h.start()
        try await hello(h)
        h.send(2, "session.reprocess", payload: "{\"session_id\":\"s\"}")
        try await h.fake.changes.wait("held") { h.fake.heldCount == 1 }
        h.source.finish()
        #expect(await h.exit() == .inputClosed)
        #expect(h.fake.shutdownReasons == [.inputClosed])
        #expect(try h.events(for: 2) == ["accepted", "error:cancelled"])
    }

    @Test func aPartialFinalLineIsAProtocolErrorExit() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        h.source.feed("{\"version\":1,\"request_id\":\"2\"")
        h.source.finish()
        let exit = await h.exit()
        guard case .protocolViolation = exit else { Issue.record("exit was \(exit)"); return }
        #expect(exit.processExitCode != 0)
        #expect(h.fake.shutdownReasons == [.protocolError])
        let last = try #require(h.outputs.last)
        guard case let .error(failure) = last.event else { Issue.record("last event is not an error"); return }
        #expect(failure.code == .invalidRequest)
        #expect(failure.severity == .fatal)
        #expect(last.requestID == nil)
    }

    @Test func aMalformedRequestIsRejectedAndTheConnectionContinues() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        h.send(2, "no.such.command")
        h.source.feed(requestLine(3, "state.get", payload: "{\"extra\":1}"))
        h.send(4, "state.get")
        try await h.waitForOutputs("4 completed") { $0.contains { $0.requestID?.value == 4 && { if case .completed = $0.event { true } else { false } }($0) } }
        #expect(try h.events(for: 2) == ["error:invalid_request"])
        #expect(try h.events(for: 3) == ["error:invalid_request"])
        #expect(h.fake.shutdownReasons.isEmpty)
        h.source.finish()
        _ = await h.exit()
    }

    @Test func aLexicallyInvalidLineEndsTheConnectionWithANullRequestID() async throws {
        let h = EngineHarness()
        h.start()
        try await hello(h)
        h.source.feed("{\"version\":1,\"version\":1}\n")
        let exit = await h.exit()
        guard case .protocolViolation = exit else { Issue.record("exit was \(exit)"); return }
        let last = try #require(h.outputs.last)
        #expect(last.requestID == nil)
        #expect(h.fake.shutdownReasons == [.protocolError])
    }

    @Test func anUnsupportedVersionTerminatesAfterItsError() async throws {
        let h = EngineHarness()
        h.start()
        h.source.feed("{\"version\":2,\"request_id\":\"1\",\"command\":\"hello\",\"payload\":{}}\n")
        let exit = await h.exit()
        guard case .protocolViolation = exit else { Issue.record("exit was \(exit)"); return }
        #expect(try h.events(for: 1) == ["error:unsupported_version"])
        #expect(h.fake.calls.contains("shutdown"))
    }

    @Test func aWriteFailureShutsDownWithoutWriting() async throws {
        let h = EngineHarness(
            limits: testLimits(deadline: 0.2), sink: ScriptedSink(blocked: true),
            deadlineClock: LiveEngineWriteDeadlineClock()
        )
        h.start()
        h.send(1, "hello")
        let exit = await h.exit()
        #expect(exit == .outputFailed(.deadlineExceeded))
        #expect(exit.processExitCode != 0)
        #expect(h.fake.shutdownReasons == [.outputFailed])
        #expect(h.sink.cancelCount >= 1)
        #expect(h.sink.closed)
    }

    @Test func aBrokenPipeShutsDownAndExitsNonZero() async throws {
        let sink = ScriptedSink()
        sink.failNextWrites(with: .brokenPipe)
        let h = EngineHarness(sink: sink)
        h.start()
        let exit = await h.exit()
        #expect(exit == .outputFailed(.brokenPipe))
        #expect(h.fake.shutdownReasons == [.outputFailed])
    }

    @Test func stdoutCarriesOnlyNDJSONRecords() async throws {
        let h = EngineHarness()
        h.fake.progressOnPrepare = true
        h.start()
        try await hello(h)
        h.send(2, "models.prepare")
        h.send(3, "nonsense")
        h.send(4, "shutdown")
        _ = await h.exit()
        let bytes = h.sink.received
        #expect(bytes.last == 0x0A)
        #expect(!bytes.contains(0x0D))
        let outputs = try ScriptedSink.decodeOutputs(bytes)
        #expect(outputs.map(\.sequence.value) == Array(1...UInt64(outputs.count)))
    }
}

private extension Sequence {
    func appending(_ element: Element) -> [Element] { Array(self) + [element] }
}
