import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#elseif os(Windows)
import CWindowsSession
import WinSDK
#endif

enum Qwen3ASREmbeddingError: Error, Equatable, CustomStringConvertible {
    case invalidDimensions(vocabSize: Int, hiddenSize: Int)
    case sizeOverflow
    case fileUnreadable(String)
    case sizeMismatch(expected: Int, actual: UInt64)
    case invalidTokenID(Int64)

    var description: String {
        switch self {
        case let .invalidDimensions(vocabSize, hiddenSize):
            "embedding dimensions must be positive: vocabSize=\(vocabSize), hiddenSize=\(hiddenSize)"
        case .sizeOverflow:
            "embedding table byte size overflows Int"
        case let .fileUnreadable(reason):
            "embedding table file cannot be read: \(reason)"
        case let .sizeMismatch(expected, actual):
            "embedding table size mismatch: expected \(expected) bytes, found \(actual)"
        case let .invalidTokenID(id):
            "token id \(id) is outside the embedding vocabulary"
        }
    }
}

private final class ReadOnlyEmbeddingMapping {
    let count: Int
    let pointer: UnsafeMutableRawPointer
    #if os(Windows)
    private let file: UnsafeMutableRawPointer
    private let mapping: UnsafeMutableRawPointer
    #else
    private let descriptor: Int32
    #endif

    init(contentsOf url: URL, expectedByteCount: Int) throws {
        guard url.isFileURL else { throw Qwen3ASREmbeddingError.fileUnreadable("URL is not a file URL") }
        #if os(macOS) || os(Linux)
        var descriptor: Int32 = -1
        var mappedPointer: UnsafeMutableRawPointer?
        var transferred = false
        defer {
            if !transferred {
                if let mappedPointer { _ = munmap(mappedPointer, expectedByteCount) }
                if descriptor >= 0 { _ = close(descriptor) }
            }
        }
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Qwen3ASREmbeddingError.fileUnreadable("filesystem path is unavailable") }
            descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Qwen3ASREmbeddingError.fileUnreadable("open failed (errno \(errno))") }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Qwen3ASREmbeddingError.fileUnreadable("fstat failed (errno \(errno))") }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw Qwen3ASREmbeddingError.fileUnreadable("opened path is not a regular file with a valid size")
        }
        let actualSize = UInt64(info.st_size)
        guard actualSize == UInt64(expectedByteCount) else { throw Qwen3ASREmbeddingError.sizeMismatch(expected: expectedByteCount, actual: actualSize) }
        let rawMapping = mmap(nil, expectedByteCount, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard rawMapping != MAP_FAILED else { throw Qwen3ASREmbeddingError.fileUnreadable("mmap failed (errno \(errno))") }
        guard let rawMapping else { throw Qwen3ASREmbeddingError.fileUnreadable("mmap returned a null pointer") }
        mappedPointer = rawMapping
        self.count = expectedByteCount
        pointer = rawMapping
        self.descriptor = descriptor
        transferred = true
        #elseif os(Windows)
        var openedFile: UnsafeMutableRawPointer?
        var openedMapping: UnsafeMutableRawPointer?
        var mappedPointer: UnsafeMutableRawPointer?
        var transferred = false
        defer {
            if !transferred {
                if let mappedPointer { _ = UnmapViewOfFile(mappedPointer) }
                if let openedMapping { _ = CloseHandle(openedMapping) }
                if let openedFile { msj_close(openedFile) }
            }
        }
        try url.withUnsafeFileSystemRepresentation { nativePath in
            guard let nativePath else { throw Qwen3ASREmbeddingError.fileUnreadable("filesystem path is unavailable") }
            try String(cString: nativePath).withCString(encodedAs: UTF16.self) { path in
                let status = msj_open_readonly_file(path, &openedFile)
                guard status == 0 else { throw Qwen3ASREmbeddingError.fileUnreadable("msj_open_readonly_file failed (Windows \(status))") }
            }
        }
        guard let file = openedFile else { throw Qwen3ASREmbeddingError.fileUnreadable("msj_open_readonly_file returned no handle") }
        var fileSize: Int64 = 0
        let sizeStatus = msj_size(file, &fileSize)
        guard sizeStatus == 0 else { throw Qwen3ASREmbeddingError.fileUnreadable("msj_size failed (Windows \(sizeStatus))") }
        guard fileSize >= 0 else { throw Qwen3ASREmbeddingError.fileUnreadable("msj_size returned a negative file size") }
        let actualSize = UInt64(fileSize)
        guard actualSize == UInt64(expectedByteCount) else { throw Qwen3ASREmbeddingError.sizeMismatch(expected: expectedByteCount, actual: actualSize) }
        guard let mapping = CreateFileMappingW(file, nil, DWORD(PAGE_READONLY), 0, 0, nil) else {
            throw Qwen3ASREmbeddingError.fileUnreadable("CreateFileMappingW failed (Windows \(GetLastError()))")
        }
        openedMapping = mapping
        guard let view = MapViewOfFile(mapping, DWORD(FILE_MAP_READ), 0, 0, SIZE_T(expectedByteCount)) else {
            throw Qwen3ASREmbeddingError.fileUnreadable("MapViewOfFile failed (Windows \(GetLastError()))")
        }
        mappedPointer = view
        self.count = expectedByteCount
        pointer = view
        self.file = file
        self.mapping = mapping
        transferred = true
        #else
        fatalError("Unsupported platform")
        #endif
    }

    deinit {
        #if os(macOS) || os(Linux)
        _ = munmap(pointer, count)
        _ = close(descriptor)
        #elseif os(Windows)
        _ = UnmapViewOfFile(pointer)
        _ = CloseHandle(mapping)
        msj_close(file)
        #endif
    }

    #if os(Windows)
    func copyRow(at offset: Int, to destination: UnsafeMutableRawPointer, byteCount: Int) throws {
        let status = withExtendedLifetime(self) {
            msj_copy_mapped(pointer.advanced(by: offset), destination, byteCount)
        }
        guard status == 0 else {
            throw Qwen3ASREmbeddingError.fileUnreadable("mapped row copy failed (Windows \(status))")
        }
    }
    #endif
}

