import Foundation
import MacAmbientJevCore

public enum SessionAudioReadersError: LocalizedError, Equatable {
    case importNeedsTimelineBuild

    public var errorDescription: String? {
        switch self {
        case .importNeedsTimelineBuild:
            "取り込んだ音声は確定処理で作る処理用タイムライン経由でのみ読み込めます"
        }
    }
}

public enum SessionAudioReaders {
    /// Opens a validated reader for a stored recording. `.recordedFLAC` decodes the whole file
    /// (`FLACTimelineReader.validateAudio()`) before returning. `.importedOriginal` throws
    /// `SessionAudioReadersError.importNeedsTimelineBuild`: imports are read only through
    /// the timeline that NativeSessionProcessor builds for one finalization.
    public static func open(_ source: SessionAudioSource, layout: SessionLayout) throws -> any TimelineAudioReading {
        switch source {
        case .recordedPCM(let checkpoint):
            let reader = try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: checkpoint, sessionURL: layout.sessionURL)
            try reader.validateAudio()
            return reader
        case .recordedFLAC(let info):
            let reader = try FLACTimelineReader(url: layout.recordingFLACURL, info: info, sessionURL: layout.sessionURL)
            try reader.validateAudio()
            return reader
        case .importedOriginal:
            throw SessionAudioReadersError.importNeedsTimelineBuild
        }
    }
}
