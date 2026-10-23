import Foundation
import Testing
@testable import MacAmbientJevEngineProtocol

struct EngineProtocolLexicalTests {
    @Test func duplicateKeysAreRejectedAtEveryObjectDepth() {
        #expect(engineError(#"{"x":1,"x":2}"#) == .duplicateKey("x"))
        #expect(engineError(#"{"outer":{"x":1,"x":2}}"#) == .duplicateKey("x"))
        #expect(engineError(#"{"items":[{"x":1,"x":2}]}"#) == .duplicateKey("x"))
        #expect(engineError(#"{"a":1,"\u0061":2}"#) == .duplicateKey("a"))
    }

    @Test func depthLimitIsInclusive() throws {
        let atLimit = nestedObject(arrayCount: EngineJSONValidator.maxDepth - 1)
        try EngineJSONValidator.validate(Data(atLimit.utf8))

        let overLimit = nestedObject(arrayCount: EngineJSONValidator.maxDepth)
        #expect(engineError(overLimit) == .nestingTooDeep)
    }

    @Test func lineByteLimitIsInclusive() throws {
        let prefix = #"{"x":""#
        let suffix = #""}"#
        let fill = String(repeating: "a", count: EngineJSONValidator.maxLineBytes - prefix.utf8.count - suffix.utf8.count)
        let atLimit = prefix + fill + suffix
        #expect(atLimit.utf8.count == EngineJSONValidator.maxLineBytes)
        try EngineJSONValidator.validate(Data(atLimit.utf8))

        #expect(engineError(atLimit + " ") == .lineTooLong)
    }

