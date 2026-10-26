import Foundation
import Testing

struct EngineProtocolEncodingSourceTests {
    @Test func protocolSourceEncodingsUseTypedValues() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = packageRoot
            .appendingPathComponent("Sources/MacAmbientJevEngineProtocol", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(atPath: sourceDirectory.path) else {
            throw EncodingSourceLintError.cannotEnumerate(sourceDirectory.path)
        }

        let swiftFiles = enumerator.compactMap { $0 as? String }
            .filter { URL(fileURLWithPath: $0).pathExtension == "swift" }
            .sorted()
        guard !swiftFiles.isEmpty else {
            throw EncodingSourceLintError.noSwiftSources(sourceDirectory.path)
        }
        var diagnostics: [String] = []
        for file in swiftFiles {
            let url = sourceDirectory.appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            diagnostics += untypedWireEncodingDiagnostics(in: source, file: file)
        }

        if !diagnostics.isEmpty {
            Issue.record("Untyped wire encoding diagnostics:\n\(diagnostics.joined(separator: "\n"))")
        }
        #expect(diagnostics.isEmpty)
    }

    @Test func lexicalLintRejectsStringAndRawValueArguments() {
        let rejectedSources = [
            #"container.encode("ready", forKey: .kind)"#,
            ##"container.encode(#"b"#, forKey: .kind)"##,
            #"""
            container.encode("""
            ready
            """, forKey: .kind)
            """#,
            #"container.encode(mode /* gap */ .rawValue, forKey: .kind)"#,
            #"""
            container.encode
                /* gap before argument list */
                (
                /* gap */
                rawValue
                , forKey: .kind
            )
            """#,
            #"container.encode(String(mode.rawValue), forKey: .kind)"#,
            #"container.encode("ready")"#,
            ##"container.encode(#"wire"#)"##,
            #"""
            container.encodeIfPresent(
                mode
                    .rawValue,
                forKey: .kind
            )
            """#,
        ]

        for source in rejectedSources {
            #expect(!untypedWireEncodingDiagnostics(in: source, file: "Example.swift").isEmpty)
        }
    }

    @Test func lexicalLintAcceptsTypedValuesAndIgnoresCommentsAndStrings() {
        let acceptedSources = [
            "container.encode(kind, forKey: .kind)",
            "container.encode(value, forKey: .count)",
            "container.encode(String(value))",
            "// container.encode(\"bad\", forKey: .kind)\ncontainer.encode(value)",
            "/* outer encode(\"bad\") /* nested encode(rawValue) */ still comment */ container.encode(value)",
            #"let pseudoCode = "container.encode(\"bad\", forKey: .kind)""#,
        ]

        for source in acceptedSources {
            #expect(untypedWireEncodingDiagnostics(in: source, file: "Example.swift").isEmpty)
        }
    }

    @Test func diagnosticsUseEncodingCallLine() {
        let source = """
        let value = mode
        container.encode(
            value.rawValue,
            forKey: .kind
        )
        """
        #expect(
            untypedWireEncodingDiagnostics(in: source, file: "Example.swift") == [
                "Untyped wire encoding: Example.swift:2: encode must pass a typed value, not a string literal or rawValue",
            ]
        )
    }

    @Test func diagnosticsUseEncodingCallLineWithCRLF() {
        let source = "let value = mode\r\ncontainer.encode(\r\n    value.rawValue,\r\n    forKey: .kind\r\n)"
        #expect(
            untypedWireEncodingDiagnostics(in: source, file: "Example.swift") == [
                "Untyped wire encoding: Example.swift:2: encode must pass a typed value, not a string literal or rawValue",
            ]
        )
    }
}

private enum EncodingSourceLintError: Error {
    case cannotEnumerate(String)
    case noSwiftSources(String)
}

private func untypedWireEncodingDiagnostics(in source: String, file: String) -> [String] {
    var tokenizer = SwiftSourceTokenizer(source)
    let tokens = tokenizer.tokenize()
    var diagnostics: [String] = []

    for index in tokens.indices {
        guard case let .identifier(name) = tokens[index].kind,
              name == "encode" || name == "encodeIfPresent",
              tokens.indices.contains(index + 1),
              tokens[index + 1].kind.isPunctuation("(") else {
            continue
        }

        if firstArgumentContainsUntypedValue(in: tokens, after: index + 1) {
            diagnostics.append(
                "Untyped wire encoding: \(file):\(tokens[index].line): encode must pass a typed value, not a string literal or rawValue"
            )
        }
    }
    return diagnostics
}

private func firstArgumentContainsUntypedValue(in tokens: [SwiftSourceToken], after openingIndex: Int) -> Bool {
    var parentheses = 0
    var brackets = 0
    var braces = 0
    var index = openingIndex + 1

    while tokens.indices.contains(index) {
        let token = tokens[index]
        switch token.kind {
        case .stringLiteral:
            return true
        case .identifier("rawValue"):
            return true
        case let .punctuation(character):
            switch character {
            case "(": parentheses += 1
            case ")":
                if parentheses == 0 && brackets == 0 && braces == 0 {
                    return false
                }
                if parentheses > 0 { parentheses -= 1 }
            case "[": brackets += 1
            case "]":
                if brackets > 0 { brackets -= 1 }
            case "{": braces += 1
            case "}":
                if braces > 0 { braces -= 1 }
            case "," where parentheses == 0 && brackets == 0 && braces == 0:
                return false
            default:
                break
            }
        case .identifier:
            break
        }
        index += 1
    }
    return false
}

private struct SwiftSourceToken {
    enum Kind {
        case identifier(String)
        case punctuation(Character)
        case stringLiteral

        func isPunctuation(_ expected: Character) -> Bool {
            guard case let .punctuation(character) = self else { return false }
            return character == expected
        }
    }

    let kind: Kind
    let line: Int
}

private struct SwiftSourceTokenizer {
    private let characters: [Character]
    private var index = 0
    private var line = 1

    init(_ source: String) {
        characters = Array(source)
    }

    mutating func tokenize() -> [SwiftSourceToken] {
        var tokens: [SwiftSourceToken] = []
        while index < characters.count {
            if current.isWhitespace {
                advance()
                continue
            }
            if skipCommentIfPresent() {
                continue
            }
            if let (quoteIndex, poundCount) = stringStart() {
                let startLine = line
                skipString(quoteIndex: quoteIndex, poundCount: poundCount)
                tokens.append(SwiftSourceToken(kind: .stringLiteral, line: startLine))
                continue
            }
            if isIdentifierStart(current) {
                let start = index
                repeat { advance() } while index < characters.count && isIdentifierContinuation(current)
                let identifier = String(characters[start..<index])
                tokens.append(SwiftSourceToken(kind: .identifier(identifier), line: line))
                continue
            }

            tokens.append(SwiftSourceToken(kind: .punctuation(current), line: line))
            advance()
        }
        return tokens
    }

    private var current: Character {
        characters[index]
    }

    private func character(at offset: Int) -> Character? {
        let target = index + offset
        return characters.indices.contains(target) ? characters[target] : nil
    }

    private mutating func advance() {
        let currentCharacter = characters[index]
        index += 1
        if currentCharacter == "\r\n" || currentCharacter == "\n" ||
            (currentCharacter == "\r" && character(at: 0) != "\n") {
            line += 1
        }
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private mutating func skipCommentIfPresent() -> Bool {
        guard current == "/", let next = character(at: 1) else { return false }
        if next == "/" {
            advance()
            advance()
            while index < characters.count && current != "\n" && current != "\r" && current != "\r\n" {
                advance()
            }
            return true
        }
        guard next == "*" else { return false }

        advance()
        advance()
        var depth = 1
        while index < characters.count && depth > 0 {
            if current == "/", character(at: 1) == "*" {
                advance()
                advance()
                depth += 1
            } else if current == "*", character(at: 1) == "/" {
                advance()
                advance()
                depth -= 1
            } else {
                advance()
            }
        }
        return true
    }

    private func stringStart() -> (quoteIndex: Int, poundCount: Int)? {
        if current == "\"" {
            return (index, 0)
        }
        guard current == "#" else { return nil }
        var quoteIndex = index
        while characters.indices.contains(quoteIndex), characters[quoteIndex] == "#" {
            quoteIndex += 1
        }
        guard characters.indices.contains(quoteIndex), characters[quoteIndex] == "\"" else {
            return nil
        }
        return (quoteIndex, quoteIndex - index)
    }

    private mutating func skipString(quoteIndex: Int, poundCount: Int) {
        let multiline = hasQuotes(at: quoteIndex, count: 3)
        index = quoteIndex + (multiline ? 3 : 1)
        let quoteCount = multiline ? 3 : 1

        while index < characters.count {
            if isStringTerminator(quoteCount: quoteCount, poundCount: poundCount) {
                for _ in 0..<(quoteCount + poundCount) { advance() }
                return
            }
            if current == "\\" {
                if let interpolationStart = interpolationOpening(poundCount: poundCount) {
                    while index <= interpolationStart { advance() }
                    skipInterpolation()
                } else if poundCount == 0 {
                    advance()
                    if index < characters.count { advance() }
                } else if let escapedTerminator = escapedStringTerminator(
                    quoteCount: quoteCount,
                    poundCount: poundCount
                ) {
                    while index < escapedTerminator { advance() }
                } else {
                    advance()
                }
            } else {
                advance()
            }
        }
    }

    private mutating func skipInterpolation() {
        var parentheses = 1
        while index < characters.count && parentheses > 0 {
            if skipCommentIfPresent() {
                continue
            }
            if let (quoteIndex, poundCount) = stringStart() {
                skipString(quoteIndex: quoteIndex, poundCount: poundCount)
                continue
            }
            if current == "(" {
                parentheses += 1
            } else if current == ")" {
                parentheses -= 1
            }
            advance()
        }
    }

    private func interpolationOpening(poundCount: Int) -> Int? {
        guard current == "\\" else { return nil }
        var openingParen = index + 1
        for _ in 0..<poundCount {
            guard characters.indices.contains(openingParen), characters[openingParen] == "#" else {
                return nil
            }
            openingParen += 1
        }
        guard characters.indices.contains(openingParen), characters[openingParen] == "(" else {
            return nil
        }
        return openingParen
    }

    private func isStringTerminator(quoteCount: Int, poundCount: Int) -> Bool {
        guard hasQuotes(at: index, count: quoteCount) else { return false }
        let poundStart = index + quoteCount
        for offset in 0..<poundCount {
            guard characters.indices.contains(poundStart + offset), characters[poundStart + offset] == "#" else {
                return false
            }
        }
        return true
    }

    private func escapedStringTerminator(quoteCount: Int, poundCount: Int) -> Int? {
        var quoteStart = index + 1
        for _ in 0..<poundCount {
            guard characters.indices.contains(quoteStart), characters[quoteStart] == "#" else {
                return nil
            }
            quoteStart += 1
        }
        guard isStringTerminator(at: quoteStart, quoteCount: quoteCount, poundCount: poundCount) else {
            return nil
        }
        return quoteStart + quoteCount + poundCount
    }

    private func isStringTerminator(at start: Int, quoteCount: Int, poundCount: Int) -> Bool {
        guard hasQuotes(at: start, count: quoteCount) else { return false }
        let poundStart = start + quoteCount
        for offset in 0..<poundCount {
            guard characters.indices.contains(poundStart + offset), characters[poundStart + offset] == "#" else {
                return false
            }
        }
        return true
    }

    private func hasQuotes(at start: Int, count: Int) -> Bool {
        guard start >= 0 else { return false }
        for offset in 0..<count {
            guard characters.indices.contains(start + offset), characters[start + offset] == "\"" else {
                return false
            }
        }
        return true
    }
}
