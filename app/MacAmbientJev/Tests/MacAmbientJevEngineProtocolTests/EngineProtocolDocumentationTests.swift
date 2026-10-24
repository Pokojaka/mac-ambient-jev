import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolDocumentationTests {
    @Test func documentationCorpusMatchesFixtureAndStrictlyDecodes() throws {
        let root = repositoryRoot()
        let markdown = try readUTF8(root.appendingPathComponent("docs/windows.md"))
        let section = try protocolSection(in: markdown)
        let documentedCorpus = try extractDocumentedCorpus(from: markdown)
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wire-v1.ndjson")
        let fixture = try Data(contentsOf: fixtureURL)

        #expect(documentedCorpus == fixture)
        let coverage = try decodeCorpus(documentedCorpus)
        #expect(coverage.recordCount == 65)
        #expect(coverage.requestCommands.count == 20)
        #expect(coverage.completedCommands.count == 20)
        #expect(coverage.requestCommands.contains(EngineCommandName.transcriptRowDetails.rawValue))
        #expect(coverage.completedCommands.contains(EngineCommandName.transcriptRowDetails.rawValue))
        #expect(coverage.eventNames.count == 7)
        #expect(coverage.rowKinds.count == 3)
        #expect(coverage.requestCommands == Set(EngineCommandName.allCases.map(\.rawValue)))
        #expect(coverage.completedCommands == Set(EngineCommandName.allCases.map(\.rawValue)))
        #expect(coverage.eventNames == Set(EngineEventName.allCases.map(\.rawValue)))
        #expect(coverage.rowKinds == Set(EngineRowsKind.allCases.map(\.rawValue)))

        let expectedConstants = [
            "max_line_bytes = \(EngineLineFramer.maxLineBytes)",
            "max_depth = \(EngineJSONValidator.maxDepth)",
            "max_row_bytes = \(EngineCodec.maxRowBytes)",
        ]
        for constant in expectedConstants {
            #expect(section.contains("`\(constant)`"), "Missing documented constant `\(constant)`")
        }

        let documentedRawValues = [
            ["default", "id"],
            EngineSource.allCases.map(\.rawValue),
            EngineASRSize.allCases.map(\.rawValue),
            EngineExecutionProvider.allCases.map(\.rawValue),
            EngineCommandName.allCases.map(\.rawValue),
            EngineEventName.allCases.map(\.rawValue),
            EngineStage.allCases.map(\.rawValue),
            EngineErrorCode.allCases.map(\.rawValue),
            EngineSeverity.allCases.map(\.rawValue),
            EngineRecoveryAction.allCases.map(\.rawValue),
            EngineScreen.allCases.map(\.rawValue),
            EngineSetupStatus.allCases.map(\.rawValue),
            EngineRecoveryStatus.allCases.map(\.rawValue),
            EngineRecordingPhase.allCases.map(\.rawValue),
            EngineUnavailableCapability.allCases.map(\.rawValue),
            EngineDiagnosticsScope.allCases.map(\.rawValue),
            ["available", "unavailable", "validated", "invalid"],
            EngineSessionStatus.allCases.map(\.rawValue),
            EngineSpeakerLabel.allCases.map(\.rawValue),
            EngineClauseState.allCases.map(\.rawValue),
            EngineRowsKind.allCases.map(\.rawValue),
        ].flatMap { $0 }
        for rawValue in documentedRawValues {
            #expect(section.contains("`\(rawValue)`"), "Missing documented raw value `\(rawValue)`")
        }
    }

    @Test func corpusValidationRejectsInvalidInsertionAndNoncanonicalID() throws {
        let markdown = try readUTF8(repositoryRoot().appendingPathComponent("docs/windows.md"))
        let corpus = try extractDocumentedCorpus(from: markdown)

        let insertedInvalidRecord = corpus + Data("{not-json}\n".utf8)
        #expect(throws: (any Error).self) { _ = try decodeCorpus(insertedInvalidRecord) }

        let text = String(decoding: corpus, as: UTF8.self)
        let validID = #""request_id":"1""#
        guard let range = text.range(of: validID) else {
            throw DocumentationValidationError.mutationTargetMissing
        }
        let invalidID = String(text[..<range.lowerBound])
            + #""request_id":"01""#
            + String(text[range.upperBound...])
        #expect(throws: (any Error).self) { _ = try decodeCorpus(Data(invalidID.utf8)) }
    }

    @Test func namedCorpusFenceMustAppearExactlyOnceAndClose() throws {
        let markdown = try readUTF8(repositoryRoot().appendingPathComponent("docs/windows.md"))
        let marker = "```ndjson engine-protocol-v1\n"

        #expect(throws: (any Error).self) {
            _ = try extractDocumentedCorpus(from: markdown.replacingOccurrences(of: marker, with: ""))
        }
        #expect(throws: (any Error).self) {
            _ = try extractDocumentedCorpus(from: markdown.replacingOccurrences(of: marker, with: marker + marker))
        }
        guard let opening = markdown.range(of: marker),
              let closing = markdown.range(of: "```\n", range: opening.upperBound..<markdown.endIndex) else {
            throw DocumentationValidationError.missingFenceClose
        }
        let missingClose = String(markdown[..<closing.lowerBound]) + String(markdown[closing.upperBound...])
        #expect(throws: (any Error).self) { _ = try extractDocumentedCorpus(from: missingClose) }
    }
}

