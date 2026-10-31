import Foundation

/// Random-access reads over an MP4 file. Implementations must fail rather than return short data.
public protocol MP4RandomAccessSource {
    var length: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

public struct MP4DataSource: MP4RandomAccessSource {
    private let data: Data
    public init(_ data: Data) { self.data = data }
    public var length: UInt64 { UInt64(data.count) }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= length, UInt64(count) <= length - offset else { throw MP4PrimingError.truncated }
        let start = data.startIndex + Int(offset)
        return data.subdata(in: start..<start + count)
    }
}

public struct MP4FileHandleSource: MP4RandomAccessSource {
    private let handle: FileHandle
    public let length: UInt64
    public init(handle: FileHandle) throws {
        self.handle = handle
        length = try handle.seekToEnd()
    }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= length, UInt64(count) <= length - offset else { throw MP4PrimingError.truncated }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw MP4PrimingError.truncated
        }
        return data
    }
}

public enum MP4PrimingError: LocalizedError, Equatable {
    case truncated
    case invalidBox(String)
    case unsupported(String)
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: return "M4A のボックスがファイル末尾を超えています。"
        case .invalidBox(let detail): return "M4A の priming 情報が不正です: \(detail)"
        case .unsupported(let detail): return "M4A の priming 情報を解釈できません: \(detail)"
        case .mismatch(let detail): return "M4A の priming 情報とデコード結果が一致しません: \(detail)"
        }
    }
}

/// The one source of AAC priming and end padding in an MP4 file.
/// An edit list wins; `iTunSMPB` is read only when there is no edit list; with neither there is nothing to trim.
public enum MP4Priming: Equatable {
    case none
    /// `segmentDuration` is nil when a fragmented file (`mvex`) records 0 because the length was unknown: the edit runs to the end of the decode.
    case editList(mediaTime: UInt64, segmentDuration: UInt64?, movieTimescale: UInt32, mediaTimescale: UInt32)
    case iTunSMPB(priming: UInt64, validFrames: UInt64)

    /// The decoded-frame range to keep, or nil when the file is imported unchanged.
    public func window(sampleRate: UInt32) throws -> AACTrimWindow? {
        switch self {
        case .none:
            return nil
        case .iTunSMPB(let priming, let validFrames):
            guard validFrames > 0 else { throw MP4PrimingError.invalidBox("iTunSMPB の有効フレーム数が 0 です。") }
            guard priming <= UInt64(Int64.max), validFrames <= UInt64(Int64.max),
                  priming + validFrames <= UInt64(Int64.max) else {
                throw MP4PrimingError.invalidBox("iTunSMPB の値が大きすぎます。")
            }
            return AACTrimWindow(start: Int64(priming), length: Int64(validFrames), slack: 0)
        case .editList(let mediaTime, let duration, let movieTimescale, let mediaTimescale):
            guard movieTimescale > 0, mediaTimescale > 0 else {
                throw MP4PrimingError.invalidBox("timescale が 0 です。")
            }
            guard mediaTimescale == sampleRate else {
                throw MP4PrimingError.mismatch("メディア timescale \(mediaTimescale) とサンプルレート \(sampleRate) が異なります。")
            }
            guard let duration else {
                guard mediaTime <= UInt64(Int64.max) else { throw MP4PrimingError.invalidBox("edit list の値が大きすぎます。") }
                return AACTrimWindow(start: Int64(mediaTime), length: nil, slack: 0)
            }
            let (product, overflow) = duration.multipliedReportingOverflow(by: UInt64(sampleRate))
            guard !overflow else { throw MP4PrimingError.invalidBox("edit list の長さがオーバーフローします。") }
            let length = product / UInt64(movieTimescale)
            guard length > 0 else { throw MP4PrimingError.invalidBox("edit list の長さが 0 です。") }
            guard mediaTime <= UInt64(Int64.max), length <= UInt64(Int64.max),
                  mediaTime + length <= UInt64(Int64.max) else {
                throw MP4PrimingError.invalidBox("edit list の値が大きすぎます。")
            }
            // A movie timescale coarser than the sample rate rounds the duration by up to one movie tick.
            let tick = (UInt64(sampleRate) + UInt64(movieTimescale) - 1) / UInt64(movieTimescale)
            return AACTrimWindow(start: Int64(mediaTime), length: Int64(length), slack: Int64(tick))
        }
    }
}

/// Keeps decoded frames `start ..< start + length`, or `start...` to the end of the decode when `length` is nil.
/// The decode may end up to `slack` frames early.
public struct AACTrimWindow: Equatable {
    public let start: Int64
    public let length: Int64?
    public let slack: Int64

    public var end: Int64? { length.map { start + $0 } }

    public func checkDecodedTotal(_ total: Int64) throws {
        guard total > start, total + slack >= (end ?? 0) else {
            throw MP4PrimingError.mismatch("デコードしたフレーム数 \(total) が priming \(start) + 有効フレーム \(length.map(String.init) ?? "残り全部") に足りません。")
        }
    }
}

