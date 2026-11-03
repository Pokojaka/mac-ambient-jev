import Foundation
import MacAmbientJevDiarizationMeasurement
import MacAmbientJevRuntime

let usage = """
使い方:
  MacAmbientJevDiarizeFileOracle --audio <canonical.caf> --coreml-directory <dir> --output <run.json>
  MacAmbientJevDiarizeFileOracle --help
"""

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print(usage)
        exit(EXIT_SUCCESS)
    }
    let options = try DiarizationMeasurementArguments.parse(
        arguments,
        modelOption: "--coreml-directory",
        requiresThreads: false
    )
    let engine = FluidOfflineDiarizationEngine(models: try MacModelStore(diarizationDirectory: options.modelDirectory))
    let run = try await DiarizationMeasurementRun.measure(engine: engine, audioURL: options.audioURL)
    try run.writeNew(to: options.outputURL)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n\(usage)\n".utf8))
    exit(EXIT_FAILURE)
}