private struct CorpusCoverage {
    var recordCount = 0
    var requestCommands = Set<String>()
    var completedCommands = Set<String>()
    var eventNames = Set<String>()
    var rowKinds = Set<String>()
}

private enum DocumentationValidationError: Error {
    case invalidUTF8
    case missingOrDuplicateSection
    case missingOrDuplicateFence
    case missingFenceClose
    case unbalancedMarkdownFences
    case invalidRecordMetadata
    case mutationTargetMissing
}

private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url = url.deletingLastPathComponent()
    }
    return url
}

private func readUTF8(_ url: URL) throws -> String {
    let bytes = try Data(contentsOf: url)
    guard let text = String(data: bytes, encoding: .utf8) else {
        throw DocumentationValidationError.invalidUTF8
    }
    return text
}

private func protocolSection(in markdown: String) throws -> String {
    let heading = "## MacAmbientJevEngineProtocol NDJSON v1\n"
    guard markdown.components(separatedBy: heading).count == 2,
          let start = markdown.range(of: heading)?.upperBound,
          let end = markdown.range(of: "## ONNX Runtime\n", range: start..<markdown.endIndex) else {
        throw DocumentationValidationError.missingOrDuplicateSection
    }
    return String(markdown[start..<end.lowerBound])
}

private func extractDocumentedCorpus(from markdown: String) throws -> Data {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    let marker = "```ndjson engine-protocol-v1"
    let namedStarts = lines.indices.filter { lines[$0] == marker }
    guard namedStarts.count == 1 else {
        throw DocumentationValidationError.missingOrDuplicateFence
    }

    let fenceLines = lines.filter { $0.hasPrefix("```") }
    guard fenceLines.count.isMultiple(of: 2) else {
        throw DocumentationValidationError.unbalancedMarkdownFences
    }

    let startIndex = namedStarts[0]
    guard let closeIndex = lines.indices.first(where: {
        $0 > startIndex && lines[$0] == "```"
    }) else {
        throw DocumentationValidationError.missingFenceClose
    }
    guard !lines[(startIndex + 1)..<closeIndex].contains(where: { $0.hasPrefix("```") }) else {
        throw DocumentationValidationError.missingFenceClose
    }

    let opening = marker + "\n"
    guard let openingRange = markdown.range(of: opening),
          let closingRange = markdown.range(of: "```\n", range: openingRange.upperBound..<markdown.endIndex),
          lines[closeIndex] == "```" else {
        throw DocumentationValidationError.missingFenceClose
    }
    return Data(markdown[openingRange.upperBound..<closingRange.lowerBound].utf8)
}

private func decodeCorpus(_ bytes: Data) throws -> CorpusCoverage {
    var framer = EngineLineFramer()
    let records = try framer.append(bytes)
    try framer.finish()

    var coverage = CorpusCoverage()
    coverage.recordCount = records.count
    for record in records {
        guard let metadata = try JSONSerialization.jsonObject(with: record) as? [String: Any] else {
            throw DocumentationValidationError.invalidRecordMetadata
        }
        if metadata.keys.contains("event") {
            let output = try EngineCodec.decodeOutput(record)
            #expect(try EngineCodec.encodeOutput(output) == record + Data([0x0A]))
            coverage.eventNames.insert(output.event.name.rawValue)
            if case let .completed(result) = output.event {
                coverage.completedCommands.insert(result.command.rawValue)
            }
            if case let .rows(payload) = output.event {
                coverage.rowKinds.insert(payload.kind.rawValue)
            }
        } else {
            let request = try EngineCodec.decodeRequest(record)
            #expect(try EngineCodec.encodeRequest(request) == record + Data([0x0A]))
            coverage.requestCommands.insert(request.command.name.rawValue)
        }
    }
    return coverage
}
