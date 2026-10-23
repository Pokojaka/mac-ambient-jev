import Foundation
import MacAmbientJevEngineProtocol

public enum EngineTransportEvent: Equatable, Sendable {
    /// One complete record without its delimiter, already lexically valid.
    case line(Data)
    /// Clean end of input at a record boundary.
    case endOfInput
    /// Framing or lexical violation, including a partial final line at EOF. The input lane has stopped.
    case protocolViolation(EngineProtocolError)
    case readFailed(String)
    case writeFailed(EngineWriteFailure)
    case captureFailed(String)
}

/// The engine's byte transport: a dedicated input lane feeding `EngineLineFramer`, and one stdout writer.
///
/// Consume `events` from one task and call `lineHandled()` after each `.line`; the input lane blocks
/// once `maxPendingInputLines` lines are unhandled, so a slow controller backpressures the pipe.
public final class EngineTransport: @unchecked Sendable {
    public let events: AsyncStream<EngineTransportEvent>

    private let source: EngineByteSource
    private let limits: EngineTransportLimits
    private let continuation: AsyncStream<EngineTransportEvent>.Continuation
    private let output: EngineOutputChannel
    private let lane: EngineInputLane

    public init(source: EngineByteSource, sink: EngineByteSink, limits: EngineTransportLimits) {
        let (events, continuation) = AsyncStream<EngineTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = events
        self.continuation = continuation
        self.source = source
        self.limits = limits
        output = EngineOutputChannel(sink: sink, limits: limits) { failure in
            EngineLog.write("output failed: \(failure)")
            continuation.yield(.writeFailed(failure))
        }
        lane = EngineInputLane(source: source, limits: limits, continuation: continuation)
    }

    public func start() {
        output.start()
        lane.start()
    }

    /// Reliable events (`ready`, `accepted`, `completed`, `error`) may suspend until the writer frees room.
    /// Replaceable events (`state`, `progress`, `rows`) never suspend and may be coalesced.
    public func send(_ event: EngineEvent, requestID: EngineID?) async throws {
        switch event {
        case .ready, .accepted, .completed, .error:
            try await output.sendReliable(event, requestID: requestID)
        case .state, .progress, .rows:
            try output.sendReplaceable(event, requestID: requestID)
        }
    }

    public func sendReplaceable(_ event: EngineEvent, requestID: EngineID?) throws {
        try output.sendReplaceable(event, requestID: requestID)
    }

    public func lineHandled() {
        lane.lineHandled()
    }

    public func captureFailed(_ message: String) {
        continuation.yield(.captureFailed(message))
    }

    /// Returns once every record queued so far has been written, or the writer failed.
    public func drain() async {
        await output.drain()
    }

    /// Stops the lanes and closes the input source and the output sink. Queued unwritten records are dropped.
    public func close() {
        lane.stop()
        output.close()
        source.close()
        continuation.finish()
    }
}

final class EngineInputLane: @unchecked Sendable {
    private let source: EngineByteSource
    private let limits: EngineTransportLimits
    private let continuation: AsyncStream<EngineTransportEvent>.Continuation
    private let condition = NSCondition()
    private var credits: Int
    private var stopped = false

    init(source: EngineByteSource, limits: EngineTransportLimits, continuation: AsyncStream<EngineTransportEvent>.Continuation) {
        self.source = source
        self.limits = limits
        self.continuation = continuation
        credits = limits.maxPendingInputLines
    }

    func start() {
        Thread.detachNewThread { [self] in run() }
    }

    func lineHandled() {
        condition.lock()
        credits += 1
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    private var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// Blocks until a line may be delivered. False once the lane is stopped.
    private func acquireCredit() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while credits == 0 && !stopped { condition.wait() }
        guard !stopped else { return false }
        credits -= 1
        return true
    }

    private func run() {
        var framer = EngineLineFramer()
        while !isStopped {
            let chunk: Data
            do {
                chunk = try source.read(maxByteCount: limits.readChunkBytes)
            } catch {
                if !isStopped { continuation.yield(.readFailed(String(describing: error))) }
                return
            }
            if chunk.isEmpty {
                do {
                    try framer.finish()
                    continuation.yield(.endOfInput)
                } catch let error as EngineProtocolError {
                    continuation.yield(.protocolViolation(error))
                } catch {
                    continuation.yield(.readFailed(String(describing: error)))
                }
                return
            }
            // Feeding one LF-terminated segment at a time keeps records completed before a bad line.
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = chunk[start...].firstIndex(of: 0x0A).map { chunk.index(after: $0) } ?? chunk.endIndex
                do {
                    for record in try framer.append(chunk[start..<end]) {
                        guard acquireCredit() else { return }
                        continuation.yield(.line(record))
                    }
                } catch let error as EngineProtocolError {
                    continuation.yield(.protocolViolation(error))
                    return
                } catch {
                    continuation.yield(.readFailed(String(describing: error)))
                    return
                }
                start = end
            }
        }
    }
}
