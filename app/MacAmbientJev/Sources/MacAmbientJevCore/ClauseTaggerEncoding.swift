import Foundation

public struct ClauseTaggerToken: Sendable, Equatable {
    public let id: Int
    public let range: TextUTF16Range

    public init(id: Int, range: TextUTF16Range) {
        self.id = id
        self.range = range
    }
}

public enum ClauseTaggerEncodingError: LocalizedError, Sendable, Equatable {
    case missingCandidate(offsetUTF16: Int)
    case missingJunction
    case pieceTooLong(tokenCount: Int)
    case contextWindowUnavailable
    case invalidTokenRange

    public var errorDescription: String? {
        switch self {
        case .missingCandidate(let offsetUTF16):
            return "UTF-16オフセット\(offsetUTF16)の候補位置を符号化できません"
        case .missingJunction:
            return "継続判定に必要な接続位置または後続トークンを符号化できません"
        case .pieceTooLong(let tokenCount):
            return "句読点で区切られたトークン列が上限を超えています（\(tokenCount)トークン）"
        case .contextWindowUnavailable:
            return "接続位置と前後の必要な文脈を含む入力窓を構成できません"
        case .invalidTokenRange:
            return "トークナイザーが入力片に対応しない UTF-16 範囲を返しました"
        }
    }
}

public struct ClauseTaggerEncodedInput: Sendable, Equatable {
    public let inputIDs: [Int]
    /// Zero-based global content index for `inputIDs[1]`; special tokens are excluded.
    public let contentStartTokenIndex: Int
    /// Aligned with `inputIDs`, including nil special-token entries, only for boundary inputs; empty otherwise.
    public let sourceTokenRanges: [TextUTF16Range?]
    public let candidateTokenIndices: [Int: Int]
    public let junctionIndex: Int?
    /// Boundary-owned content token positions; empty for whole-text and continuation inputs.
    public let spanTokenIndices: [Int]
}

public enum ClauseTaggerEncoding {
    public static let punctuation = "、。？！?!"
    public static let maximumContentTokens = 190
    public static let maximumTokens = 192
    public static let clsTokenID = 6
    public static let sepTokenID = 4
    public static let commaTokenID = 275

    private static let commaScalar: Unicode.Scalar = "、"

    private struct ScalarElement {
        let scalar: Unicode.Scalar
        let isJunction: Bool
        let isNextText: Bool
        let sourceStartUTF16: Int?
    }

    private struct Piece {
        let tokens: [Int]
        let sourceTokenRanges: [TextUTF16Range?]
        let candidates: [Int: Int]
        let junctionLocalIndex: Int?
        let nextTokenLocalIndices: [Int]
    }

    private struct PieceSequence {
        let pieces: [Piece]
        let contentTokens: [Int]
        let sourceTokenRanges: [TextUTF16Range?]
        let pieceStarts: [Int]
        let candidatePositions: [Int: Int]
        let junctionPosition: Int?
        let nextTokenPositions: [Int]
    }

    private struct Window {
        let startPiece: Int
        let contentStart: Int
        let contentEnd: Int
    }

    /// Encodes the whole text as one sequence. Content beyond the first `maximumContentTokens`
    /// tokens is dropped, the same cut the model was trained with. Candidates and the junction
    /// past the cut are not reported.
    public static func encode(
        text: String,
        next: String? = nil,
        tokenizePiece: (String) throws -> [ClauseTaggerToken]
    ) throws -> ClauseTaggerEncodedInput {
        let sequence = try makeSequence(
            text: text,
            next: next,
            limitsPieces: false,
            includesSourceRanges: false,
            tokenizePiece: tokenizePiece
        )
        let contentEnd = min(sequence.contentTokens.count, maximumContentTokens)
        return makeInput(
            sequence: sequence,
            window: Window(startPiece: 0, contentStart: 0, contentEnd: contentEnd),
            candidateOffsets: sequence.candidatePositions.compactMap { offset, position in
                position < contentEnd ? offset : nil
            },
            includesJunction: true,
            includesSourceRanges: false,
            spanTokenPositions: []
        )
    }

