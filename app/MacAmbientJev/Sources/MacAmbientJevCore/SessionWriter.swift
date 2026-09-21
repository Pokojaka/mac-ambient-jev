import Foundation

public actor SessionWriter {
    public let sessionURL: URL
    public let eventsURL: URL
    private var nextEventSequence: UInt64

    public init(sessionURL: URL) throws {
        self.sessionURL = sessionURL
        self.eventsURL = sessionURL.appending(path: "events.jsonl")

        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            _ = FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
            self.nextEventSequence = 1
        } else {
            let existing = try Data(contentsOf: eventsURL)
            let recovered = try SessionRecovery.recoverJSONL(existing)
            if recovered.droppedIncompleteTail {
                try recovered.normalizedData.write(to: eventsURL, options: .atomic)
            }
            self.nextEventSequence = (recovered.lastEventSequence ?? 0) + 1
        }
    }

    @discardableResult
    public func append<Payload: Codable & Sendable>(
        _ draft: EventDraft<Payload>
    ) throws -> EventEnvelope<Payload> {
        let envelope = EventEnvelope(
            eventSeq: nextEventSequence,
            eventID: UUID(),
            eventType: draft.eventType,
            schemaVersion: draft.schemaVersion,
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
        line.append(0x0A)

        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()

        nextEventSequence += 1
        return envelope
    }
}
