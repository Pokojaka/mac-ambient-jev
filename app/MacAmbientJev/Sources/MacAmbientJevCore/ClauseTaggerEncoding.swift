import Foundation

public enum ClauseTaggerEncodingError: LocalizedError, Sendable, Equatable {
    case missingCandidate(offsetUTF16: Int)
    case missingJunction
    case pieceTooLong(tokenCount: Int)
    case contextWindowUnavailable

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
        }
    }
}

public struct ClauseTaggerEncodedInput: Sendable, Equatable {
    public let inputIDs: [Int]
    public let candidateTokenIndices: [Int: Int]
    public let junctionIndex: Int?
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
    }

    private struct Piece {
        let tokens: [Int]
        let candidates: [Int: Int]
        let junctionLocalIndex: Int?
        let nextTokenLocalIndices: [Int]
    }

    private struct PieceSequence {
        let pieces: [Piece]
        let contentTokens: [Int]
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
        tokenizePiece: (String) throws -> [Int]
    ) throws -> ClauseTaggerEncodedInput {
        let sequence = try makeSequence(
            text: text,
            next: next,
            limitsPieces: false,
            tokenizePiece: tokenizePiece
        )
        let contentEnd = min(sequence.contentTokens.count, maximumContentTokens)
        return makeInput(
            sequence: sequence,
            window: Window(startPiece: 0, contentStart: 0, contentEnd: contentEnd),
            candidateOffsets: sequence.candidatePositions.compactMap { offset, position in
                position < contentEnd ? offset : nil
            },
            includesJunction: true
        )
    }

    public static func boundaryInputs(
        _ request: ClauseBoundaryRequest,
        tokenizePiece: (String) throws -> [Int]
    ) throws -> [ClauseTaggerEncodedInput] {
        guard !request.candidates.isEmpty else { return [] }
        let sequence = try makeSequence(text: request.text, next: nil, limitsPieces: true, tokenizePiece: tokenizePiece)
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
            guard let position = sequence.candidatePositions[candidate.offsetUTF16] else {
                throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
            }
            var bestWindow: Window?
            var bestScore = -1
            for window in windows where position >= window.contentStart && position < window.contentEnd {
                let score = min(position - window.contentStart, window.contentEnd - position - 1)
                if score > bestScore {
                    bestScore = score
                    bestWindow = window
                }
            }
            guard let bestWindow else {
                throw ClauseTaggerEncodingError.missingCandidate(offsetUTF16: candidate.offsetUTF16)
            }
            chosenByCandidate[candidate.offsetUTF16] = bestWindow
        }

        let chosenStarts = Set(chosenByCandidate.values.map(\.startPiece)).sorted()
        return try chosenStarts.map { start in
            guard let window = windows.first(where: { $0.startPiece == start }) else {
                throw ClauseTaggerEncodingError.contextWindowUnavailable
            }
            let offsets = request.candidates.compactMap { candidate in
                chosenByCandidate[candidate.offsetUTF16]?.startPiece == start ? candidate.offsetUTF16 : nil
            }
            return makeInput(
                sequence: sequence,
                window: window,
                candidateOffsets: offsets,
                includesJunction: false
            )
        }
    }

    public static func continuationInput(
        _ request: ClauseBoundaryRequest,
        tokenizePiece: (String) throws -> [Int]
    ) throws -> ClauseTaggerEncodedInput {
        guard let next = request.next else { throw ClauseTaggerEncodingError.missingJunction }
        let sequence = try makeSequence(text: request.text, next: next.text, limitsPieces: true, tokenizePiece: tokenizePiece)
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
            includesJunction: true
        )
    }

    private static func makeSequence(
        text: String,
        next: String?,
        limitsPieces: Bool,
        tokenizePiece: (String) throws -> [Int]
    ) throws -> PieceSequence {
        let cleanedText = removingTrailingPunctuation(from: Array(text.unicodeScalars))
        var elements = cleanedText.map {
            ScalarElement(scalar: $0, isJunction: false, isNextText: false)
        }
        if let next {
            elements.append(ScalarElement(scalar: commaScalar, isJunction: true, isNextText: false))
            elements.append(contentsOf: removingTrailingPunctuation(from: Array(next.unicodeScalars)).map {
                ScalarElement(scalar: $0, isJunction: false, isNextText: true)
            })
        }

        var pieces: [Piece] = []
        var runScalars: [Unicode.Scalar] = []
        var runIsNextText = false
        var offsetUTF16 = 0

        for element in elements {
            if isPunctuation(element.scalar) {
                let commaOffset = offsetUTF16 + utf16Width(of: element.scalar)
                let piece = try makePiece(
                    runScalars,
                    limitsPieces: limitsPieces,
                    isNextText: runIsNextText,
                    commaOffsetUTF16: commaOffset,
                    isJunction: element.isJunction,
                    tokenizePiece: tokenizePiece
                )
                pieces.append(piece)
                runScalars.removeAll(keepingCapacity: true)
                runIsNextText = false
            } else {
                if runScalars.isEmpty { runIsNextText = element.isNextText }
                runScalars.append(element.scalar)
            }
            offsetUTF16 += utf16Width(of: element.scalar)
        }

        pieces.append(try makePiece(
            runScalars,
            limitsPieces: limitsPieces,
            isNextText: runIsNextText,
            commaOffsetUTF16: nil,
            isJunction: false,
            tokenizePiece: tokenizePiece
        ))

        var contentTokens: [Int] = []
        var pieceStarts: [Int] = []
        var candidatePositions: [Int: Int] = [:]
        var junctionPosition: Int?
        var nextTokenPositions: [Int] = []
        for piece in pieces {
            let pieceStart = contentTokens.count
            pieceStarts.append(pieceStart)
            contentTokens.append(contentsOf: piece.tokens)
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
            pieceStarts: pieceStarts,
            candidatePositions: candidatePositions,
            junctionPosition: junctionPosition,
            nextTokenPositions: nextTokenPositions
        )
    }

    private static func makePiece(
        _ scalars: [Unicode.Scalar],
        limitsPieces: Bool,
        isNextText: Bool,
        commaOffsetUTF16: Int?,
        isJunction: Bool,
        tokenizePiece: (String) throws -> [Int]
    ) throws -> Piece {
        let text = String(String.UnicodeScalarView(scalars))
        let tokenIDs = try tokenizePiece(text)
        let tokenCount = tokenIDs.count + (commaOffsetUTF16 == nil ? 0 : 1)
        guard !limitsPieces || tokenCount <= maximumContentTokens else {
            throw ClauseTaggerEncodingError.pieceTooLong(tokenCount: tokenCount)
        }

        var tokens = tokenIDs
        var candidates: [Int: Int] = [:]
        var junctionLocalIndex: Int?
        if let commaOffsetUTF16 {
            let commaIndex = tokens.count
            tokens.append(commaTokenID)
            candidates[commaOffsetUTF16] = commaIndex
            if isJunction { junctionLocalIndex = commaIndex }
        }
        return Piece(
            tokens: tokens,
            candidates: candidates,
            junctionLocalIndex: junctionLocalIndex,
            nextTokenLocalIndices: isNextText ? Array(tokenIDs.indices) : []
        )
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
        includesJunction: Bool
    ) -> ClauseTaggerEncodedInput {
        let content = Array(sequence.contentTokens[window.contentStart..<window.contentEnd])
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
            candidateTokenIndices: candidateIndices,
            junctionIndex: junctionIndex
        )
    }

    private static func removingTrailingPunctuation(from scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var end = scalars.count
        while end > 0 && isPunctuation(scalars[end - 1]) {
            end -= 1
        }
        return Array(scalars[..<end])
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        punctuation.unicodeScalars.contains(scalar)
    }

    private static func utf16Width(of scalar: Unicode.Scalar) -> Int {
        scalar.value > 0xFFFF ? 2 : 1
    }
}