struct Qwen3ASREmbeddingTable {
    let vocabSize: Int
    let hiddenSize: Int

    private let storage: ReadOnlyEmbeddingMapping

    init(contentsOf url: URL, vocabSize: Int, hiddenSize: Int) throws {
        guard vocabSize > 0, hiddenSize > 0 else {
            throw Qwen3ASREmbeddingError.invalidDimensions(vocabSize: vocabSize, hiddenSize: hiddenSize)
        }
        let (elementCount, elementCountOverflow) = vocabSize.multipliedReportingOverflow(by: hiddenSize)
        let (expectedByteCount, byteCountOverflow) = elementCount.multipliedReportingOverflow(by: 2)
        guard !elementCountOverflow, !byteCountOverflow else {
            throw Qwen3ASREmbeddingError.sizeOverflow
        }

        self.vocabSize = vocabSize
        self.hiddenSize = hiddenSize
        storage = try ReadOnlyEmbeddingMapping(contentsOf: url, expectedByteCount: expectedByteCount)
    }

    func row(_ id: Int64) throws -> [Float] {
        guard id >= 0, UInt64(id) < UInt64(vocabSize) else {
            throw Qwen3ASREmbeddingError.invalidTokenID(id)
        }
        let (rowByteCount, rowSizeOverflow) = hiddenSize.multipliedReportingOverflow(by: 2)
        guard !rowSizeOverflow else { throw Qwen3ASREmbeddingError.sizeOverflow }
        let rowID = Int(id)
        let (byteOffset, offsetOverflow) = rowID.multipliedReportingOverflow(by: rowByteCount)
        let (endOffset, endOverflow) = byteOffset.addingReportingOverflow(rowByteCount)
        guard !offsetOverflow, !endOverflow else { throw Qwen3ASREmbeddingError.sizeOverflow }
        guard endOffset <= storage.count else {
            throw Qwen3ASREmbeddingError.fileUnreadable("mapped row exceeds the file")
        }

        #if os(Windows)
        let rowBytes = UnsafeMutableRawPointer.allocate(byteCount: rowByteCount, alignment: 1)
        defer { rowBytes.deallocate() }
        try storage.copyRow(at: byteOffset, to: rowBytes, byteCount: rowByteCount)
        return Self.decode(UnsafeRawBufferPointer(start: rowBytes, count: rowByteCount), hiddenSize: hiddenSize)
        #else
        return withExtendedLifetime(storage) {
            let rowBytes = UnsafeRawBufferPointer(
                start: storage.pointer.advanced(by: byteOffset), count: rowByteCount
            )
            return Self.decode(rowBytes, hiddenSize: hiddenSize)
        }
        #endif
    }

    private static func decode(_ bytes: UnsafeRawBufferPointer, hiddenSize: Int) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(hiddenSize)
        for column in 0..<hiddenSize {
            let offset = column * 2
            let halfBits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            result.append(float(fromFloat16Bits: halfBits))
        }
        return result
    }

    private static func float(fromFloat16Bits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = UInt32(bits & 0x03FF)

        let floatBits: UInt32
        switch exponent {
        case 0:
            if fraction == 0 {
                floatBits = sign
            } else {
                let leadingBit = 31 - fraction.leadingZeroBitCount
                let unbiasedExponent = leadingBit - 24
                let normalizedFraction = fraction - (UInt32(1) << leadingBit)
                floatBits = sign
                    | (UInt32(unbiasedExponent + 127) << 23)
                    | (normalizedFraction << (23 - leadingBit))
            }
        case 0x1F:
            floatBits = sign | 0x7F80_0000 | (fraction << 13)
        default:
            floatBits = sign | (UInt32(exponent + 112) << 23) | (fraction << 13)
        }
        return Float(bitPattern: floatBits)
    }
}
