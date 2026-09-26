import Foundation
import MacAmbientJevCore

private enum EvaluateDiarizationError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "speaker-reference.json と diarization.json を指定してください"
        }
    }
}

@main
struct EvaluateDiarizationCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            FileHandle.standardError.write(
                Data(
                    """
                    使い方:
                      MacAmbientJevEvaluateDiarization <speaker-reference.json> <diarization.json>

                    """.utf8
                )
            )
            throw EvaluateDiarizationError.invalidArguments
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
        FileHandle.standardOutput.write(
            try encoder.encode(report)
        )
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