/// Applies an `AACTrimWindow` to decoded chunks of any size, the same way on every platform.
public struct AACTrimCursor {
    public let window: AACTrimWindow?
    public private(set) var decodedFrames: Int64 = 0
    /// True once the window's end has been reached; later frames are not needed.
    public private(set) var isComplete = false

    public init(window: AACTrimWindow?) { self.window = window }

    /// Counts a chunk of `frameCount` decoded frames and returns the part of it to keep (possibly empty).
    public mutating func accept(frameCount: Int) throws -> Range<Int> {
        let first = decodedFrames
        let (next, overflow) = first.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { throw MP4PrimingError.invalidBox("デコードした累積フレーム数が上限を超えました。") }
        decodedFrames = next
        guard let window else { return 0..<frameCount }
        let keepStart = max(first, window.start)
        let keepEnd = min(next, window.end ?? next)
        if let end = window.end, next >= end { isComplete = true }
        guard keepEnd > keepStart else { return 0..<0 }
        return Int(keepStart - first)..<Int(keepEnd - first)
    }

    /// Call when the decoder ends before the window does.
    public func finish() throws {
        try window?.checkDecodedTotal(decodedFrames)
    }
}

public enum MP4PrimingParser {
    private static let maxBoxesPerContainer = 100_000
    private static let maxLeafBytes = 4_096

    private struct Box {
        let type: String
        let payload: UInt64
        let end: UInt64
    }

    public static func parse(_ source: some MP4RandomAccessSource) throws -> MP4Priming {
        var movieTimescale: UInt32?
        var editList: (mediaTime: UInt64, duration: UInt64)?
        var mediaTimescale: UInt32?
        var udtas: [Box] = []
        var fragmented = false
        var sawAudioTrack = false

        guard let moov = try boxes(in: 0..<source.length, source).first(where: { $0.type == "moov" }) else {
            throw MP4PrimingError.invalidBox("moov がありません。")
        }
        for box in try boxes(in: moov.payload..<moov.end, source) {
            switch box.type {
            case "mvhd":
                let body = try leaf(box, source, minimum: 16)
                let version = body[0]
                guard version <= 1 else { throw MP4PrimingError.unsupported("mvhd version \(version)") }
                guard body.count >= (version == 1 ? 24 : 16) else { throw MP4PrimingError.invalidBox("mvhd が短すぎます。") }
                movieTimescale = u32(body, version == 1 ? 20 : 12, need: version == 1 ? 24 : 16)
            case "trak":
                guard !sawAudioTrack, try isAudioTrack(box, source) else { continue }
                sawAudioTrack = true
                for child in try boxes(in: box.payload..<box.end, source) {
                    if child.type == "edts" {
                        editList = try parseEdts(child, source)
                    } else if child.type == "mdia" {
                        mediaTimescale = try mdhdTimescale(child, source)
                    }
                }
            case "mvex":
                fragmented = true
            case "udta":
                udtas.append(box)
            default:
                break
            }
        }
        guard sawAudioTrack else { throw MP4PrimingError.invalidBox("音声トラックがありません。") }

        if let editList {
            guard let movieTimescale, let mediaTimescale else {
                throw MP4PrimingError.invalidBox("edit list に必要な timescale がありません。")
            }
            if editList.duration == 0 && !fragmented {
                throw MP4PrimingError.invalidBox("edit list の長さが 0 です。")
            }
            return .editList(mediaTime: editList.mediaTime, segmentDuration: editList.duration == 0 ? nil : editList.duration,
                             movieTimescale: movieTimescale, mediaTimescale: mediaTimescale)
        }
        // udta is read only without an edit list, so an unrelated malformed udta cannot fail an elst import.
        var smpb: Box?
        for udta in udtas { smpb = try findSMPB(in: udta, source) ?? smpb }
        guard let smpb else { return .none }
        return try parseSMPB(smpb, source)
    }

    private static func boxes(in range: Range<UInt64>, _ source: some MP4RandomAccessSource) throws -> [Box] {
        guard range.upperBound <= source.length else { throw MP4PrimingError.truncated }
        var result: [Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard result.count < maxBoxesPerContainer else { throw MP4PrimingError.invalidBox("ボックス数が多すぎます。") }
            guard range.upperBound - offset >= 8 else { throw MP4PrimingError.truncated }
            let header = try source.read(at: offset, count: 8)
            var size = UInt64(u32(header, 0, need: 8))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard range.upperBound - offset >= 16 else { throw MP4PrimingError.truncated }
                let large = try source.read(at: offset + 8, count: 8)
                size = large.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= headerSize else { throw MP4PrimingError.invalidBox("\(type) のサイズが小さすぎます。") }
            let (end, overflow) = offset.addingReportingOverflow(size)
            guard !overflow, end <= range.upperBound else {
                throw MP4PrimingError.invalidBox("\(type) のサイズが親ボックスを超えています。")
            }
            result.append(Box(type: type, payload: offset + headerSize, end: end))
            offset = end
        }
        return result
    }

