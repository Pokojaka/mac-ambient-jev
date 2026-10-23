import Foundation

public enum EngineCodec {
    /// Maximum bytes in one compact encoded transcript row, including its keys.
    /// This is a controller-selected per-row budget, not a history limit.
    public static let maxRowBytes = 262_144

    public static func decodeRequest(_ line: Data) throws -> EngineRequest {
        try EngineJSONValidator.validate(line)
        return try JSONDecoder().decode(EngineRequest.self, from: line)
    }

    public static func decodeOutput(_ line: Data) throws -> EngineOutput {
        try EngineJSONValidator.validate(line)
        let output = try JSONDecoder().decode(EngineOutput.self, from: line)
        try validateRows(in: output, using: makeEncoder())
        return output
    }

    public static func encodeRequest(_ request: EngineRequest) throws -> Data {
        try encodeLine(request, using: makeEncoder())
    }

    public static func encodeOutput(_ output: EngineOutput) throws -> Data {
        let encoder = makeEncoder()
        try validateRows(in: output, using: encoder)
        return try encodeLine(output, using: encoder)
    }

    /// Extracts a canonical ID only for diagnostics after the entire record passes lexical validation.
    /// A nil result is not a configuration fallback and must not affect command handling.
    public static func trustedRequestID(in line: Data) -> EngineID? {
        do {
            try EngineJSONValidator.validate(line)
            return try JSONDecoder().decode(TrustedRequestIDProbe.self, from: line).requestID
        } catch {
            return nil
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func encodeLine<Value: Encodable>(_ value: Value, using encoder: JSONEncoder) throws -> Data {
        let line = try encoder.encode(value)
        try EngineJSONValidator.validate(line)
        var record = line
        record.append(0x0A)
        return record
    }

    private static func validateRows(in output: EngineOutput, using encoder: JSONEncoder) throws {
        let rows: [EngineTranscriptRow]
        switch output.event {
        case let .rows(payload):
            rows = payload.rows
        case let .completed(result):
            switch result {
            case let .transcriptRead(page), let .transcriptWatch(page):
                rows = page.rows
            default:
                rows = []
            }
        default:
            rows = []
        }

        for row in rows {
            if try encoder.encode(row).count > maxRowBytes {
                throw EngineProtocolError.oversizedRow(row.rowID)
            }
        }
    }
}

private struct TrustedRequestIDProbe: Decodable {
    let requestID: EngineID

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
    }
}

public struct EngineLineFramer: Sendable {
    public static let maxLineBytes = EngineJSONValidator.maxLineBytes

    public private(set) var bufferedByteCount = 0

    private var buffer: [UInt8] = []
    private var hasPendingCarriageReturn = false
    private var isClosed = false

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !isClosed else {
            throw EngineProtocolError.closedFramer
        }

        var records: [Data] = []
        do {
            for byte in bytes {
                if hasPendingCarriageReturn {
                    guard byte == 0x0A else {
                        throw EngineProtocolError.invalidJSON("bare carriage return")
                    }
                    hasPendingCarriageReturn = false
                    bufferedByteCount -= 1
                    try finishRecord(into: &records)
                    continue
                }

                switch byte {
                case 0x0A:
                    try finishRecord(into: &records)
                case 0x0D:
                    hasPendingCarriageReturn = true
                    bufferedByteCount += 1
                default:
                    guard buffer.count < Self.maxLineBytes else {
                        throw EngineProtocolError.lineTooLong
                    }
                    buffer.append(byte)
                    bufferedByteCount += 1
                }
            }
            return records
        } catch {
            poison()
            throw error
        }
    }

    public mutating func finish() throws {
        guard !isClosed else {
            throw EngineProtocolError.closedFramer
        }
        guard buffer.isEmpty, !hasPendingCarriageReturn else {
            poison()
            throw EngineProtocolError.partialFinalLine
        }
        isClosed = true
    }

    private mutating func finishRecord(into records: inout [Data]) throws {
        let record = Data(buffer)
        try EngineJSONValidator.validate(record)
        records.append(record)
        buffer.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
    }

    private mutating func poison() {
        buffer.removeAll(keepingCapacity: false)
        hasPendingCarriageReturn = false
        bufferedByteCount = 0
        isClosed = true
    }
}

public struct EngineRequestOrder: Sendable {
    /// Nil denotes the explicit initial state of a new connection, not a configuration fallback.
    public private(set) var highWaterMark: EngineID?

    public init() {
        highWaterMark = nil
    }

    public mutating func accept(_ request: EngineRequest) throws {
        let id = request.requestID
        if let current = highWaterMark {
            guard request.command.name != .hello else {
                throw EngineProtocolError.invalidOrder("hello must be the first request")
            }
            guard id > current else {
                throw EngineProtocolError.invalidOrder("request_id must increase")
            }
        } else {
            guard case .hello = request.command else {
                throw EngineProtocolError.invalidOrder("hello must be the first request")
            }
            guard id.value == 1 else {
                throw EngineProtocolError.invalidOrder("first request_id must be 1")
            }
        }
        highWaterMark = id
    }
}

public struct EngineSequenceOrder: Sendable {
    public private(set) var highWaterMark: EngineID?

    public init() {
        highWaterMark = nil
    }

    public mutating func accept(_ sequence: EngineID) throws {
        if let current = highWaterMark {
            guard sequence > current else {
                throw EngineProtocolError.invalidOrder("sequence must increase")
            }
        } else {
            guard sequence.value == 1 else {
                throw EngineProtocolError.invalidOrder("first sequence must be 1")
            }
        }
        highWaterMark = sequence
    }
}

public struct EngineSequenceGenerator: Sendable {
    private var lastGenerated: EngineID?

    public init() {
        lastGenerated = nil
    }

    public mutating func next() throws -> EngineID {
        guard let previous = lastGenerated else {
            let first = try EngineID(1)
            lastGenerated = first
            return first
        }
        guard previous.value < UInt64.max else {
            throw EngineProtocolError.invalidOrder("sequence exhausted")
        }
        let next = try EngineID(previous.value + 1)
        lastGenerated = next
        return next
    }
}
