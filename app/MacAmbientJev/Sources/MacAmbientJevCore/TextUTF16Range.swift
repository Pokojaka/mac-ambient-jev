import Foundation

public struct TextUTF16Range: Codable, Sendable, Hashable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) throws {
        guard start >= 0, end >= start else { throw TextUTF16RangeError.invalidBounds(start: start, end: end) }
        self.start = start
        self.end = end
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: container.decode(Int.self, forKey: .start),
                      end: container.decode(Int.self, forKey: .end))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public func substring(in text: String) throws -> Substring {
        let utf16 = text.utf16
        guard end <= utf16.count,
              let lower16 = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
              let upper16 = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
              let lower = String.Index(lower16, within: text),
              let upper = String.Index(upper16, within: text) else {
            throw TextUTF16RangeError.invalidCharacterBoundary(start: start, end: end)
        }
        return text[lower..<upper]
    }
}

public enum TextUTF16RangeError: Error, Sendable, Equatable {
    case invalidBounds(start: Int, end: Int)
    case invalidCharacterBoundary(start: Int, end: Int)
}
