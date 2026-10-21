import Foundation

public enum CanonicalCAFError: LocalizedError, Equatable {
    case notCAF
    case unsupportedVersion(UInt16)
    case unsupportedFileFlags(UInt16)
    case truncated(offset: UInt64)
    case invalidChunkSize(chunk: String, size: Int64)
    case unfinalizedData
    case missingDescription
    case invalidDescriptionSize(Int64)
    case noncanonicalFormat(String)
    case missingData
    case dataShorterThanDeclared(declared: Int64, available: UInt64)
    case invalidDataLayout(String)

    public var errorDescription: String? {
        switch self {
        case .notCAF: "CAFファイルではありません"
        case .unsupportedVersion(let version): "未対応のCAFバージョンです: \(version)"
        case .unsupportedFileFlags(let flags): "CAFファイルのflagsが0ではありません: \(flags)"
        case .truncated(let offset): "CAFファイルが位置\(offset)で途中終了しています"
        case .invalidChunkSize(let chunk, let size): "CAFチャンク'\(chunk)'のサイズが不正です: \(size)"
        case .unfinalizedData: "CAFのdataチャンクのサイズが確定していません（-1）"
        case .missingDescription: "CAFの先頭チャンクがdescではありません"
        case .invalidDescriptionSize(let size): "CAFのdescチャンクは32 bytesである必要があります: \(size)"
        case .noncanonicalFormat(let detail): "内部音声は16,000 Hz・mono・float32リトルエンディアンPCMである必要があります: \(detail)"
        case .missingData: "CAFにdataチャンクがありません"
        case .dataShorterThanDeclared(let declared, let available):
            "CAFのdataチャンクが宣言サイズ\(declared) bytesより短く、\(available) bytesしかありません"
        case .invalidDataLayout(let detail): "CAFのdataチャンクが不正です: \(detail)"
        }
    }
}

/// Reads exact samples from the canonical 16 kHz mono Float32 CAF that the Mac exporter writes
/// (`desc`, `free`, `data` with an exact size). Anything else is an error; nothing is converted.
///
/// Samples are returned as stored. Non-finite values are not rejected here; consumers that
/// require finite samples validate what they read.
public final class CanonicalCAFReader: @unchecked Sendable {
    public let sampleCount: Int64

    private static let headerSize: UInt64 = 8
    private static let chunkHeaderSize: UInt64 = 12
    private static let descriptionSize: Int64 = 32
    private static let editCountSize: UInt64 = 4
    private static let bytesPerFrame: UInt64 = 4
    /// IsFloat (1) | IsLittleEndian (2), per the CAF `desc` chunk's format flags.
    private static let floatLittleEndianFlags: UInt32 = 3

    private let handle: FileHandle
    private let firstSampleOffset: UInt64
    private let lock = NSLock()

