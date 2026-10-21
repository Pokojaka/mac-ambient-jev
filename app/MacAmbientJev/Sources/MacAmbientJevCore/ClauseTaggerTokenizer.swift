import Foundation

public struct ClauseTaggerTokenizer: Sendable {
    private let tokenizer: ClauseTaggerUnigram
    private let vocabularyIDs: [Data: Int]
    private let vocabularyScalars: Set<Unicode.Scalar>
    private let byteFallbackIDs: [UInt8: Int]
    private let addedTokens: [AddedToken]

    private struct AddedToken: Sendable {
        let content: String
        let scalars: [UInt32]
    }

    private struct SourceScalar {
        let scalar: Unicode.Scalar
        let range: TextUTF16Range
    }

    public init(tokenizerURL: URL, expectedSHA256: String) throws {
        let tokenizerBytes: Data
        do {
            tokenizerBytes = try Data(contentsOf: tokenizerURL)
        } catch {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json を読み込めません: \(error.localizedDescription)"
            )
        }

        let actualSHA256 = FileSHA256.hexDigest(of: tokenizerBytes)
        guard actualSHA256 == expectedSHA256 else {
            throw ClauseTaggerTokenizerError.invalidConfiguration(
                "tokenizer.json の SHA-256 が一致しません (expected: \(expectedSHA256), actual: \(actualSHA256))。"
            )
        }

        let configuration = try ClauseTaggerTokenizerConfiguration(data: tokenizerBytes)
        let tokenizer = ClauseTaggerUnigram(configuration: configuration)

        var vocabularyIDs: [Data: Int] = [:]
        var vocabularyScalars: Set<Unicode.Scalar> = []
        vocabularyIDs.reserveCapacity(configuration.vocabulary.count)

        for (id, entry) in configuration.vocabulary.enumerated() {
            let tokenBytes = Data(entry.token.utf8)
            vocabularyIDs[tokenBytes] = id
            vocabularyScalars.formUnion(entry.token.unicodeScalars)
        }

        var byteFallbackIDs: [UInt8: Int] = [:]
        byteFallbackIDs.reserveCapacity(256)
        for byte in 0..<256 {
            let tokenString = String(format: "<0x%02X>", byte)
            let token = Data(tokenString.utf8)
            guard let id = vocabularyIDs[token] else {
                throw ClauseTaggerTokenizerError.invalidConfiguration(
                    "tokenizer.json の語彙にバイトフォールバックトークン \(tokenString) がありません。"
                )
            }
            byteFallbackIDs[UInt8(byte)] = id
        }

        let addedTokens = configuration.addedTokens.enumerated()
            .map { item in
                (
                    index: item.offset,
                    token: AddedToken(
                        content: item.element.content,
                        scalars: item.element.content.unicodeScalars.map(\.value)
                    )
                )
            }
            .sorted {
                if $0.token.scalars.count != $1.token.scalars.count {
                    return $0.token.scalars.count > $1.token.scalars.count
                }
                return $0.index < $1.index
            }
            .map { $0.token }

