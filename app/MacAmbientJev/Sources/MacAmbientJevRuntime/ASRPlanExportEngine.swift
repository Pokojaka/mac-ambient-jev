import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore

public enum ASRPlanExportError: Error, LocalizedError, Equatable {
    case directoryNotEmpty(String)
    case recognitionNotSupported
    /// Thrown from `begin` once the plan is written, so no ASR run starts.
    case exported

    public var errorDescription: String? {
        switch self {
        case .directoryNotEmpty(let path):
            "ASR プランの出力先が空ではありません: \(path)"
        case .recognitionNotSupported:
            "ASR プランの書き出し用エンジンは文字起こしできません"
        case .exported:
            "ASR プランを書き出したため、文字起こしを行わずに終了しました"
        }
    }
}

/// Writes the plan and one FLAC clip per request, then stops the run before any recognition.
public actor ASRPlanExportEngine: ASREngine {
    nonisolated public let language: String? = ASRLanguage.japanese
    nonisolated public var provenance: RunProvenance {
        RunProvenance(engine: "asr-plan-export", model: nil, version: "1", configuration: [:])
    }

    private let directory: URL
    public private(set) var hasExported = false

    public init(directory: URL) {
        self.directory = directory
    }

    public func prepare() async throws {}

    public func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        throw ASRPlanExportError.recognitionNotSupported
    }

    public func unload() async {}

    public func begin(plan: ASRPlan, audio: ASRAudioLoader) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            guard try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw ASRPlanExportError.directoryNotEmpty(directory.path)
            }
        }
        try manager.createDirectory(
            at: directory.appending(path: "clips", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        for request in plan.requests {
            try RecordingFLAC.writeASRClip(
                try audio.load(frameRange: request.startSample..<request.endSample),
                to: directory.appending(path: request.clipRelativePath),
                directory: directory
            )
        }
        try plan.write(directory: directory)
        hasExported = true
        throw ASRPlanExportError.exported
    }
}
