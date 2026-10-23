import Foundation
import MacAmbientJevEngineProtocol

public enum EngineExit: Equatable, Sendable {
    /// The client sent `shutdown` and it completed.
    case shutdownRequested
    /// EOF at a record boundary: the engine shut down safely because the client went away.
    case inputClosed
    case protocolViolation(String)
    case inputFailed(String)
    case outputFailed(EngineWriteFailure)
    case shutdownFailed(String)
    case startupFailed(String)
    case captureFailed(String)

    /// 0 for a requested shutdown or a clean disconnect; non-zero for every failure.
    public var processExitCode: Int32 {
        switch self {
        case .shutdownRequested, .inputClosed: 0
        case .protocolViolation: 3
        case .inputFailed: 4
        case .outputFailed: 5
        case .shutdownFailed: 6
        case .startupFailed: 2
        case .captureFailed: 7
        }
    }
}

/// The one logical engine state actor's command front end: enforces `hello` first, the request-id
/// high-water mark and admission bounds, and gives every admitted request `accepted` followed by exactly
/// one `completed` or `error`. Requests rejected before admission get a single `error` and no `accepted`.
///
/// Handlers run on the main actor as unstructured tasks; a handler that serializes against others (for
/// example a second recording) answers `busy` itself.
@MainActor
public final class EngineController {
    private struct InFlight {
        var task: Task<Void, Never>?
    }

    private let transport: EngineTransport
    private let handlers: EngineHandlers
    private let admission: EngineAdmissionLimits
    private let emitter: EngineEventEmitter
    private var order = EngineRequestOrder()
    private var inFlight: [EngineID: InFlight] = [:]

    public init(transport: EngineTransport, handlers: EngineHandlers, admission: EngineAdmissionLimits) {
        self.transport = transport
        self.handlers = handlers
        self.admission = admission
        emitter = EngineEventEmitter(transport: transport)
    }

    /// Runs until shutdown, disconnect or a transport failure, then closes the transport and returns why.
    public func run() async -> EngineExit {
        transport.start()
        do {
            let ready = try await handlers.state.ready()
            try await transport.send(.ready(ready), requestID: nil)
        } catch {
            transport.close()
            return .startupFailed(String(describing: error))
        }
        var exit: EngineExit?
        for await event in transport.events {
            exit = await handle(event)
            if exit != nil { break }
        }
        transport.close()
        return exit ?? .inputFailed("transport event stream ended")
    }

    // MARK: Transport events

    private func handle(_ event: EngineTransportEvent) async -> EngineExit? {
        switch event {
        case let .line(line):
            let exit = await handleLine(line)
            transport.lineHandled()
            return exit
        case .endOfInput:
            return await disconnect(reason: .inputClosed, exit: .inputClosed, canWrite: true)
        case let .protocolViolation(error):
            await sendRejection(
                code: Self.code(for: error), message: "プロトコル違反のため接続を終了します", requestID: nil,
                severity: .fatal, recoveryAction: .restart, reason: String(describing: error)
            )
            return await disconnect(reason: .protocolError, exit: .protocolViolation(String(describing: error)), canWrite: true)
        case let .readFailed(reason):
            await sendRejection(
                code: .internalError, message: "入力を読み取れません", requestID: nil,
                severity: .fatal, recoveryAction: .restart, reason: reason
            )
            return await disconnect(reason: .inputFailed, exit: .inputFailed(reason), canWrite: true)
        case let .writeFailed(failure):
            return await disconnect(reason: .outputFailed, exit: .outputFailed(failure), canWrite: false)
        case let .captureFailed(message):
            return await disconnect(reason: .captureFailed, exit: .captureFailed(message), canWrite: true)
        }
    }

