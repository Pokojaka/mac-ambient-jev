import Foundation
import MacAmbientJevCore

private struct InvalidArguments: Error {}

@main
struct EvaluateDiarizationCommand {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
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
                      MacAmbientJevEvaluateDiarization <speaker-reference.json> <diarization.json> [--output report.json]

                    """.utf8
                )
            )
            throw InvalidArguments()
        }

        let decoder = JSONDecoder()
        let reference = try decoder.decode(
            [DiarizationRawSpan].self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: arguments[0]
                )
            )
        )
        let artifact = try decoder.decode(
            DiarizationEvaluationArtifact.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: arguments[1]
                )
            )
        )
        let report = try DiarizationArtifactEvaluator.evaluate(
            reference: reference.map(\.sourceSpan),
            artifact: artifact
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
