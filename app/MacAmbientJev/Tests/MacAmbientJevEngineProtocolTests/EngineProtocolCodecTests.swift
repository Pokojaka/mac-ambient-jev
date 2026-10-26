import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolCodecTests {
    @Test func codecAppliesLexicalValidationBeforeTypedDecoding() {
        let validPrefix = #"{"version":1,"request_id":"1","command":"hello","payload":{}}"#
        let nestedDuplicate = #"{"version":1,"request_id":"1","command":"hello","payload":{"x":1,"x":2}}"#
        let escapedDuplicate = #"{"version":1,"request_id":"1","command":"hello","payload":{"x":1,"\u0078":2}}"#
        let badNumbers = [
            #"{"version":1,"request_id":"1","command":"hello","payload":{},"x":01}"#,
            #"{"version":1,"request_id":"1","command":"hello","payload":{},"x":NaN}"#,
            #"{"version":1,"request_id":"1","command":"hello","payload":{},"x":1e9999}"#,
        ]
        let tooDeep = "{\"x\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}"
        let overlong = Data(repeating: 0x20, count: EngineJSONValidator.maxLineBytes + 1)
        var invalidUTF8 = Data(validPrefix.utf8)
        invalidUTF8.insert(0xFF, at: invalidUTF8.count - 1)
        let cases: [Data] = [
            Data(nestedDuplicate.utf8), Data(escapedDuplicate.utf8), invalidUTF8,
            Data([0xEF, 0xBB, 0xBF] + Array(validPrefix.utf8)),
            Data(#"{"version":1,"request_id":"1","command":"hello","payload":{},}"#.utf8),
            Data(#"{"version":1,"request_id":"1","command":"hello","payload":{}} {}"#.utf8),
            Data("[]".utf8), Data(tooDeep.utf8), overlong,
        ] + badNumbers.map { Data($0.utf8) }
        for data in cases {
            #expect(throws: (any Error).self) { try EngineCodec.decodeRequest(data) }
        }
    }

    @Test func framerHandlesEveryByteAndEverySplitIncludingUTF8AndCRLF() throws {
        let record = Data(#"{"text":"😀日本語\nend"}"#.utf8)
        let stream = record + Data([0x0D, 0x0A]) + Data(#"{"n":2}"#.utf8) + Data([0x0A])
        var bytewise = EngineLineFramer()
        var emitted: [Data] = []
        for byte in stream {
            emitted += try bytewise.append(Data([byte]))
        }
        try bytewise.finish()
        #expect(emitted == [record, Data(#"{"n":2}"#.utf8)])

        var coalesced = EngineLineFramer()
        #expect(try coalesced.append(stream) == [record, Data(#"{"n":2}"#.utf8)])
        try coalesced.finish()

        let utf8CRLF = Data(#"{"text":"😀"}"#.utf8) + Data([0x0D, 0x0A])
        for split in 0...utf8CRLF.count {
            var framer = EngineLineFramer()
            let first = utf8CRLF.subdata(in: 0..<split)
            let second = utf8CRLF.subdata(in: split..<utf8CRLF.count)
            var lines = try framer.append(first)
            lines += try framer.append(second)
            #expect(lines == [Data(#"{"text":"😀"}"#.utf8)], "split at byte \(split)")
            try framer.finish()
        }
    }

    @Test func framerRejectsBlankBareCRAndPartialRecordsAndPoisonsAfterFailure() throws {
        for bytes in [Data([0x0A]), Data([0x0D, 0x0A]), Data([0x20, 0x09, 0x0A])] {
            var framer = EngineLineFramer()
            #expect(capturedProtocolError { _ = try framer.append(bytes) } == .blankLine)
            #expect(framer.bufferedByteCount == 0)
            #expect(capturedProtocolError { _ = try framer.append(Data()) } == .closedFramer)
            #expect(capturedProtocolError { try framer.finish() } == .closedFramer)
        }

        var bareCR = EngineLineFramer()
        #expect(try bareCR.append(Data("{}\r".utf8)).isEmpty)
        #expect(bareCR.bufferedByteCount == 3)
        #expect(capturedProtocolError { _ = try bareCR.append(Data("x".utf8)) } == .invalidJSON("bare carriage return"))
        #expect(capturedProtocolError { try bareCR.finish() } == .closedFramer)

        var partial = EngineLineFramer()
        _ = try partial.append(Data("{}".utf8))
        #expect(capturedProtocolError { try partial.finish() } == .partialFinalLine)
        #expect(partial.bufferedByteCount == 0)
        #expect(capturedProtocolError { _ = try partial.append(Data()) } == .closedFramer)

        var clean = EngineLineFramer()
        #expect(try clean.append(Data()).isEmpty)
        try clean.finish()
        #expect(capturedProtocolError { try clean.finish() } == .closedFramer)
    }

    @Test func framerAcceptsExactByteLimitAndRejectsOverlongInputBoundedly() throws {
        let prefix = #"{"x":""#
        let suffix = #""}"#
        let exact = Data((prefix + String(repeating: "a", count: EngineJSONValidator.maxLineBytes - prefix.utf8.count - suffix.utf8.count) + suffix).utf8)
        #expect(exact.count == EngineJSONValidator.maxLineBytes)
        for delimiter in [Data([0x0A]), Data([0x0D, 0x0A])] {
            var framer = EngineLineFramer()
            let lines = try framer.append(exact + delimiter)
            #expect(lines == [exact])
            try framer.finish()
        }

        var fragmented = EngineLineFramer()
        let overlongPrefix = Data(repeating: 0x61, count: EngineJSONValidator.maxLineBytes)
        for offset in stride(from: 0, to: overlongPrefix.count, by: 16_384) {
            let end = min(offset + 16_384, overlongPrefix.count)
            _ = try fragmented.append(overlongPrefix.subdata(in: offset..<end))
            #expect(fragmented.bufferedByteCount <= EngineJSONValidator.maxLineBytes)
        }
        #expect(fragmented.bufferedByteCount == EngineJSONValidator.maxLineBytes)
        #expect(capturedProtocolError { _ = try fragmented.append(Data([0x61])) } == .lineTooLong)
        #expect(fragmented.bufferedByteCount == 0)
        #expect(capturedProtocolError { _ = try fragmented.append(Data()) } == .closedFramer)

        var coalesced = EngineLineFramer()
        let validThenOverlong = Data("{}\n".utf8) + Data(repeating: 0x61, count: EngineJSONValidator.maxLineBytes + 1)
        #expect(capturedProtocolError { _ = try coalesced.append(validThenOverlong) } == .lineTooLong)
        #expect(capturedProtocolError { _ = try coalesced.append(Data()) } == .closedFramer)
    }

    @Test func trustedIDRequiresLexicalIntegrityButNotValidCommandSemantics() throws {
        let semanticallyInvalid = Data(#"{"version":1,"request_id":"42","command":"future.command","payload":{"future":true},"other":null}"#.utf8)
        #expect(EngineCodec.trustedRequestID(in: semanticallyInvalid) == id(42))
        #expect(EngineCodec.trustedRequestID(in: Data(#"{"version":1,"request_id":"01","command":"hello","payload":{}}"#.utf8)) == nil)
        #expect(EngineCodec.trustedRequestID(in: Data(#"{"version":1,"request_id":1,"command":"hello","payload":{}}"#.utf8)) == nil)
        #expect(EngineCodec.trustedRequestID(in: Data(#"{"request_id":"1","x":1,"x":2}"#.utf8)) == nil)
        #expect(EngineCodec.trustedRequestID(in: Data(#"{"request_id":"1","x":1e9999}"#.utf8)) == nil)
        #expect(EngineCodec.trustedRequestID(in: Data([0xEF, 0xBB, 0xBF] + Array(#"{"request_id":"1"}"#.utf8))) == nil)
        #expect(EngineCodec.trustedRequestID(in: Data(("{" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}").utf8)) == nil)
    }

    @Test func rowByteLimitIsInclusiveForRowsEventsAndCompletedPages() throws {
        let exactRow = try asciiRow(exactEncodedBytes: EngineCodec.maxRowBytes)
        #expect(encodedRow(exactRow).count == EngineCodec.maxRowBytes)
        let event = try rowsOutput([exactRow])
        #expect(try EngineCodec.decodeOutput(Data(EngineCodec.encodeOutput(event).dropLast())) == event)

        let tooLarge = try asciiRow(exactEncodedBytes: EngineCodec.maxRowBytes + 1)
        #expect(protocolError { _ = try EngineCodec.encodeOutput(rowsOutput([tooLarge])) } == .oversizedRow(tooLarge.rowID))
        let page = try EngineTranscriptPage(sessionID: "s", revision: id(1), rows: [tooLarge], nextCursor: nil, previousCursor: nil)
        for result in [EngineResult.transcriptRead(page), .transcriptWatch(page)] {
            let output = try EngineOutput(version: 1, sequence: id(1), requestID: id(2), event: .completed(result))
            #expect(protocolError { _ = try EngineCodec.encodeOutput(output) } == .oversizedRow(tooLarge.rowID))
            let raw = try rawJSONEncoder().encode(output)
            #expect(protocolError { _ = try EngineCodec.decodeOutput(raw) } == .oversizedRow(tooLarge.rowID))
        }
        let rawRowsEvent = try rawJSONEncoder().encode(rowsOutput([tooLarge]))
        #expect(protocolError { _ = try EngineCodec.decodeOutput(rawRowsEvent) } == .oversizedRow(tooLarge.rowID))
    }

    @Test func rowLimitCountsUTF8AndJSONEscapedBytesAndFullPageLimitIsSeparate() throws {
        let multiByte = try EngineTranscriptRow(rowID: "unicode", startMS: 0, endMS: 1, text: String(repeating: "界", count: 100), headings: [], clauseState: nil)
        let escaped = try EngineTranscriptRow(rowID: "escaped", startMS: 0, endMS: 1, text: String(repeating: "\n", count: 100) + "x", headings: [], clauseState: nil)
        #expect(encodedRow(multiByte).count > multiByte.text.count)
        #expect(encodedRow(escaped).count > escaped.text.count)

        let characterShortButByteLarge = try EngineTranscriptRow(rowID: "escaped-large", startMS: 0, endMS: 1, text: String(repeating: "\n", count: 131_100) + "x", headings: [], clauseState: nil)
        #expect(characterShortButByteLarge.text.count < EngineCodec.maxRowBytes)
        #expect(protocolError { _ = try EngineCodec.encodeOutput(rowsOutput([characterShortButByteLarge])) } == .oversizedRow("escaped-large"))

        let unicodeShortButByteLarge = try EngineTranscriptRow(rowID: "unicode-large", startMS: 0, endMS: 1, text: String(repeating: "界", count: 87_400), headings: [], clauseState: nil)
        #expect(unicodeShortButByteLarge.text.count < EngineCodec.maxRowBytes)
        #expect(encodedRow(unicodeShortButByteLarge).count > EngineCodec.maxRowBytes)
        #expect(protocolError { _ = try EngineCodec.encodeOutput(rowsOutput([unicodeShortButByteLarge])) } == .oversizedRow("unicode-large"))

        let rows = try (0..<5).map { index in
            try EngineTranscriptRow(rowID: "large-\(index)", startMS: 0, endMS: 1, text: String(repeating: "x", count: 220_000), headings: [], clauseState: nil)
        }
        #expect(rows.allSatisfy { encodedRow($0).count <= EngineCodec.maxRowBytes })
        #expect(protocolError { _ = try EngineCodec.encodeOutput(rowsOutput(rows)) } == .lineTooLong)
    }

    @Test func requestAndSequenceOrdersAreStrictAtomicAndAllowGaps() throws {
        var requests = EngineRequestOrder()
        #expect(protocolError { try requests.accept(makeRequest(1, .stateGet)) } == .invalidOrder("hello must be the first request"))
        #expect(requests.highWaterMark == nil)
        #expect(protocolError { try requests.accept(makeRequest(2, .hello)) } == .invalidOrder("first request_id must be 1"))
        #expect(requests.highWaterMark == nil)
        try requests.accept(makeRequest(1, .hello))
        #expect(requests.highWaterMark == id(1))
        #expect(protocolError { try requests.accept(makeRequest(2, .hello)) } == .invalidOrder("hello must be the first request"))
        #expect(protocolError { try requests.accept(makeRequest(1, .stateGet)) } == .invalidOrder("request_id must increase"))
        #expect(requests.highWaterMark == id(1))
        try requests.accept(makeRequest(4, .stateGet))
        #expect(requests.highWaterMark == id(4))
        #expect(protocolError { try requests.accept(makeRequest(3, .stateGet)) } == .invalidOrder("request_id must increase"))
        #expect(requests.highWaterMark == id(4))
        try requests.accept(makeRequest(UInt64.max, .stateGet))
        #expect(protocolError { try requests.accept(makeRequest(UInt64.max - 1, .stateGet)) } == .invalidOrder("request_id must increase"))
        #expect(requests.highWaterMark == id(UInt64.max))

        var sequences = EngineSequenceOrder()
        #expect(protocolError { try sequences.accept(id(2)) } == .invalidOrder("first sequence must be 1"))
        #expect(sequences.highWaterMark == nil)
        try sequences.accept(id(1))
        #expect(protocolError { try sequences.accept(id(1)) } == .invalidOrder("sequence must increase"))
        try sequences.accept(id(7))
        #expect(protocolError { try sequences.accept(id(6)) } == .invalidOrder("sequence must increase"))
        try sequences.accept(id(UInt64.max))
        #expect(protocolError { try sequences.accept(id(UInt64.max - 1)) } == .invalidOrder("sequence must increase"))
        #expect(sequences.highWaterMark == id(UInt64.max))
    }

    @Test func sequenceGeneratorStartsAtOneThenIncrements() throws {
        var generator = EngineSequenceGenerator()
        #expect(try generator.next() == id(1))
        #expect(try generator.next() == id(2))
        #expect(try generator.next() == id(3))
    }
}

private func id(_ value: UInt64) -> EngineID {
    try! EngineID(value)
}

private func makeRequest(_ requestID: UInt64, _ command: EngineCommand) throws -> EngineRequest {
    try EngineRequest(version: 1, requestID: id(requestID), command: command)
}

private func rowsOutput(_ rows: [EngineTranscriptRow]) throws -> EngineOutput {
    let payload = try EngineRowsPayload(sessionID: "s", revision: id(1), kind: .snapshot, rows: rows, removedRowIDs: [], nextCursor: nil)
    return try EngineOutput(version: 1, sequence: id(1), requestID: nil, event: .rows(payload))
}

private func asciiRow(exactEncodedBytes byteCount: Int) throws -> EngineTranscriptRow {
    let oneCharacter = try EngineTranscriptRow(rowID: "limit-row", startMS: 0, endMS: 1, text: "x", headings: [], clauseState: nil)
    let overhead = encodedRow(oneCharacter).count - 1
    return try EngineTranscriptRow(rowID: "limit-row", startMS: 0, endMS: 1, text: String(repeating: "x", count: byteCount - overhead), headings: [], clauseState: nil)
}

private func encodedRow(_ row: EngineTranscriptRow) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try! encoder.encode(row)
}

private func rawJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func protocolError(_ body: () throws -> Void) -> EngineProtocolError? {
    do {
        try body()
        return nil
    } catch let error as EngineProtocolError {
        return error
    } catch {
        return nil
    }
}

private func capturedProtocolError(_ body: () throws -> Void) -> EngineProtocolError? {
    protocolError(body)
}