    public static func boundaryInputs(
        _ request: ClauseBoundaryRequest,
        tokenizePiece: (String) throws -> [ClauseTaggerToken]
    ) throws -> [ClauseTaggerEncodedInput] {
        let sequence = try makeSequence(
            text: request.text,
            next: nil,
            limitsPieces: true,
            includesSourceRanges: true,
            tokenizePiece: tokenizePiece
        )
        for candidate in request.candidates where sequence.candidatePositions[candidate.offsetUTF16] == nil {
            throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
        }

        let windows: [Window]
        if sequence.contentTokens.count <= maximumContentTokens {
            windows = [Window(
                startPiece: 0,
                contentStart: 0,
                contentEnd: sequence.contentTokens.count
            )]
        } else {
            windows = maximalWindows(in: sequence)
        }

        var chosenByCandidate: [Int: Window] = [:]
        for candidate in request.candidates {
            guard let position = sequence.candidatePositions[candidate.offsetUTF16],
                  let bestWindow = bestWindow(containing: position, in: windows) else {
                throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
            }
            chosenByCandidate[candidate.offsetUTF16] = bestWindow
        }

        var chosenBySourceToken: [Int: Window] = [:]
        for position in sequence.sourceTokenRanges.indices where sequence.sourceTokenRanges[position] != nil {
            guard let bestWindow = bestWindow(containing: position, in: windows) else {
                throw ClauseTaggerEncodingError.contextWindowUnavailable
            }
            chosenBySourceToken[position] = bestWindow
        }

        var chosenStarts = Set(chosenByCandidate.values.map(\.startPiece))
        chosenStarts.formUnion(chosenBySourceToken.values.map(\.startPiece))
        if chosenStarts.isEmpty {
            guard let firstWindow = windows.first else {
                throw ClauseTaggerEncodingError.contextWindowUnavailable
            }
            chosenStarts.insert(firstWindow.startPiece)
        }

        return try chosenStarts.sorted().map { start in
            guard let window = windows.first(where: { $0.startPiece == start }) else {
                throw ClauseTaggerEncodingError.contextWindowUnavailable
            }
            let offsets = request.candidates.compactMap { candidate in
                chosenByCandidate[candidate.offsetUTF16]?.startPiece == start ? candidate.offsetUTF16 : nil
            }
            let spanPositions = chosenBySourceToken.compactMap { position, owner in
                owner.startPiece == start ? position : nil
            }.sorted()
            return makeInput(
                sequence: sequence,
                window: window,
                candidateOffsets: offsets,
                includesJunction: false,
                includesSourceRanges: true,
                spanTokenPositions: spanPositions
            )
        }
    }

    public static func continuationInput(
        _ request: ClauseBoundaryRequest,
        tokenizePiece: (String) throws -> [ClauseTaggerToken]
    ) throws -> ClauseTaggerEncodedInput {
        guard let next = request.next else { throw ClauseTaggerEncodingError.missingJunction }
        let sequence = try makeSequence(
            text: request.text,
            next: next.text,
            limitsPieces: true,
            includesSourceRanges: false,
            tokenizePiece: tokenizePiece
        )
        guard let junctionPosition = sequence.junctionPosition,
              !sequence.nextTokenPositions.isEmpty else {
            throw ClauseTaggerEncodingError.missingJunction
        }

        let validWindows = maximalWindows(in: sequence).filter { window in
            window.contentStart <= junctionPosition && junctionPosition < window.contentEnd
                && sequence.nextTokenPositions.contains {
                    $0 > junctionPosition && $0 >= window.contentStart && $0 < window.contentEnd
                }
        }
        guard !validWindows.isEmpty else { throw ClauseTaggerEncodingError.contextWindowUnavailable }

        var chosenWindow: Window?
        var bestScore = -1
        for window in validWindows {
            let score = min(junctionPosition - window.contentStart, window.contentEnd - junctionPosition - 1)
            if score > bestScore {
                bestScore = score
                chosenWindow = window
            }
        }
        guard let chosenWindow else { throw ClauseTaggerEncodingError.contextWindowUnavailable }

        return makeInput(
            sequence: sequence,
            window: chosenWindow,
            candidateOffsets: [],
            includesJunction: true,
            includesSourceRanges: false,
            spanTokenPositions: []
        )
    }

