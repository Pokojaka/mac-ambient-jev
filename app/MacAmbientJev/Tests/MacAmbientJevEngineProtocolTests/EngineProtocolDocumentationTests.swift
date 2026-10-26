import Foundation
import Testing
@testable import MacAmbientJevEngineProtocol

struct EngineProtocolDocumentationTests {
    @Test func documentedCorpusAndLimitsMatchTheCodec() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root = root.deletingLastPathComponent()
        }
        let markdown = try String(contentsOf: root.appendingPathComponent("docs/windows.md"), encoding: .utf8)
        let opening = "```ndjson engine-protocol-v1\n"
        #expect(markdown.components(separatedBy: opening).count == 2)
        let start = try #require(markdown.range(of: opening))
        let end = try #require(markdown.range(of: "```\n", range: start.upperBound..<markdown.endIndex))
        let fixture = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wire-v1.ndjson"))
        #expect(Data(markdown[start.upperBound..<end.lowerBound].utf8) == fixture)

        for constant in [
            "max_line_bytes = \(EngineLineFramer.maxLineBytes)",
            "max_depth = \(EngineJSONValidator.maxDepth)",
            "max_row_bytes = \(EngineCodec.maxRowBytes)",
        ] {
            #expect(markdown.contains("`\(constant)`"), "Missing documented constant `\(constant)`")
        }
    }
}
