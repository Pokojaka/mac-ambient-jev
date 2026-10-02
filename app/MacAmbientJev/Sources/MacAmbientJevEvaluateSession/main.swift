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

/// The `segments.json` fields the evaluation reads. Speaker spans are not evaluated.
private struct SegmentsFileEntry: Decodable {
    let segmentID: String
    let startMilliseconds: Int64
    let endMilliseconds: Int64
    let text: String
    let scene: SceneState
    let scopeSpans: [ScopeSpanEntry]
    let contentPriority: ContentPriority?

    struct ScopeSpanEntry: Decodable {
        let startMilliseconds: Int64
        let endMilliseconds: Int64
        let scope: AcousticScope
        let confidence: Double

        enum CodingKeys: String, CodingKey {
            case startMilliseconds = "start_ms"
            case endMilliseconds = "end_ms"
            case scope
            case confidence
        }
    }

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case text
        case scene
        case scopeSpans = "scope_spans"
        case contentPriority = "content_priority"
    }

    /// `segments.json` is the finalized CLI output, which always runs diarization.
    var segment: MaterializedTranscriptSegment {
        MaterializedTranscriptSegment(
            segmentID: segmentID,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            text: text,
            scene: scene,
            speakers: [],
            scopeSpans: scopeSpans.map {
                MaterializedScopeSpan(
                    startMilliseconds: $0.startMilliseconds,
                    endMilliseconds: $0.endMilliseconds,
                    scope: $0.scope,
                    confidence: $0.confidence
                )
            },
            contentPriority: contentPriority,
            isDiarized: true
        )
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
            [SegmentsFileEntry].self,
            from: Data(contentsOf: segmentsURL)
        ).map(\.segment)

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
