import Foundation

public enum EngineProtocolError: Error, Equatable, Sendable {
    case invalidUTF8
    case byteOrderMark
    case lineTooLong
    case blankLine
    case invalidJSON(String)
    case nestingTooDeep
    case duplicateKey(String)
    case invalidNumber
    case partialFinalLine
    case closedFramer
    case unsupportedVersion(Int)
    case invalidID
    case invalidOrder(String)
    case oversizedRow(String)
}

public enum EngineJSONValidator {
    public static let maxLineBytes = 1_048_576
    public static let maxDepth = 32

    public static func validate(_ data: Data) throws {
        guard data.count <= maxLineBytes else {
            throw EngineProtocolError.lineTooLong
        }

        let bytes = Array(data)
        guard String(data: data, encoding: .utf8) != nil else {
            throw EngineProtocolError.invalidUTF8
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw EngineProtocolError.byteOrderMark
        }
        if bytes.contains(0x0A) || bytes.contains(0x0D) {
            throw EngineProtocolError.invalidJSON("literal line break")
        }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
            throw EngineProtocolError.blankLine
        }

        var parser = EngineJSONParser(bytes: bytes)
        try parser.validateObject()
    }
}

private struct EngineJSONParser {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func validateObject() throws {
        skipWhitespace()
        guard currentByte == 0x7B else {
            throw EngineProtocolError.invalidJSON("root must be an object")
        }
        try parseObject(depth: 1)
        skipWhitespace()
        guard index == bytes.count else {
            throw EngineProtocolError.invalidJSON("trailing data")
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while currentByte == 0x20 || currentByte == 0x09 {
            index += 1
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= EngineJSONValidator.maxDepth else {
            throw EngineProtocolError.nestingTooDeep
        }
        guard currentByte == 0x7B else {
            throw EngineProtocolError.invalidJSON("expected object")
        }
        index += 1
        skipWhitespace()
        if currentByte == 0x7D {
            index += 1
            return
        }

        var keys = Set<String>()
        while true {
            guard currentByte == 0x22 else {
                throw EngineProtocolError.invalidJSON("expected object key")
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw EngineProtocolError.duplicateKey(key)
            }
            skipWhitespace()
            guard currentByte == 0x3A else {
                throw EngineProtocolError.invalidJSON("expected colon")
            }
            index += 1
            skipWhitespace()
            try parseValue(containerDepth: depth)
            skipWhitespace()
            if currentByte == 0x7D {
                index += 1
                return
            }
            guard currentByte == 0x2C else {
                throw EngineProtocolError.invalidJSON("expected comma or object end")
            }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= EngineJSONValidator.maxDepth else {
            throw EngineProtocolError.nestingTooDeep
        }
        guard currentByte == 0x5B else {
            throw EngineProtocolError.invalidJSON("expected array")
        }
        index += 1
        skipWhitespace()
        if currentByte == 0x5D {
            index += 1
            return
        }

        while true {
            try parseValue(containerDepth: depth)
            skipWhitespace()
            if currentByte == 0x5D {
                index += 1
                return
            }
            guard currentByte == 0x2C else {
                throw EngineProtocolError.invalidJSON("expected comma or array end")
            }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func parseValue(containerDepth: Int) throws {
        skipWhitespace()
        switch currentByte {
        case 0x7B:
            let depth = containerDepth + 1
            guard depth <= EngineJSONValidator.maxDepth else {
                throw EngineProtocolError.nestingTooDeep
            }
            try parseObject(depth: depth)
        case 0x5B:
            let depth = containerDepth + 1
            guard depth <= EngineJSONValidator.maxDepth else {
                throw EngineProtocolError.nestingTooDeep
            }
            try parseArray(depth: depth)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try parseLiteral(Array("true".utf8))
        case 0x66:
            try parseLiteral(Array("false".utf8))
        case 0x4E, 0x49:
            throw EngineProtocolError.invalidNumber
        case 0x6E:
            try parseLiteral(Array("null".utf8))
        case 0x2B, 0x2E:
            throw EngineProtocolError.invalidNumber
        case let byte? where byte == 0x2D || isDigit(byte):
            try parseNumber()
        case nil:
            throw EngineProtocolError.invalidJSON("unexpected end")
        default:
            throw EngineProtocolError.invalidJSON("invalid value")
        }
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              bytes[index..<(index + literal.count)].elementsEqual(literal) else {
            throw EngineProtocolError.invalidJSON("invalid literal")
        }
        index += literal.count
    }

    private mutating func parseNumber() throws {
        let start = index
        if currentByte == 0x2D {
            index += 1
        }

        guard let first = currentByte else {
            throw EngineProtocolError.invalidNumber
        }
        if first == 0x30 {
            index += 1
            if let next = currentByte, isDigit(next) {
                throw EngineProtocolError.invalidNumber
            }
        } else if (0x31...0x39).contains(first) {
            index += 1
            while let byte = currentByte, isDigit(byte) {
                index += 1
            }
        } else {
            throw EngineProtocolError.invalidNumber
        }

        if currentByte == 0x2E {
            index += 1
            guard let byte = currentByte, isDigit(byte) else {
                throw EngineProtocolError.invalidNumber
            }
            repeat { index += 1 } while currentByte.map(isDigit) == true
        }

        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D {
                index += 1
            }
            guard let byte = currentByte, isDigit(byte) else {
                throw EngineProtocolError.invalidNumber
            }
            repeat { index += 1 } while currentByte.map(isDigit) == true
        }

        if let next = currentByte,
           next != 0x20, next != 0x09, next != 0x2C, next != 0x5D, next != 0x7D {
            throw EngineProtocolError.invalidNumber
        }
        let number = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(number), value.isFinite else {
            throw EngineProtocolError.invalidNumber
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private mutating func parseString() throws -> String {
        guard currentByte == 0x22 else {
            throw EngineProtocolError.invalidJSON("expected string")
        }
        let start = index
        index += 1

        while let byte = currentByte {
            if byte == 0x22 {
                index += 1
                let token = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: token)
                } catch {
                    throw EngineProtocolError.invalidJSON("invalid string")
                }
            }
            if byte < 0x20 {
                throw EngineProtocolError.invalidJSON("unescaped control character")
            }
            if byte != 0x5C {
                index += 1
                continue
            }

            index += 1
            guard let escape = currentByte else {
                throw EngineProtocolError.invalidJSON("incomplete escape")
            }
            switch escape {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                index += 1
            case 0x75:
                let codeUnit = try parseHexCodeUnit()
                if (0xD800...0xDBFF).contains(codeUnit) {
                    guard currentByte == 0x5C,
                          index + 1 < bytes.count,
                          bytes[index + 1] == 0x75 else {
                        throw EngineProtocolError.invalidJSON("unpaired high surrogate")
                    }
                    index += 1
                    let low = try parseHexCodeUnit()
                    guard (0xDC00...0xDFFF).contains(low) else {
                        throw EngineProtocolError.invalidJSON("invalid surrogate pair")
                    }
                } else if (0xDC00...0xDFFF).contains(codeUnit) {
                    throw EngineProtocolError.invalidJSON("unpaired low surrogate")
                }
            default:
                throw EngineProtocolError.invalidJSON("invalid escape")
            }
        }
        throw EngineProtocolError.invalidJSON("unterminated string")
    }

    private mutating func parseHexCodeUnit() throws -> UInt16 {
        guard currentByte == 0x75 else {
            throw EngineProtocolError.invalidJSON("expected unicode escape")
        }
        index += 1
        guard index + 4 <= bytes.count else {
            throw EngineProtocolError.invalidJSON("incomplete unicode escape")
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let digit = hexValue(bytes[index]) else {
                throw EngineProtocolError.invalidJSON("invalid unicode escape")
            }
            value = (value << 4) | UInt16(digit)
            index += 1
        }
        return value
    }

    private func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

struct EngineCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

func engineContainer<K: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    keyedBy type: K.Type
) throws -> KeyedDecodingContainer<K> {
    let dynamic = try decoder.container(keyedBy: EngineCodingKey.self)
    let allowedKeys = Set(K.allCases.map(\.stringValue))
    for key in dynamic.allKeys where !allowedKeys.contains(key.stringValue) {
        throw EngineProtocolError.invalidJSON("unknown field: \(key.stringValue)")
    }
    return try decoder.container(keyedBy: type)
}

@propertyWrapper
public struct EngineNullable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else {
            wrappedValue = try container.decode(Value.self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

public struct EngineID: Codable, Hashable, Sendable, Comparable {
    public let value: UInt64

    public var rawValue: String {
        String(value)
    }

    public init(_ value: UInt64) throws {
        guard value > 0 else {
            throw EngineProtocolError.invalidID
        }
        self.value = value
    }

    public init(decimal: String) throws {
        let bytes = Array(decimal.utf8)
        guard let first = bytes.first,
              (0x31...0x39).contains(first),
              bytes.dropFirst().allSatisfy({ (0x30...0x39).contains($0) }),
              let parsed = UInt64(decimal),
              parsed > 0,
              String(parsed) == decimal else {
            throw EngineProtocolError.invalidID
        }
        value = parsed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decimal: String
        do {
            decimal = try container.decode(String.self)
        } catch {
            throw EngineProtocolError.invalidID
        }
        try self.init(decimal: decimal)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }

    public static func < (lhs: EngineID, rhs: EngineID) -> Bool {
        lhs.value < rhs.value
    }
}