    private static func makeSequence(
        text: String,
        next: String?,
        limitsPieces: Bool,
        includesSourceRanges: Bool,
        tokenizePiece: (String) throws -> [ClauseTaggerToken]
    ) throws -> PieceSequence {
        var elements = sourceElements(in: text, isNextText: false)
        if let next {
            elements.append(ScalarElement(
                scalar: commaScalar,
                isJunction: true,
                isNextText: false,
                sourceStartUTF16: nil
            ))
            elements.append(contentsOf: sourceElements(in: next, isNextText: true))
        }

        var pieces: [Piece] = []
        var runScalars: [Unicode.Scalar] = []
        var runSourceStartUTF16: Int?
        var runIsNextText = false
        var sequenceOffsetUTF16 = 0

        for element in elements {
            if isPunctuation(element.scalar) {
                let commaOffset = sequenceOffsetUTF16 + utf16Width(of: element.scalar)
                let commaRange: TextUTF16Range?
                if includesSourceRanges, let sourceStart = element.sourceStartUTF16 {
                    commaRange = try TextUTF16Range(
                        start: sourceStart,
                        end: sourceStart + utf16Width(of: element.scalar)
                    )
                } else {
                    commaRange = nil
                }
                let piece = try makePiece(
                    runScalars,
                    runSourceStartUTF16: runSourceStartUTF16,
                    limitsPieces: limitsPieces,
                    includesSourceRanges: includesSourceRanges,
                    isNextText: runIsNextText,
                    commaOffsetUTF16: commaOffset,
                    commaRange: commaRange,
                    isJunction: element.isJunction,
                    tokenizePiece: tokenizePiece
                )
                pieces.append(piece)
                runScalars.removeAll(keepingCapacity: true)
                runSourceStartUTF16 = nil
                runIsNextText = false
            } else {
                if runScalars.isEmpty {
                    runIsNextText = element.isNextText
                    runSourceStartUTF16 = element.sourceStartUTF16
                }
                runScalars.append(element.scalar)
            }
            sequenceOffsetUTF16 += utf16Width(of: element.scalar)
        }

        pieces.append(try makePiece(
            runScalars,
            runSourceStartUTF16: runSourceStartUTF16,
            limitsPieces: limitsPieces,
            includesSourceRanges: includesSourceRanges,
            isNextText: runIsNextText,
            commaOffsetUTF16: nil,
            commaRange: nil,
            isJunction: false,
            tokenizePiece: tokenizePiece
        ))

        var contentTokens: [Int] = []
        var sourceTokenRanges: [TextUTF16Range?] = []
        var pieceStarts: [Int] = []
        var candidatePositions: [Int: Int] = [:]
        var junctionPosition: Int?
        var nextTokenPositions: [Int] = []
        for piece in pieces {
            let pieceStart = contentTokens.count
            pieceStarts.append(pieceStart)
            contentTokens.append(contentsOf: piece.tokens)
            sourceTokenRanges.append(contentsOf: piece.sourceTokenRanges)
            for (offset, localIndex) in piece.candidates {
                candidatePositions[offset] = pieceStart + localIndex
            }
            if let localIndex = piece.junctionLocalIndex {
                junctionPosition = pieceStart + localIndex
            }
            nextTokenPositions.append(contentsOf: piece.nextTokenLocalIndices.map { pieceStart + $0 })
        }

        return PieceSequence(
            pieces: pieces,
            contentTokens: contentTokens,
            sourceTokenRanges: sourceTokenRanges,
            pieceStarts: pieceStarts,
            candidatePositions: candidatePositions,
            junctionPosition: junctionPosition,
            nextTokenPositions: nextTokenPositions
        )
    }

    private static func sourceElements(in text: String, isNextText: Bool) -> [ScalarElement] {
        let scalars = Array(text.unicodeScalars)
        var elements: [ScalarElement] = []
        var sourceOffsetUTF16 = 0
        for scalar in scalars {
            elements.append(ScalarElement(
                scalar: scalar,
                isJunction: false,
                isNextText: isNextText,
                sourceStartUTF16: isNextText ? nil : sourceOffsetUTF16
            ))
            sourceOffsetUTF16 += utf16Width(of: scalar)
        }
        while let last = elements.last, isPunctuation(last.scalar) {
            elements.removeLast()
        }
        return elements
    }

