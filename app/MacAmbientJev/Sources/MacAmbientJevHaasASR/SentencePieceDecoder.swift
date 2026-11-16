import Foundation

struct SentencePieceDecoder {
    private struct Piece { let text: String; let score: Float; let type: Int; let byte: UInt8? }
    private enum TokenizerError: Error, CustomStringConvertible {
        case invalidTokenizer(String)
        var description: String {
            switch self { case .invalidTokenizer(let reason): return "Invalid Haas tokenizer: \(reason)" }
        }
    }
    private struct ProtoReader {
        private let buffer: [UInt8]
        private var cursor = 0
        init(_ bytes: [UInt8]) { self.buffer = bytes }
        mutating func nextField() throws -> (number: Int, wire: Int)? {
            guard cursor < buffer.count else { return nil }
            let tag = try varint(), number = tag >> 3, wire = Int(tag & 7)
            guard number > 0, number <= 0x1fff_ffff else { throw TokenizerError.invalidTokenizer("invalid protobuf tag") }
            guard wire == 0 || wire == 1 || wire == 2 || wire == 5 else {
                throw TokenizerError.invalidTokenizer("unsupported protobuf wire type \(wire)")
            }
            return (Int(number), wire)
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0, shift = 0
            while true {
                guard cursor < buffer.count else { throw TokenizerError.invalidTokenizer("truncated varint") }
                let byte = buffer[cursor]; cursor += 1
                if shift == 63 {
                    guard byte & 0xfe == 0 else { throw TokenizerError.invalidTokenizer("varint overflow") }
                    value |= UInt64(byte & 1) << 63
                } else { value |= UInt64(byte & 0x7f) << shift }
                if byte & 0x80 == 0 { return value }
                guard shift < 63 else { throw TokenizerError.invalidTokenizer("varint overflow") }
                shift += 7
            }
        }
        mutating func bytes() throws -> ArraySlice<UInt8> {
            let length = try varint()
            guard length <= UInt64(buffer.count - cursor) else {
                throw TokenizerError.invalidTokenizer("truncated length-delimited field")
            }
            let end = cursor + Int(length), value = buffer[cursor..<end]
            cursor = end
            return value
        }
        mutating func string() throws -> String {
            guard let value = String(bytes: Array(try bytes()), encoding: .utf8) else {
                throw TokenizerError.invalidTokenizer("invalid UTF-8 string")
            }
            return value
        }
        mutating func float() throws -> Float {
            guard buffer.count - cursor >= 4 else { throw TokenizerError.invalidTokenizer("truncated fixed32 field") }
            let bits = UInt32(buffer[cursor]) | UInt32(buffer[cursor + 1]) << 8
                | UInt32(buffer[cursor + 2]) << 16 | UInt32(buffer[cursor + 3]) << 24
            cursor += 4
            return Float(bitPattern: bits)
        }
        mutating func skip(wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1:
                guard buffer.count - cursor >= 8 else { throw TokenizerError.invalidTokenizer("truncated fixed64 field") }
                cursor += 8
            case 2: _ = try bytes()
            case 5:
                guard buffer.count - cursor >= 4 else { throw TokenizerError.invalidTokenizer("truncated fixed32 field") }
                cursor += 4
            default: throw TokenizerError.invalidTokenizer("unsupported protobuf wire type \(wire)")
            }
        }
    }

    private let pieces: [Piece]
    private let unknownSurface: String
    private let addDummyPrefix: Bool
    private let removeExtraWhitespaces: Bool

    init(modelData: Data) throws {
        var reader = ProtoReader(Array(modelData)), parsedPieces: [Piece] = []
        // SentencePiece proto2 schema defaults: unk_surface=" ⁇ ", add_dummy_prefix=true, remove_extra_whitespaces=true.
        var unknownSurface = " ⁇ ", addDummyPrefix = true, removeExtraWhitespaces = true
        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                guard field.wire == 2 else { throw TokenizerError.invalidTokenizer("ModelProto.pieces has the wrong wire type") }
                parsedPieces.append(try Self.parsePiece(reader.bytes()))
            case 2:
                guard field.wire == 2 else { throw TokenizerError.invalidTokenizer("ModelProto.trainer_spec has the wrong wire type") }
                if let surface = try Self.parseTrainerSpec(reader.bytes()) { unknownSurface = surface }
            case 3:
                guard field.wire == 2 else { throw TokenizerError.invalidTokenizer("ModelProto.normalizer_spec has the wrong wire type") }
                let settings = try Self.parseNormalizerSpec(reader.bytes())
                if let value = settings.addDummyPrefix { addDummyPrefix = value }
                if let value = settings.removeExtraWhitespaces { removeExtraWhitespaces = value }
            default: try reader.skip(wire: field.wire)
            }
        }
        guard parsedPieces.count == 3072 else {
            throw TokenizerError.invalidTokenizer("expected 3072 pieces, found \(parsedPieces.count)")
        }
        var unknownCount = 0, seenBytes = [Bool](repeating: false, count: 256)
        for piece in parsedPieces {
            switch piece.type {
            case 1, 4: break
            case 2: unknownCount += 1
            case 6:
                guard let byte = piece.byte else { throw TokenizerError.invalidTokenizer("invalid BYTE piece name") }
                guard !seenBytes[Int(byte)] else { throw TokenizerError.invalidTokenizer("duplicate BYTE piece \(byte)") }
                seenBytes[Int(byte)] = true
            default: throw TokenizerError.invalidTokenizer("unsupported piece type \(piece.type)")
            }
        }
        guard unknownCount == 1 else { throw TokenizerError.invalidTokenizer("expected one UNKNOWN piece, found \(unknownCount)") }
        guard seenBytes.allSatisfy({ $0 }) else { throw TokenizerError.invalidTokenizer("BYTE pieces do not cover all 256 byte values") }
        pieces = parsedPieces
        self.unknownSurface = unknownSurface
        self.addDummyPrefix = addDummyPrefix
        self.removeExtraWhitespaces = removeExtraWhitespaces
    }

    func decode(_ ids: [Int]) -> String {
        var output = "", byteRun: [UInt8] = [], consumedDummy = false
        for id in ids {
            precondition((0..<3072).contains(id), "SentencePiece token ID must be in 0..<3072")
            let piece = pieces[id]
            if piece.type == 6 {
                guard let byte = piece.byte else { preconditionFailure("validated BYTE piece has no byte value") }
                byteRun.append(byte)
                continue
            }
            if !byteRun.isEmpty { output += Self.decodeBytes(byteRun); byteRun.removeAll(keepingCapacity: true) }
            switch piece.type {
            case 1, 4:
                var text = piece.text
                if (addDummyPrefix || removeExtraWhitespaces), output.isEmpty, !consumedDummy, text.hasPrefix("▁") {
                    text.removeFirst()
                    consumedDummy = !removeExtraWhitespaces
                }
                output += text.replacingOccurrences(of: "▁", with: " ")
            case 2: output += unknownSurface
            default: preconditionFailure("validated tokenizer contains an unsupported piece type")
            }
        }
        if !byteRun.isEmpty { output += Self.decodeBytes(byteRun) }
        return output
    }

    private static func parsePiece(_ data: ArraySlice<UInt8>) throws -> Piece {
        var reader = ProtoReader(Array(data)), text: String?, type = 1
        // SentencePiece proto2 schema defaults: score=0 and type=NORMAL (1).
        var score: Float = 0
        while let field = try reader.nextField() {
            switch field.number {
            case 1:
                guard field.wire == 2 else { throw TokenizerError.invalidTokenizer("Piece.piece has the wrong wire type") }
                text = try reader.string()
            case 2:
                guard field.wire == 5 else { throw TokenizerError.invalidTokenizer("Piece.score has the wrong wire type") }
                score = try reader.float()
            case 3:
                guard field.wire == 0 else { throw TokenizerError.invalidTokenizer("Piece.type has the wrong wire type") }
                let rawType = try reader.varint()
                guard rawType <= UInt64(Int.max) else { throw TokenizerError.invalidTokenizer("invalid piece type value") }
                type = Int(rawType)
            default: try reader.skip(wire: field.wire)
            }
        }
        guard let text, !text.isEmpty else { throw TokenizerError.invalidTokenizer("Piece.piece is missing or empty") }
        return Piece(text: text, score: score, type: type, byte: type == 6 ? try Self.parseByteName(text) : nil)
    }

    private static func parseTrainerSpec(_ data: ArraySlice<UInt8>) throws -> String? {
        var reader = ProtoReader(Array(data)), surface: String?
        while let field = try reader.nextField() {
            if field.number == 44 {
                guard field.wire == 2 else { throw TokenizerError.invalidTokenizer("TrainerSpec.unk_surface has the wrong wire type") }
                surface = try reader.string()
            } else { try reader.skip(wire: field.wire) }
        }
        return surface
    }

    private static func parseNormalizerSpec(_ data: ArraySlice<UInt8>) throws -> (addDummyPrefix: Bool?, removeExtraWhitespaces: Bool?) {
        var reader = ProtoReader(Array(data)), addDummyPrefix: Bool?, removeExtraWhitespaces: Bool?
        while let field = try reader.nextField() {
            switch field.number {
            case 3:
                guard field.wire == 0 else { throw TokenizerError.invalidTokenizer("NormalizerSpec.add_dummy_prefix has the wrong wire type") }
                addDummyPrefix = try reader.varint() != 0
            case 4:
                guard field.wire == 0 else { throw TokenizerError.invalidTokenizer("NormalizerSpec.remove_extra_whitespaces has the wrong wire type") }
                removeExtraWhitespaces = try reader.varint() != 0
            default: try reader.skip(wire: field.wire)
            }
        }
        return (addDummyPrefix, removeExtraWhitespaces)
    }

    private static func parseByteName(_ text: String) throws -> UInt8 {
        let bytes = Array(text.utf8)
        guard bytes.count == 6, bytes[0] == 60, bytes[1] == 48, bytes[2] == 120, bytes[5] == 62 else {
            throw TokenizerError.invalidTokenizer("invalid BYTE piece name \(text)")
        }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        guard let high = digit(bytes[3]), let low = digit(bytes[4]) else {
            throw TokenizerError.invalidTokenizer("invalid BYTE piece name \(text)")
        }
        return high << 4 | low
    }

    private static func decodeBytes(_ bytes: [UInt8]) -> String {
        var output = "", index = 0
        while index < bytes.count {
            let first = bytes[index]
            let length: Int
            switch first {
            case 0x00...0x7f: length = 1
            case 0xc2...0xdf: length = 2
            case 0xe0...0xef: length = 3
            case 0xf0...0xf4: length = 4
            default: output.append("\u{fffd}"); index += 1; continue
            }
            if index + length <= bytes.count,
               let scalar = String(bytes: Array(bytes[index..<(index + length)]), encoding: .utf8) {
                output += scalar; index += length
            } else { output.append("\u{fffd}"); index += 1 }
        }
        return output
    }
}