    @Test func rejectsInvalidUTF8AndInitialBOM() {
        let overlongUTF8 = Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xC0, 0xAF, 0x22, 0x7D])
        #expect(engineError(overlongUTF8) == .invalidUTF8)
        #expect(engineError(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))) == .byteOrderMark)
    }

    @Test func rejectsBlankLinesAndLiteralLineBreaks() {
        #expect(engineError(Data()) == .blankLine)
        #expect(engineError(Data([0x20, 0x09, 0x20])) == .blankLine)
        #expect(engineError(Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x31, 0x7D, 0x0A])) == .invalidJSON("literal line break"))
        #expect(engineError(Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x31, 0x7D, 0x0D])) == .invalidJSON("literal line break"))
        #expect(engineError(Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0x61, 0x0A, 0x62, 0x22, 0x7D])) == .invalidJSON("literal line break"))
    }

    @Test func enforcesJSONNumberGrammarAndFiniteValues() throws {
        let malformedNumbers = [
            #"{"n":01}"#,
            #"{"n":-}"#,
            #"{"n":.1}"#,
            #"{"n":+1}"#,
            #"{"n":1.}"#,
            #"{"n":1e}"#,
            #"{"n":1e+}"#,
            #"{"n":0x1}"#,
        ]
        for value in malformedNumbers {
            #expect(engineError(value) == .invalidNumber, "Expected invalidNumber for \(value)")
        }

        for value in [#"{"n":NaN}"#, #"{"n":Infinity}"#, #"{"n":-Infinity}"#, #"{"n":1e9999}"#] {
            #expect(engineError(value) == .invalidNumber, "Expected finite-number rejection for \(value)")
        }

        try EngineJSONValidator.validate(Data(#"{"n":-1.25e+100,"underflow":1e-9999}"#.utf8))
    }

    @Test func rejectsMalformedStringsAndAcceptsUnicodeEscapes() throws {
        let malformed = [
            #"{"s":"bad\q"}"#,
            #"{"s":"\uD800"}"#,
            #"{"s":"\uDC00"}"#,
            #"{"s":"\uD800\u0041"}"#,
            #"{"s":"unterminated}"#,
        ]
        for value in malformed {
            #expect(engineError(value) != nil, "Expected string rejection for \(value)")
        }

        try EngineJSONValidator.validate(Data(#"{"emoji":"😀","japanese":"日本語","newline":"first\nsecond","pair":"\uD83D\uDE00"}"#.utf8))
    }

    @Test func requiresObjectRootAndCompleteInput() {
        #expect(engineError("[]") == .invalidJSON("root must be an object"))
        #expect(engineError("null") == .invalidJSON("root must be an object"))
        #expect(engineError("{} {}") == .invalidJSON("trailing data"))
        #expect(engineError("{}x") == .invalidJSON("trailing data"))
        #expect(engineError(#"{"x":true,}"#) != nil)
        #expect(engineError(#"{"x":}"#) != nil)
    }

    @Test func nullableRequiresAKeyAndPreservesNullAndValue() throws {
        let missingFailed = decodingFails(NullableModel.self, from: Data("{}".utf8))
        #expect(missingFailed)

        let nullValue = try JSONDecoder().decode(NullableModel.self, from: Data(#"{"value":null}"#.utf8))
        #expect(nullValue.value == nil)
        let encodedNull = try JSONEncoder().encode(nullValue)
        #expect(String(decoding: encodedNull, as: UTF8.self) == #"{"value":null}"#)

        let presentValue = try JSONDecoder().decode(NullableModel.self, from: Data(#"{"value":"ready"}"#.utf8))
        #expect(presentValue.value == "ready")
        let encodedValue = try JSONEncoder().encode(presentValue)
        #expect(try JSONDecoder().decode(NullableModel.self, from: encodedValue).value == "ready")
    }

    @Test func dynamicContainerRejectsUnknownKeysAtEveryModelLevel() {
        let topLevelError = decodingEngineError(NullableModel.self, from: Data(#"{"value":null,"extra":true}"#.utf8))
        #expect(topLevelError == .invalidJSON("unknown field: extra"))

        let nestedError = decodingEngineError(ParentModel.self, from: Data(#"{"child":{"value":1,"extra":true}}"#.utf8))
        #expect(nestedError == .invalidJSON("unknown field: extra"))
    }

    @Test func engineIDUsesPositiveCanonicalDecimalStrings() throws {
        let minimum = try EngineID(decimal: "1")
        let maximum = try EngineID(decimal: "18446744073709551615")
        #expect(minimum.value == 1)
        #expect(minimum.rawValue == "1")
        #expect(maximum.value == UInt64.max)
        #expect(maximum.rawValue == "18446744073709551615")
        #expect(minimum < maximum)
        #expect(try JSONDecoder().decode(EngineID.self, from: Data(#""1""#.utf8)) == minimum)
        #expect(String(decoding: try JSONEncoder().encode(maximum), as: UTF8.self) == #""18446744073709551615""#)

        for value in ["", "0", "00", "01", "+1", "-1", " 1", "١", "18446744073709551616"] {
            #expect(capturedEngineError { _ = try EngineID(decimal: value) } == .invalidID, "Expected invalid ID for \(value)")
        }
        #expect(capturedEngineError { _ = try EngineID(0) } == .invalidID)
        #expect(decodingEngineError(EngineID.self, from: Data("1".utf8)) == .invalidID)
        #expect(decodingEngineError(EngineID.self, from: Data("null".utf8)) == .invalidID)
    }
}

private func nestedObject(arrayCount: Int) -> String {
    "{\"value\":" + String(repeating: "[", count: arrayCount) + "0" + String(repeating: "]", count: arrayCount) + "}"
}

private func engineError(_ string: String) -> EngineProtocolError? {
    engineError(Data(string.utf8))
}

private func engineError(_ data: Data) -> EngineProtocolError? {
    capturedEngineError { try EngineJSONValidator.validate(data) }
}

private func capturedEngineError(_ body: () throws -> Void) -> EngineProtocolError? {
    do {
        try body()
        return nil
    } catch let error as EngineProtocolError {
        return error
    } catch {
        return nil
    }
}

private func decodingEngineError<T: Decodable>(_ type: T.Type, from data: Data) -> EngineProtocolError? {
    capturedEngineError { _ = try JSONDecoder().decode(type, from: data) }
}

private func decodingFails<T: Decodable>(_ type: T.Type, from data: Data) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}

private struct NullableModel: Codable, Equatable {
    @EngineNullable var value: String?

    enum Keys: String, CodingKey, CaseIterable {
        case value
    }

    init(value: String?) {
        _value = EngineNullable(wrappedValue: value)
    }

    init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: Keys.self)
        _value = try container.decode(EngineNullable<String>.self, forKey: .value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(_value, forKey: .value)
    }
}

private struct ParentModel: Decodable {
    let child: ChildModel

    enum Keys: String, CodingKey, CaseIterable {
        case child
    }

    init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: Keys.self)
        child = try container.decode(ChildModel.self, forKey: .child)
    }
}

private struct ChildModel: Decodable {
    let value: Int

    enum Keys: String, CodingKey, CaseIterable {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try engineContainer(decoder, keyedBy: Keys.self)
        value = try container.decode(Int.self, forKey: .value)
    }
}
