import Foundation
import MacAmbientJevCore

private enum EvaluateSessionError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "manifest.json と segments.json を指定してください"
        }
    }
}

@main
struct EvaluateSessionCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard arguments.count == 2 || arguments.count == 3 else {
            FileHandle.standardError.write(
                Data(
                    """
                    使い方:
                      MacAmbientJevEvaluateSession <manifest.json> <segments.json> [scene-transitions.json]

                    """.utf8
                )
            )
            throw EvaluateSessionError.invalidArguments
        }

        let decoder = JSONDecoder()
        let manifestURL = URL(fileURLWithPath: arguments[0])
        let segmentsURL = URL(fileURLWithPath: arguments[1])

        let manifest = try decoder.decode(
            GoldenCorpusManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let segments = try decoder.decode(
            [MaterializedTranscriptSegment].self,
            from: Data(contentsOf: segmentsURL)
        )

        let observedTransitions: [GoldenSceneTransition]
        if arguments.count == 3 {
            observedTransitions = try decoder.decode(
                [GoldenSceneTransition].self,
                from: Data(
                    contentsOf: URL(fileURLWithPath: arguments[2])
                )
            )
        } else {
            observedTransitions = []
        }

        let report = GoldenCorpusEvaluator.evaluate(
            segments: segments,
            manifest: manifest,
            observedSceneTransitions: observedTransitions
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