    private func handleLine(_ line: Data) async -> EngineExit? {
        let request: EngineRequest
        do {
            request = try EngineCodec.decodeRequest(line)
        } catch {
            let isUnsupportedVersion: Bool
            if case EngineProtocolError.unsupportedVersion = error { isUnsupportedVersion = true } else { isUnsupportedVersion = false }
            await sendRejection(
                code: Self.code(for: error),
                message: isUnsupportedVersion ? "サポートされていない version です。version 1 のみ対応しています" : "リクエストを解釈できません",
                requestID: EngineCodec.trustedRequestID(in: line),
                severity: isUnsupportedVersion ? .fatal : .error,
                recoveryAction: isUnsupportedVersion ? .restart : .none,
                reason: String(describing: error)
            )
            guard isUnsupportedVersion else { return nil }
            return await disconnect(reason: .protocolError, exit: .protocolViolation(String(describing: error)), canWrite: true)
        }

        let id = request.requestID
        if let rejection = orderRejection(for: request) {
            await sendRejection(
                code: rejection.code, message: rejection.message, requestID: id,
                severity: .error, recoveryAction: .none, reason: nil
            )
            return nil
        }
        do {
            try order.accept(request)
        } catch {
            preconditionFailure("orderRejection and EngineRequestOrder disagree: \(error)")
        }

        let name = request.command.name
        let isControl = name == .recordingStop || name == .shutdown
        let limit = isControl ? admission.maxAdmittedRequests : admission.maxAdmittedRequests - admission.reservedControlRequests
        guard inFlight.count < limit else {
            await sendRejection(
                code: .busy, message: "処理中のリクエストが多すぎます。完了してから再試行してください", requestID: id,
                severity: .error, recoveryAction: .retry, reason: nil
            )
            return nil
        }

        inFlight[id] = InFlight(task: nil)
        do {
            try await transport.send(.accepted(EngineAcceptedPayload(command: name)), requestID: id)
        } catch {
            inFlight.removeValue(forKey: id)
            EngineLog.write("accepted not sent for request \(id.rawValue): \(error)")
            return nil
        }
        if name == .shutdown {
            return await performRequestedShutdown(id)
        }
        let task = Task { [self] in await execute(request) }
        if inFlight[id] != nil { inFlight[id]?.task = task }
        return nil
    }

    private func orderRejection(for request: EngineRequest) -> (code: EngineErrorCode, message: String)? {
        let id = request.requestID
        guard let highWater = order.highWaterMark else {
            guard request.command.name == .hello else {
                return (.helloRequired, "最初のリクエストは hello である必要があります")
            }
            guard id.value == 1 else {
                return (.invalidRequestID, "最初の request_id は 1 である必要があります")
            }
            return nil
        }
        guard request.command.name != .hello else {
            return (.invalidRequest, "hello は最初のリクエストでのみ送れます")
        }
        guard id > highWater else {
            return (.invalidRequestID, "request_id は直前の値より大きい必要があります")
        }
        return nil
    }

    private static func code(for error: Error) -> EngineErrorCode {
        guard let protocolError = error as? EngineProtocolError else { return .invalidRequest }
        switch protocolError {
        case .unsupportedVersion: return .unsupportedVersion
        case .invalidID: return .invalidRequestID
        default: return .invalidRequest
        }
    }

    // MARK: Execution

    private func execute(_ request: EngineRequest) async {
        let id = request.requestID
        let context = EngineRequestContext(requestID: id, events: emitter)
        do {
            let result = try await dispatch(request.command, context: context)
            let sent = await finish(id, .completed(result))
            if sent, request.command.name == .hello { handlers.state.helloDidComplete() }
        } catch {
            await finish(id, Self.failure(for: error, requestID: id))
        }
    }

    private func dispatch(_ command: EngineCommand, context: EngineRequestContext) async throws -> EngineResult {
        switch command {
        case .hello:
            return .hello(try await handlers.state.hello())
        case .stateGet:
            return .stateGet(try await handlers.state.state())
        case let .devicesList(payload):
            return .devicesList(try await handlers.recording.devices(payload, context: context))
        case let .recordingStart(payload):
            return .recordingStart(try await handlers.recording.start(payload, context: context))
        case let .recordingStop(payload):
            return .recordingStop(try await handlers.recording.stop(payload, context: context))
        case let .sessionImport(payload):
            return .sessionImport(try await handlers.sessions.importSession(payload, context: context))
        case let .sessionReprocess(payload):
            return .sessionReprocess(try await handlers.sessions.reprocess(payload, context: context))
        case let .sessionRetryDecisions(payload):
            return .sessionRetryDecisions(try await handlers.sessions.retryDecisions(payload, context: context))
        case let .sessionList(payload):
            return .sessionList(try await handlers.sessions.list(payload, context: context))
        case let .transcriptRead(payload):
            return .transcriptRead(try await handlers.transcript.read(payload, context: context))
        case let .transcriptWatch(payload):
            return .transcriptWatch(try await handlers.transcript.watch(payload, context: context))
        case let .sessionExport(payload):
            return .sessionExport(try await handlers.sessions.export(payload, context: context))
        case .settingsGet:
            return .settingsGet(try await handlers.settings.get(context: context))
        case let .settingsReplace(payload):
            return .settingsReplace(try await handlers.settings.replace(payload, context: context))
        case .modelsPrepare:
            try await handlers.models.prepare(context: context)
            return .modelsPrepare
        case .shutdown:
            preconditionFailure("shutdown is handled inline by the dispatcher")
        }
    }