    private static func makePiece(
        _ scalars: [Unicode.Scalar],
        runSourceStartUTF16: Int?,
        limitsPieces: Bool,
        includesSourceRanges: Bool,
        isNextText: Bool,
        commaOffsetUTF16: Int?,
        commaRange: TextUTF16Range?,
        isJunction: Bool,
        tokenizePiece: (String) throws -> [ClauseTaggerToken]
    ) throws -> Piece {
        let text = String(String.UnicodeScalarView(scalars))
        let tokenized = try tokenizePiece(text)
        let tokenCount = tokenized.count + (commaOffsetUTF16 == nil ? 0 : 1)
        guard !limitsPieces || tokenCount <= maximumContentTokens else {
            throw ClauseTaggerEncodingError.pieceTooLong(tokenCount: tokenCount)
        }

        var tokens = tokenized.map(\.id)
        let textUTF16Count = text.utf16.count
        var sourceTokenRanges: [TextUTF16Range?] = []
        if includesSourceRanges {
            sourceTokenRanges.reserveCapacity(tokenCount)
        }
        for token in tokenized {
            guard token.range.end <= textUTF16Count else {
                throw ClauseTaggerEncodingError.invalidTokenRange
            }
            guard includesSourceRanges else { continue }
            let sourceRange: TextUTF16Range?
            if isNextText {
                sourceRange = nil
            } else if let runSourceStartUTF16 {
                sourceRange = try TextUTF16Range(
                    start: runSourceStartUTF16 + token.range.start,
                    end: runSourceStartUTF16 + token.range.end
                )
            } else {
                sourceRange = nil
            }
            sourceTokenRanges.append(sourceRange)
        }

        var candidates: [Int: Int] = [:]
        var junctionLocalIndex: Int?
        if let commaOffsetUTF16 {
            let commaIndex = tokens.count
            tokens.append(commaTokenID)
            if includesSourceRanges {
                sourceTokenRanges.append(commaRange)
            }
            candidates[commaOffsetUTF16] = commaIndex
            if isJunction { junctionLocalIndex = commaIndex }
        }
        return Piece(
            tokens: tokens,
            sourceTokenRanges: sourceTokenRanges,
            candidates: candidates,
            junctionLocalIndex: junctionLocalIndex,
            nextTokenLocalIndices: isNextText ? Array(tokenized.indices) : []
        )
    }

    private static func bestWindow(containing position: Int, in windows: [Window]) -> Window? {
        var bestWindow: Window?
        var bestScore = -1
        for window in windows where position >= window.contentStart && position < window.contentEnd {
            let score = min(position - window.contentStart, window.contentEnd - position - 1)
            if score > bestScore {
                bestScore = score
                bestWindow = window
            }
        }
        return bestWindow
    }

    private static func maximalWindows(in sequence: PieceSequence) -> [Window] {
        var windows: [Window] = []
        for start in sequence.pieces.indices {
            var end = start
            var tokenCount = 0
            while end < sequence.pieces.count {
                let nextCount = sequence.pieces[end].tokens.count
                guard tokenCount + nextCount <= maximumContentTokens else { break }
                tokenCount += nextCount
                end += 1
            }
            let contentStart = sequence.pieceStarts[start]
            let contentEnd = end == sequence.pieces.count
                ? sequence.contentTokens.count
                : sequence.pieceStarts[end]
            windows.append(Window(
                startPiece: start,
                contentStart: contentStart,
                contentEnd: contentEnd
            ))
        }
        return windows
    }

    private static func makeInput(
        sequence: PieceSequence,
        window: Window,
        candidateOffsets: [Int],
        includesJunction: Bool,
        includesSourceRanges: Bool,
        spanTokenPositions: [Int]
    ) -> ClauseTaggerEncodedInput {
        let content = Array(sequence.contentTokens[window.contentStart..<window.contentEnd])
        let sourceRanges: [TextUTF16Range?]
        let localSpanIndices: [Int]
        if includesSourceRanges {
            sourceRanges = Array(sequence.sourceTokenRanges[window.contentStart..<window.contentEnd])
            localSpanIndices = spanTokenPositions.map { position -> Int in
                precondition(position >= window.contentStart && position < window.contentEnd)
                precondition(sequence.sourceTokenRanges[position] != nil)
                return position - window.contentStart + 1
            }
        } else {
            sourceRanges = []
            localSpanIndices = []
        }
        let candidateIndices = candidateOffsets.reduce(into: [Int: Int]()) { result, offset in
            guard let position = sequence.candidatePositions[offset] else {
                preconditionFailure("Candidate offset must have an encoded position")
            }
            precondition(position >= window.contentStart && position < window.contentEnd)
            result[offset] = position - window.contentStart + 1
        }
        let junctionIndex: Int?
        if includesJunction,
           let position = sequence.junctionPosition,
           position >= window.contentStart,
           position < window.contentEnd {
            junctionIndex = position - window.contentStart + 1
        } else {
            junctionIndex = nil
        }
        return ClauseTaggerEncodedInput(
            inputIDs: [clsTokenID] + content + [sepTokenID],
            contentStartTokenIndex: window.contentStart,
            sourceTokenRanges: includesSourceRanges ? [nil] + sourceRanges + [nil] : [],
            candidateTokenIndices: candidateIndices,
            junctionIndex: junctionIndex,
            spanTokenIndices: localSpanIndices
        )
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        punctuation.unicodeScalars.contains(scalar)
    }

    private static func utf16Width(of scalar: Unicode.Scalar) -> Int {
        scalar.value > 0xFFFF ? 2 : 1
    }
}
