import Foundation
import MacAmbientJevCore

private enum EvaluateASRError: LocalizedError {
    case invalidArguments
    case emptySegments

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "reference.txt と asr-artifact.json を指定してください"
        case .emptySegments:
            return "ASR artifact に segments がありません"
        }
    }
}

private struct ASRArtifact: Decodable {
    struct Segment: Decodable {
        let text: String
    }

    let segments: [Segment]
}

@main
struct EvaluateASRCommand {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(
                Data("\(error.localizedDescription)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let outputURL: URL?
        switch arguments.count {
        case 2:
            outputURL = nil
        case 4 where arguments[2] == "--output":
            outputURL = URL(fileURLWithPath: arguments[3])
        default:
            FileHandle.standardError.write(
                Data(
                    """
                    使い方:
                      MacAmbientJevEvaluateASR <reference.txt> <asr-artifact.json> [--output report.json]

                    """.utf8
                )
            )
            throw EvaluateASRError.invalidArguments
        }

        let reference = try String(
            contentsOf: URL(fileURLWithPath: arguments[0]),
            encoding: .utf8
        )
        let artifact = try JSONDecoder().decode(
            ASRArtifact.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: arguments[1]
                )
            )
        )
        guard !artifact.segments.isEmpty else {
            throw EvaluateASRError.emptySegments
        }

        let hypothesis = artifact.segments
            .map(\.text)
            .joined(separator: "\n")
        let report = ASREvaluation.evaluate(
            reference: reference,
            hypothesis: hypothesis
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)

        if let outputURL {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            FileHandle.standardOutput.write(
                Data("\(outputURL.path)\n".utf8)
            )
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}
