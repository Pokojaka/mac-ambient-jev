import Foundation
import MacAmbientJevDiarizationMeasurement
import MacAmbientJevPortableRuntime

let usage = """
使い方:
  MacAmbientJevDiarizeFile --audio <canonical.caf> --model-directory <dir> --threads <n> --output <run.json>
  MacAmbientJevDiarizeFile --help
"""

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print(usage)
        exit(EXIT_SUCCESS)
    }
    let options = try DiarizationMeasurementArguments.parse(
        arguments,
        modelOption: "--model-directory",
        requiresThreads: true
    )
    let engine = try ONNXCommunity1DiarizationEngine(
        modelDirectory: options.modelDirectory,
        intraOpThreads: options.threads!
    )
    let run = try await DiarizationMeasurementRun.measure(engine: engine, audioURL: options.audioURL)
    try run.writeNew(to: options.outputURL)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n\(usage)\n".utf8))
    exit(EXIT_FAILURE)
}