    /// Emits the terminal reply once. A request already finished, for example cancelled by shutdown, is ignored.
    @discardableResult
    private func finish(_ id: EngineID, _ event: EngineEvent) async -> Bool {
        guard inFlight.removeValue(forKey: id) != nil else { return false }
        do {
            try await transport.send(event, requestID: id)
            return true
        } catch {
            EngineLog.write("terminal reply for request \(id.rawValue) not sent: \(error)")
            return false
        }
    }

    private static func failure(for error: Error, requestID: EngineID) -> EngineEvent {
        if let commandError = error as? EngineCommandError {
            return .error(commandError.failure(requestID: requestID))
        }
        if error is CancellationError {
            return .error(simpleFailure(.cancelled, "処理は中断されました", stage: .shutdown, requestID: requestID, severity: .warning, reason: nil))
        }
        return .error(simpleFailure(.internalError, "内部エラーが発生しました", stage: .protocolValidation, requestID: requestID, severity: .error, reason: String(describing: error)))
    }

    private static func simpleFailure(
        _ code: EngineErrorCode,
        _ message: String,
        stage: EngineStage,
        requestID: EngineID?,
        severity: EngineSeverity,
        recoveryAction: EngineRecoveryAction = .none,
        reason: String?
    ) -> EngineFailure {
        do {
            let details = try reason.map { [try EngineErrorDetail(domain: "engine", code: code.rawValue, message: $0.isEmpty ? "(empty)" : $0, path: nil, deviceID: nil)] } ?? []
            return try EngineFailure(
                code: code, message: message, stage: stage, requestID: requestID, sessionID: nil,
                severity: severity, recoveryAction: recoveryAction, details: details, cleanupErrors: []
            )
        } catch {
            preconditionFailure("constant failure fields are valid: \(error)")
        }
    }

    private func sendRejection(
        code: EngineErrorCode,
        message: String,
        requestID: EngineID?,
        severity: EngineSeverity,
        recoveryAction: EngineRecoveryAction,
        reason: String?
    ) async {
        let failure = Self.simpleFailure(
            code, message, stage: .protocolValidation, requestID: requestID,
            severity: severity, recoveryAction: recoveryAction, reason: reason
        )
        do {
            try await transport.send(.error(failure), requestID: requestID)
        } catch {
            EngineLog.write("rejection \(code.rawValue) not sent: \(error)")
        }
    }

    // MARK: Shutdown

    private func performRequestedShutdown(_ id: EngineID) async -> EngineExit {
        let failure = await stopEverything(reason: .requested, keeping: id)
        if let failure {
            await finish(id, .error(Self.simpleFailure(
                .internalError, "シャットダウンに失敗しました", stage: .shutdown, requestID: id,
                severity: .fatal, recoveryAction: .restart, reason: failure
            )))
            await transport.drain()
            return .shutdownFailed(failure)
        }
        await finish(id, .completed(.shutdown))
        await transport.drain()
        return .shutdownRequested
    }

    private func disconnect(reason: EngineShutdownReason, exit: EngineExit, canWrite: Bool) async -> EngineExit {
        let failure = await stopEverything(reason: reason, keeping: nil)
        if canWrite { await transport.drain() }
        if let failure { return .shutdownFailed(failure) }
        return exit
    }

    /// Runs the shutdown handler, then gives every request still in flight its `cancelled` terminal reply.
    /// Returns the handler's failure description, if any.
    private func stopEverything(reason: EngineShutdownReason, keeping keptID: EngineID?) async -> String? {
        var failure: String?
        do {
            try await handlers.shutdown.shutdown(reason: reason)
        } catch {
            failure = String(describing: error)
            EngineLog.write("shutdown handler failed: \(error)")
        }
        for id in inFlight.keys.sorted() where id != keptID {
            inFlight[id]?.task?.cancel()
            await finish(id, Self.failure(for: CancellationError(), requestID: id))
        }
        return failure
    }
}
