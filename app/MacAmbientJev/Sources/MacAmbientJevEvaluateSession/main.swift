import Foundation
import MacAmbientJevCore

@main
struct EvaluateSessionCommand {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data(
                "使い方: MacAmbientJevEvaluateSession <manifest.json> <segments.json>\n".utf8
            ))
            exit(2)
        }

        let decoder = JSONDecoder()
        let manifestURL = URL(fileURLWithPath: arguments[0])
        let manifest = try decoder.decode(
            ASRSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let segments = try decoder.decode(
            [ASRSessionSegment].self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        )

        let report = ASRSessionEvaluator.evaluate(
            id: manifest.id,
            reference: try manifest.referenceText(manifestURL: manifestURL),
            segments: segments
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
