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

                    注釈がない評価項目は JSON null で出力します（合格値ではありません）。
                    scene-transitions.json を省略すると scene 指標は未計測です。転換なしを記録する場合は空配列 [] を渡してください。

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

        let referenceText = try manifest.reference?.resolvedText(
            relativeTo: manifestURL
        )

        let observedTransitions: [GoldenSceneTransition]?
        if arguments.count == 3 {
            observedTransitions = try decoder.decode(
                [GoldenSceneTransition].self,
                from: Data(
                    contentsOf: URL(fileURLWithPath: arguments[2])
                )
            )
        } else {
            observedTransitions = nil
        }

        var unannotatedMetrics: [String] = []
        if manifest.annotations.mustKeepTerms.isEmpty {
            unannotatedMetrics.append("technical_term_retention")
        }
        if manifest.annotations.mustNotBeLowPriority.isEmpty {
            unannotatedMetrics.append("false_low_priority_count")
        }
        if manifest.annotations.mustNotBeBackground.isEmpty {
            unannotatedMetrics.append("false_background_count")
        }
        if manifest.annotations.sceneTransitions.isEmpty {
            unannotatedMetrics.append("scene_transition_error_ms")
        }
        if observedTransitions == nil {
            if !unannotatedMetrics.contains("scene_transition_error_ms") {
                unannotatedMetrics.append("scene_transition_error_ms")
            }
            unannotatedMetrics.append("scene_oscillation_count")
        }
        if !unannotatedMetrics.isEmpty {
            FileHandle.standardError.write(
                Data(
                    "未評価の項目は JSON null です（\(unannotatedMetrics.joined(separator: ", "))）。\n".utf8
                )
            )
        }

        let report = try GoldenCorpusEvaluator.evaluate(
            segments: segments,
            manifest: manifest,
            observedSceneTransitions: observedTransitions,
            referenceText: referenceText
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