    public init(url: URL, sessionURL: URL) throws {
        let handle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
        do {
            let layout = try Self.parse(handle)
            self.handle = handle
            self.sampleCount = layout.sampleCount
            self.firstSampleOffset = layout.firstSampleOffset
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    /// Reads exactly `frames`; a range outside `0...sampleCount` is an error.
    public func readSamples(frames: Range<Int64>) throws -> [Float] {
        guard frames.lowerBound >= 0, frames.upperBound <= sampleCount else {
            throw ProcessingTimelineReaderError.invalidFrameRange
        }
        guard !frames.isEmpty else { return [] }
        let count = Int(frames.upperBound - frames.lowerBound)
        lock.lock()
        defer { lock.unlock() }
        let offset = firstSampleOffset + UInt64(frames.lowerBound) * Self.bytesPerFrame
        let bytes = try Self.read(handle, offset: offset, count: count * Int(Self.bytesPerFrame))
        return bytes.withUnsafeBytes { raw in
            (0..<count).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }

    private static func parse(_ handle: FileHandle) throws -> (sampleCount: Int64, firstSampleOffset: UInt64) {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= headerSize else { throw CanonicalCAFError.notCAF }
        let header = try read(handle, offset: 0, count: Int(headerSize))
        guard header.prefix(4).elementsEqual("caff".utf8) else { throw CanonicalCAFError.notCAF }
        let version = bigEndianUInt16(header, at: 4)
        guard version == 1 else { throw CanonicalCAFError.unsupportedVersion(version) }
        let flags = bigEndianUInt16(header, at: 6)
        guard flags == 0 else { throw CanonicalCAFError.unsupportedFileFlags(flags) }

        var offset = headerSize
        var sawDescription = false
        while true {
            let remaining = fileSize - offset
            if remaining == 0 { throw sawDescription ? CanonicalCAFError.missingData : .missingDescription }
            guard remaining >= chunkHeaderSize else { throw CanonicalCAFError.truncated(offset: fileSize) }
            let chunkHeader = try read(handle, offset: offset, count: Int(chunkHeaderSize))
            let type = String(decoding: chunkHeader.prefix(4), as: UTF8.self)
            let size = Int64(bitPattern: bigEndianUInt64(chunkHeader, at: 4))
            let bodyOffset = offset + chunkHeaderSize
            let available = fileSize - bodyOffset

            if type == "data" {
                guard sawDescription else { throw CanonicalCAFError.missingDescription }
                // Size -1 means "to end of file" and marks a writer that never finalized.
                guard size != -1 else { throw CanonicalCAFError.unfinalizedData }
                guard size >= 0 else { throw CanonicalCAFError.invalidChunkSize(chunk: type, size: size) }
                guard UInt64(size) <= available else {
                    throw CanonicalCAFError.dataShorterThanDeclared(declared: size, available: available)
                }
                guard UInt64(size) >= editCountSize else {
                    throw CanonicalCAFError.invalidDataLayout("編集カウントを含められません")
                }
                let payload = UInt64(size) - editCountSize
                guard payload % bytesPerFrame == 0 else {
                    throw CanonicalCAFError.invalidDataLayout("PCM payloadが4 bytesの倍数ではありません")
                }
                guard let frames = Int64(exactly: payload / bytesPerFrame) else {
                    throw CanonicalCAFError.invalidDataLayout("フレーム数がInt64を超えます")
                }
                return (frames, bodyOffset + editCountSize)
            }

            guard size >= 0 else { throw CanonicalCAFError.invalidChunkSize(chunk: type, size: size) }
            guard UInt64(size) <= available else { throw CanonicalCAFError.truncated(offset: fileSize) }

            if !sawDescription {
                guard type == "desc" else { throw CanonicalCAFError.missingDescription }
                guard size == descriptionSize else { throw CanonicalCAFError.invalidDescriptionSize(size) }
                try validateDescription(try read(handle, offset: bodyOffset, count: Int(descriptionSize)))
                sawDescription = true
            } else if type == "desc" {
                throw CanonicalCAFError.noncanonicalFormat("descチャンクが複数あります")
            }
            offset = bodyOffset + UInt64(size)
        }
    }

    private static func validateDescription(_ body: [UInt8]) throws {
        let sampleRate = Double(bitPattern: bigEndianUInt64(body, at: 0))
        let formatID = String(decoding: body[8..<12], as: UTF8.self)
        let formatFlags = bigEndianUInt32(body, at: 12)
        let bytesPerPacket = bigEndianUInt32(body, at: 16)
        let framesPerPacket = bigEndianUInt32(body, at: 20)
        let channels = bigEndianUInt32(body, at: 24)
        let bitsPerChannel = bigEndianUInt32(body, at: 28)
        guard sampleRate == CanonicalAudio.sampleRate else {
            throw CanonicalCAFError.noncanonicalFormat("sample rate \(sampleRate)")
        }
        guard formatID == "lpcm" else { throw CanonicalCAFError.noncanonicalFormat("format \(formatID)") }
        guard formatFlags == floatLittleEndianFlags else {
            throw CanonicalCAFError.noncanonicalFormat("format flags \(formatFlags)")
        }
        guard channels == UInt32(CanonicalAudio.channelCount) else {
            throw CanonicalCAFError.noncanonicalFormat("channels \(channels)")
        }
        guard bitsPerChannel == 32 else { throw CanonicalCAFError.noncanonicalFormat("bits \(bitsPerChannel)") }
        guard bytesPerPacket == UInt32(bytesPerFrame), framesPerPacket == 1 else {
            throw CanonicalCAFError.noncanonicalFormat("packet \(bytesPerPacket) bytes / \(framesPerPacket) frames")
        }
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> [UInt8] {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CanonicalCAFError.truncated(offset: offset + UInt64(data.count)) }
        return [UInt8](data)
    }

    private static func bigEndianUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        bytes[index..<index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func bigEndianUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        bytes[index..<index + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
