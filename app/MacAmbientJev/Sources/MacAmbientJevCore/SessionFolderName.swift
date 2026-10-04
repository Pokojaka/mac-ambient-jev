import Foundation

public struct ParsedSessionFolderName: Sendable, Equatable {
    public let datetimePrefix: String
    public let stem: String
    public let sessionIDPrefix: String
}

public enum SessionFolderName {
    public static func make(
        createdAt: Date, sessionID: UUID, source: SessionSource, timeZone: TimeZone
    ) throws -> String {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SessionFolderNameError.invalidCreationDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.era, .year], from: createdAt)
        guard components.era == 1, let year = components.year, (1...9999).contains(year) else {
            throw SessionFolderNameError.invalidCreationDate
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: createdAt)
        guard validTimestamp(timestamp) else { throw SessionFolderNameError.invalidCreationDate }
        return "\(timestamp)_\(try stem(for: source))_\(sessionID.uuidString.prefix(8).lowercased())"
    }

    public static func parse(_ name: String) throws -> ParsedSessionFolderName {
        let bytes = Array(name.utf8)
        guard bytes.count <= 255, bytes.count > 29, bytes[19] == 95,
              !bytes.contains(0), !name.contains("/"), !name.contains(":"),
              let separator = name.lastIndex(of: "_") else {
            throw SessionFolderNameError.invalidName(name)
        }
        let timestamp = String(decoding: bytes.prefix(19), as: UTF8.self)
        let suffix = String(name[name.index(after: separator)...])
        guard validTimestamp(timestamp),
              suffix.utf8.count == 8,
              suffix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SessionFolderNameError.invalidName(name)
        }
        let stemStart = name.utf8.index(name.utf8.startIndex, offsetBy: 20)
        guard separator > stemStart else { throw SessionFolderNameError.invalidName(name) }
        let stem = String(name[stemStart..<separator])
        guard stem.unicodeScalars.first?.value != 46, stem.utf8.count <= 226 else {
            throw SessionFolderNameError.invalidName(name)
        }
        return ParsedSessionFolderName(datetimePrefix: timestamp, stem: stem, sessionIDPrefix: suffix)
    }

    public static func validate(_ name: String, manifest: SessionManifest) throws {
        let parsed = try parse(name)
        guard parsed.sessionIDPrefix == manifest.sessionID.uuidString.prefix(8).lowercased() else {
            throw SessionFolderNameError.sessionIDPrefixMismatch(folderName: name, sessionID: manifest.sessionID)
        }
        guard parsed.stem == (try stem(for: manifest.source)) else {
            throw SessionFolderNameError.sourceStemMismatch(folderName: name)
        }
    }

    private static func stem(for source: SessionSource) throws -> String {
        let original: String
        switch source {
        case .recording: original = "録音"
        case .imported(let filename):
            guard !filename.contains("\0") else { throw SessionFolderNameError.invalidSource(filename) }
            // Strip only the last extension, without interpreting slashes as path separators.
            if let dot = filename.lastIndex(of: "."), dot != filename.startIndex {
                original = String(filename[..<dot])
            } else {
                original = filename
            }
        }
        var sanitized = original.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if sanitized.unicodeScalars.first?.value == 46 {
            let dotEnd = sanitized.unicodeScalars.index(after: sanitized.unicodeScalars.startIndex)
            sanitized.replaceSubrange(sanitized.startIndex..<dotEnd, with: "-")
        }
        var result = ""
        var byteCount = 0
        for character in sanitized {
            let size = character.utf8.count
            guard byteCount + size <= 226 else { break }
            result.append(character)
            byteCount += size
        }
        guard !result.isEmpty, !result.contains("\0") else {
            throw SessionFolderNameError.invalidSource(original)
        }
        return result
    }

    private static func validTimestamp(_ timestamp: String) -> Bool {
        let bytes = Array(timestamp.utf8)
        guard bytes.count == 19 else { return false }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 95, 13: 45, 16: 45]
        for (index, byte) in bytes.enumerated() {
            if let separator = separators[index] {
                guard byte == separator else { return false }
            } else if !(48...57).contains(byte) { return false }
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let values = [number(0..<4), number(5..<7), number(8..<10), number(11..<13), number(14..<16), number(17..<19)]
        guard (1...9999).contains(values[0]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(era: 1, year: values[0], month: values[1], day: values[2],
                                        hour: values[3], minute: values[4], second: values[5])
        guard let date = calendar.date(from: components) else { return false }
        let actual = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        return actual.era == 1 && actual.year == values[0] && actual.month == values[1]
            && actual.day == values[2] && actual.hour == values[3]
            && actual.minute == values[4] && actual.second == values[5]
    }
}

public enum SessionFolderNameError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case invalidSource(String)
    case invalidCreationDate
    case sessionIDPrefixMismatch(folderName: String, sessionID: UUID)
    case sourceStemMismatch(folderName: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "不正なセッションフォルダ名: \(name)"
        case .invalidSource(let source): "セッション名を作成できない音声ソース: \(source)"
        case .invalidCreationDate: "セッション作成日時をフォルダ名で表現できません"
        case .sessionIDPrefixMismatch(let name, let id): "セッションフォルダ \(name) と ID \(id) が一致しません"
        case .sourceStemMismatch(let name): "セッションフォルダ \(name) と音声ソース名が一致しません"
        }
    }
}
