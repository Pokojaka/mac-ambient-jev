import Foundation
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol

struct FakeFailure: Error {}

/// Records every call and can hold chosen commands open until released. A held call is deliberately not
/// cancellable, like a handler stuck in uncooperative work.
@MainActor
final class FakeEngineHandlers:
    EngineStateHandling, EngineRecordingHandling, EngineSessionHandling, EngineTranscriptHandling,
    EngineSettingsHandling, EngineModelsHandling, EngineShutdownHandling
{
    private(set) var calls: [String] = []
    private(set) var shutdownReasons: [EngineShutdownReason] = []
    private(set) var helloCompletionCount = 0
    var onHelloDidComplete: (@MainActor () -> Void)?
    var heldCommands: Set<String> = []
    var failingCommands: [String: Error] = [:]
    var shutdownError: Error?
    var progressOnPrepare = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { held.count }

    func releaseAll() {
        let continuations = held
        held = []
        for continuation in continuations { continuation.resume() }
    }

    private func enter(_ name: String) async throws {
        calls.append(name)
        if heldCommands.contains(name) {
            await withCheckedContinuation { held.append($0) }
        }
        if let error = failingCommands[name] { throw error }
    }

    var handlers: EngineHandlers {
        EngineHandlers(state: self, recording: self, sessions: self, transcript: self, settings: self, models: self, shutdown: self)
    }

    static let sessionID = "session-1"
    private func session() throws -> EngineSessionPayload { try EngineSessionPayload(sessionID: Self.sessionID) }

    func ready() async throws -> EngineReadyPayload {
        calls.append("ready")
        return try sampleReady()
    }

    func hello() async throws -> EngineReadyPayload {
        try await enter("hello")
        return try sampleReady()
    }

    func helloDidComplete() {
        helloCompletionCount += 1
        onHelloDidComplete?()
    }

    func state() async throws -> EngineState {
        try await enter("state.get")
        return try sampleState(revision: 1)
    }

    func devices(_ payload: EngineDevicesListPayload, context: EngineRequestContext) async throws -> EngineDevicesResult {
        try await enter("devices.list")
        return try EngineDevicesResult(source: payload.source, devices: [], defaultDeviceID: nil)
    }

    func start(_ payload: EngineRecordingStartPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await enter("recording.start")
        return try session()
    }

    func stop(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await enter("recording.stop")
        return payload
    }

    func importSession(_ payload: EngineImportPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await enter("session.import")
        return try session()
    }

    func reprocess(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await enter("session.reprocess")
        return payload
    }

    func retryDecisions(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineSessionPayload {
        try await enter("session.retry_decisions")
        return payload
    }

    func list(_ payload: EngineSessionListPayload, context: EngineRequestContext) async throws -> EngineSessionListResult {
        try await enter("session.list")
        return try EngineSessionListResult(sessions: [], nextCursor: nil)
    }

    func export(_ payload: EngineExportPayload, context: EngineRequestContext) async throws -> EngineExportResult {
        try await enter("session.export")
        return try EngineExportResult(sessionID: payload.sessionID, destinationPath: payload.destinationPath)
    }

    func read(_ payload: EngineTranscriptReadPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        try await enter("transcript.read")
        return try EngineTranscriptPage(sessionID: payload.sessionID, revision: EngineID(1), rows: [], nextCursor: nil)
    }

    func watch(_ payload: EngineSessionPayload, context: EngineRequestContext) async throws -> EngineTranscriptPage {
        try await enter("transcript.watch")
        return try EngineTranscriptPage(sessionID: payload.sessionID, revision: EngineID(1), rows: [], nextCursor: nil)
    }

    func get(context: EngineRequestContext) async throws -> EngineSettingsResult {
        try await enter("settings.get")
        return EngineSettingsResult(revision: try EngineID(1), settings: try sampleSettings())
    }

    func replace(_ payload: EngineSettingsReplacePayload, context: EngineRequestContext) async throws -> EngineSettingsResult {
        try await enter("settings.replace")
        return EngineSettingsResult(revision: try EngineID(2), settings: payload.settings)
    }

    func prepare(context: EngineRequestContext) async throws {
        try await enter("models.prepare")
        if progressOnPrepare {
            try context.events.progress(
                EngineProgressPayload(stage: .loadingModels, completedUnits: 1, totalUnits: 2, sessionID: nil),
                requestID: context.requestID
            )
        }
    }

    func shutdown(reason: EngineShutdownReason) async throws {
        calls.append("shutdown")
        shutdownReasons.append(reason)
        if let shutdownError { throw shutdownError }
    }
}

func sampleSettings() throws -> EngineSettings {
    try EngineSettings(
        schemaVersion: 1, source: .microphone, device: .default, asrSize: .small, executionProvider: .cpu,
        threads: 2, lowHeat: false, decisionsEnabled: true, automaticExport: false, exportDestinationPath: nil
    )
}

/// A controller wired to scripted I/O, running in a background task.
@MainActor
final class EngineHarness {
    let source = ScriptedSource()
    let sink: ScriptedSink
    let fake = FakeEngineHandlers()
    let transport: EngineTransport
    let controller: EngineController
    private var runTask: Task<EngineExit, Never>?

    init(
        limits: EngineTransportLimits = testLimits(),
        admission: EngineAdmissionLimits = .production,
        sink: ScriptedSink = ScriptedSink()
    ) {
        self.sink = sink
        transport = EngineTransport(source: source, sink: sink, limits: limits)
        controller = EngineController(transport: transport, handlers: fake.handlers, admission: admission)
    }

    func start() {
        runTask = Task { await controller.run() }
    }

    func send(_ id: UInt64, _ command: String, payload: String = "{}") {
        source.feed(requestLine(id, command, payload: payload))
    }

    func exit() async -> EngineExit {
        await runTask!.value
    }

    var outputs: [EngineOutput] {
        get throws { try sink.outputs() }
    }

    func waitForOutputs(_ what: String, _ predicate: @escaping @Sendable ([EngineOutput]) -> Bool) async throws {
        let sink = self.sink
        try await waitUntil(what) { ((try? sink.outputs()).map(predicate)) ?? false }
    }

    /// Terminal events (`completed` / `error`) for a request id, in order.
    func events(for id: UInt64) throws -> [String] {
        try outputs.compactMap { output in
            guard output.requestID?.value == id else { return nil }
            switch output.event {
            case .accepted: return "accepted"
            case .completed: return "completed"
            case let .error(failure): return "error:\(failure.code.rawValue)"
            case .progress: return "progress"
            default: return nil
            }
        }
    }
}
