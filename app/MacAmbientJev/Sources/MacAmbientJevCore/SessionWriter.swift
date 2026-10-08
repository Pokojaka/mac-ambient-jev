import Foundation

public actor SessionWriter {
    public let sessionURL: URL
    public let eventsURL: URL
    private var knownLogSize: UInt64
    private var lastEventSequence: UInt64

    public init(sessionURL: URL) throws {
        self.sessionURL = sessionURL
        self.eventsURL = sessionURL.appending(path: "events.jsonl")

        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )

        _ = try ProcessingMetadataStore(sessionURL: sessionURL).load()
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            _ = FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        let handle = try Self.lockedHandle(eventsURL)
        defer { try? handle.close() }
        (knownLogSize, lastEventSequence) = try Self.recover(handle)
    }

    private static func lockedHandle(_ url: URL) throws -> FileHandle {
        let handle = try FileHandle(forUpdating: url)
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? handle.close()
            throw POSIXError(code)
        }
        return handle
    }

    /// Freezes bytes only after an in-flight append has synchronized and released its lock.
    /// This is read-only: unlike writer recovery, it never trims a damaged tail.
    public static func readDurableLog(eventsURL: URL) throws -> Data {
        let handle = try lockedHandle(eventsURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let recovered = try SessionRecovery.recoverJSONL(data)
        guard !recovered.droppedIncompleteTail else {
            throw EventLogTranscriptReaderError.unreadableLine(index: recovered.lines.count)
        }
        _ = try EventLogLine.decode(recovered.lines)
        return data
    }

    private static func recover(_ handle: FileHandle) throws -> (UInt64, UInt64) {
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        let recovered = try SessionRecovery.recoverJSONL(data)
        // Appending to a log of another envelope version would mix formats in one file.
        for line in try EventLogLine.decode(recovered.lines) {
            try line.validateClausePayload()
        }
        var size = UInt64(data.count)
        if recovered.droppedIncompleteTail {
            size = UInt64(data.lastIndex(of: 0x0A).map { $0 - data.startIndex + 1 } ?? 0)
            try handle.truncate(atOffset: size)
            try handle.synchronize()
        } else if let last = data.last, last != 0x0A {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            try handle.synchronize()
            size += 1
        }
        return (size, recovered.lastEventSequence ?? 0)
    }

    @discardableResult
    public func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) throws -> EventEnvelope<Payload> {
        try Task.checkCancellation()
        let handle = try Self.lockedHandle(eventsURL)
        defer { try? handle.close() }
        if try handle.seekToEnd() != knownLogSize {
            (knownLogSize, lastEventSequence) = try Self.recover(handle)
            try handle.seekToEnd()
        }
        try Task.checkCancellation()

        let envelope = EventEnvelope(
            eventSeq: lastEventSequence + 1,
            eventID: UUID(),
            eventType: draft.eventType,
            sessionID: draft.sessionID,
            processingRunID: draft.processingRunID,
            segmentationRunID: draft.segmentationRunID,
            segmentID: draft.segmentID,
            sourceStartFrame: draft.sourceStartFrame,
            sourceEndFrame: draft.sourceEndFrame,
            createdAt: draft.createdAt,
            payload: draft.payload
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(envelope)
        switch draft.eventType {
        case ClauseEventType.boundaryAssessed, ClauseEventType.boundaryPending,
             ClauseEventType.clauseClosed, ClauseEventType.priorityAssigned:
            try EventLogLine(index: Int(clamping: lastEventSequence), data: line).validateClausePayload()
        default:
            break
        }
        line.append(0x0A)

        try handle.write(contentsOf: line)
        try handle.synchronize()

        knownLogSize += UInt64(line.count)
        lastEventSequence = envelope.eventSeq
        return envelope
    }
}