        self.tokenizer = tokenizer
        self.vocabularyIDs = vocabularyIDs
        self.vocabularyScalars = vocabularyScalars
        self.byteFallbackIDs = byteFallbackIDs
        self.addedTokens = addedTokens
    }

    public func encodePiece(_ text: String) throws -> [ClauseTaggerToken] {
        guard !text.isEmpty else { return [] }

        let scalars = Array(text.unicodeScalars)
        let sourceScalars = try makeSourceScalars(scalars)
        var result: [ClauseTaggerToken] = []
        var ordinaryRun: [SourceScalar] = []
        var offset = 0

        while offset < scalars.count {
            if let addedToken = addedToken(matching: scalars, at: offset) {
                result += try encodeOrdinary(ordinaryRun)
                ordinaryRun.removeAll(keepingCapacity: true)

                let end = offset + addedToken.scalars.count
                result += try encodeKnownText(
                    addedToken.content,
                    sourceRanges: sourceScalars[offset..<end].map(\.range)
                )
                offset = end
            } else {
                ordinaryRun.append(sourceScalars[offset])
                offset += 1
            }
        }

        result += try encodeOrdinary(ordinaryRun)
        return result
    }

    private func makeSourceScalars(_ scalars: [Unicode.Scalar]) throws -> [SourceScalar] {
        var sourceScalars: [SourceScalar] = []
        sourceScalars.reserveCapacity(scalars.count)
        var offsetUTF16 = 0
        for scalar in scalars {
            let endUTF16 = offsetUTF16 + utf16Width(of: scalar)
            sourceScalars.append(SourceScalar(
                scalar: scalar,
                range: try TextUTF16Range(start: offsetUTF16, end: endUTF16)
            ))
            offsetUTF16 = endUTF16
        }
        return sourceScalars
    }

    private func addedToken(matching scalars: [Unicode.Scalar], at offset: Int) -> AddedToken? {
        for token in addedTokens where offset + token.scalars.count <= scalars.count {
            var matches = true
            for (index, scalarValue) in token.scalars.enumerated() {
                if scalars[offset + index].value != scalarValue {
                    matches = false
                    break
                }
            }
            if matches { return token }
        }
        return nil
    }

    private func encodeOrdinary(_ sourceScalars: [SourceScalar]) throws -> [ClauseTaggerToken] {
        guard !sourceScalars.isEmpty else { return [] }

        var result: [ClauseTaggerToken] = []
        var knownRun = String.UnicodeScalarView()
        var knownRunRanges: [TextUTF16Range] = []
        var unknownRunBytes: [UInt8] = []
        var unknownRunStartUTF16: Int?
        var unknownRunEndUTF16: Int?

        func flushKnownRun() throws {
            guard !knownRun.isEmpty else { return }
            result += try encodeKnownText(String(knownRun), sourceRanges: knownRunRanges)
            knownRun = String.UnicodeScalarView()
            knownRunRanges.removeAll(keepingCapacity: true)
        }

        func flushUnknownRun() throws {
            guard !unknownRunBytes.isEmpty else { return }
            guard let start = unknownRunStartUTF16, let end = unknownRunEndUTF16 else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            let range = try TextUTF16Range(start: start, end: end)
            result += try encodeBytes(
                unknownRunBytes,
                sourceRangesByByte: Array(repeating: range, count: unknownRunBytes.count)
            )
            unknownRunBytes.removeAll(keepingCapacity: true)
            unknownRunStartUTF16 = nil
            unknownRunEndUTF16 = nil
        }

        for sourceScalar in sourceScalars {
            let transformed = sourceScalar.scalar.value == 0x20 ? Unicode.Scalar(0x2581)! : sourceScalar.scalar
            let transformedText = String(transformed)
            if vocabularyScalars.contains(transformed) {
                try flushUnknownRun()
                knownRun.append(transformed)
                knownRunRanges.append(sourceScalar.range)
            } else {
                try flushKnownRun()
                if unknownRunStartUTF16 == nil {
                    unknownRunStartUTF16 = sourceScalar.range.start
                }
                unknownRunEndUTF16 = sourceScalar.range.end
                unknownRunBytes.append(contentsOf: transformedText.utf8)
            }
        }
        try flushKnownRun()
        try flushUnknownRun()
        return result
    }

    private func encodeKnownText(
        _ text: String,
        sourceRanges: [TextUTF16Range]
    ) throws -> [ClauseTaggerToken] {
        let pieces = try tokenizer.tokenize(text)
        var reconstructed = Data()
        var previousPieceIsUnknown = false
        for piece in pieces {
            let id = vocabularyIDs[Data(piece.utf8)]
            let isUnknown = id == nil || id == 0
            // Adjacent unknown lattice pieces cannot satisfy unknown-fusion and byte-exact reconstruction.
            guard !(previousPieceIsUnknown && isUnknown) else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            previousPieceIsUnknown = isUnknown
            reconstructed.append(contentsOf: piece.utf8)
        }
        guard reconstructed == Data(text.utf8) else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }

        let scalars = Array(text.unicodeScalars)
        guard scalars.count == sourceRanges.count else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        var scalarIndexByByteOffset = [0: 0]
        scalarIndexByByteOffset.reserveCapacity(scalars.count + 1)
        var byteCount = 0
        for (index, scalar) in scalars.enumerated() {
            byteCount += String(scalar).utf8.count
            scalarIndexByByteOffset[byteCount] = index + 1
        }
        var sourceRangesByByte: [TextUTF16Range] = []
        sourceRangesByByte.reserveCapacity(byteCount)
        for (scalar, range) in zip(scalars, sourceRanges) {
            sourceRangesByByte.append(contentsOf: repeatElement(range, count: String(scalar).utf8.count))
        }

        var result: [ClauseTaggerToken] = []
        var byteOffset = 0
        for piece in pieces {
            let bytes = Array(piece.utf8)
            guard !bytes.isEmpty, byteOffset + bytes.count <= sourceRangesByByte.count else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            if let id = vocabularyIDs[Data(bytes)] {
                let range = try coveredRange(
                    byteStart: byteOffset,
                    byteEnd: byteOffset + bytes.count,
                    scalarIndexByByteOffset: scalarIndexByByteOffset,
                    sourceRanges: sourceRanges
                )
                result.append(ClauseTaggerToken(id: id, range: range))
            } else {
                let byteRanges = Array(sourceRangesByByte[byteOffset..<(byteOffset + bytes.count)])
                result += try encodeBytes(bytes, sourceRangesByByte: byteRanges)
            }
            byteOffset += bytes.count
        }
        guard byteOffset == sourceRangesByByte.count else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        return result
    }

    private func coveredRange(
        byteStart: Int,
        byteEnd: Int,
        scalarIndexByByteOffset: [Int: Int],
        sourceRanges: [TextUTF16Range]
    ) throws -> TextUTF16Range {
        guard let firstScalar = scalarIndexByByteOffset[byteStart],
              let afterLastScalar = scalarIndexByByteOffset[byteEnd],
              firstScalar < afterLastScalar,
              afterLastScalar <= sourceRanges.count else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        let covered = sourceRanges[firstScalar..<afterLastScalar]
        guard let first = covered.first, let last = covered.last else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        var expectedStart = first.start
        for range in covered {
            guard range.start == expectedStart else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            expectedStart = range.end
        }
        return try TextUTF16Range(start: first.start, end: last.end)
    }

    private func encodeBytes<S: Sequence>(
        _ bytes: S,
        sourceRangesByByte: [TextUTF16Range]
    ) throws -> [ClauseTaggerToken] where S.Element == UInt8 {
        let bytes = Array(bytes)
        guard bytes.count == sourceRangesByByte.count else {
            throw ClauseTaggerTokenizerError.unrepresentableText
        }
        var result: [ClauseTaggerToken] = []
        result.reserveCapacity(bytes.count)
        for (byte, range) in zip(bytes, sourceRangesByByte) {
            guard let id = byteFallbackIDs[byte] else {
                throw ClauseTaggerTokenizerError.unrepresentableText
            }
            result.append(ClauseTaggerToken(id: id, range: range))
        }
        return result
    }

    private func utf16Width(of scalar: Unicode.Scalar) -> Int {
        scalar.value > 0xFFFF ? 2 : 1
    }

}