    private static func leaf(_ box: Box, _ source: some MP4RandomAccessSource, minimum: Int) throws -> Data {
        let size = box.end - box.payload
        guard size >= UInt64(minimum) else { throw MP4PrimingError.invalidBox("\(box.type) が短すぎます。") }
        guard size <= UInt64(maxLeafBytes) else { throw MP4PrimingError.invalidBox("\(box.type) が大きすぎます。") }
        return Data(try source.read(at: box.payload, count: Int(size)))
    }

    private static func u32(_ data: Data, _ offset: Int, need: Int) -> UInt32 {
        precondition(data.count >= need)
        return data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data[data.startIndex + offset..<data.startIndex + offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func isAudioTrack(_ trak: Box, _ source: some MP4RandomAccessSource) throws -> Bool {
        guard let mdia = try boxes(in: trak.payload..<trak.end, source).first(where: { $0.type == "mdia" }),
              let hdlr = try boxes(in: mdia.payload..<mdia.end, source).first(where: { $0.type == "hdlr" }) else {
            return false
        }
        let body = try leaf(hdlr, source, minimum: 12)
        return String(decoding: body[8..<12], as: UTF8.self) == "soun"
    }

    private static func mdhdTimescale(_ mdia: Box, _ source: some MP4RandomAccessSource) throws -> UInt32 {
        guard let mdhd = try boxes(in: mdia.payload..<mdia.end, source).first(where: { $0.type == "mdhd" }) else {
            throw MP4PrimingError.invalidBox("mdhd がありません。")
        }
        let body = try leaf(mdhd, source, minimum: 16)
        let version = body[0]
        guard version <= 1 else { throw MP4PrimingError.unsupported("mdhd version \(version)") }
        guard body.count >= (version == 1 ? 24 : 16) else { throw MP4PrimingError.invalidBox("mdhd が短すぎます。") }
        return u32(body, version == 1 ? 20 : 12, need: version == 1 ? 24 : 16)
    }

    private static func parseEdts(_ edts: Box, _ source: some MP4RandomAccessSource) throws -> (mediaTime: UInt64, duration: UInt64) {
        guard let elst = try boxes(in: edts.payload..<edts.end, source).first(where: { $0.type == "elst" }) else {
            throw MP4PrimingError.invalidBox("edts に elst がありません。")
        }
        let body = try leaf(elst, source, minimum: 8)
        let version = body[0]
        guard version <= 1 else { throw MP4PrimingError.unsupported("elst version \(version)") }
        let entryCount = u32(body, 4, need: 8)
        guard entryCount == 1 else { throw MP4PrimingError.unsupported("elst のエントリ数が \(entryCount) です（1 のみ対応）。") }
        let entrySize = version == 1 ? 20 : 12
        guard body.count == 8 + entrySize else { throw MP4PrimingError.invalidBox("elst のサイズがエントリ数と一致しません。") }
        let duration: UInt64
        let mediaTime: Int64
        if version == 1 {
            duration = u64(body, 8)
            mediaTime = Int64(bitPattern: u64(body, 16))
        } else {
            duration = UInt64(u32(body, 8, need: 20))
            mediaTime = Int64(Int32(bitPattern: u32(body, 12, need: 20)))
        }
        let rate = u32(body, 8 + entrySize - 4, need: 8 + entrySize)
        guard rate == 0x0001_0000 else { throw MP4PrimingError.unsupported("elst の再生速度が 1.0 ではありません。") }
        guard mediaTime >= 0 else { throw MP4PrimingError.unsupported("elst に空の edit（media_time \(mediaTime)）があります。") }
        return (UInt64(mediaTime), duration)
    }

    private static func findSMPB(in udta: Box, _ source: some MP4RandomAccessSource) throws -> Box? {
        guard let meta = try boxes(in: udta.payload..<udta.end, source).first(where: { $0.type == "meta" }),
              meta.end - meta.payload >= 4,
              let ilst = try boxes(in: meta.payload + 4..<meta.end, source).first(where: { $0.type == "ilst" }) else {
            return nil
        }
        for item in try boxes(in: ilst.payload..<ilst.end, source) where item.type == "----" {
            let parts = try boxes(in: item.payload..<item.end, source)
            guard let name = parts.first(where: { $0.type == "name" }) else { continue }
            let nameBody = try leaf(name, source, minimum: 4)
            if String(decoding: nameBody.dropFirst(4), as: UTF8.self) == "iTunSMPB" {
                return parts.first(where: { $0.type == "data" })
            }
        }
        return nil
    }

    private static func parseSMPB(_ data: Box, _ source: some MP4RandomAccessSource) throws -> MP4Priming {
        let body = try leaf(data, source, minimum: 8)
        guard u32(body, 0, need: 8) == 1 else { throw MP4PrimingError.invalidBox("iTunSMPB が UTF-8 テキストではありません。") }
        let fields = String(decoding: body.dropFirst(8), as: UTF8.self).split(separator: " ")
        guard fields.count >= 4, fields[1].count == 8, fields[3].count == 16,
              let priming = UInt64(fields[1], radix: 16), let valid = UInt64(fields[3], radix: 16) else {
            throw MP4PrimingError.invalidBox("iTunSMPB の形式が不正です。")
        }
        return .iTunSMPB(priming: priming, validFrames: valid)
    }
}
