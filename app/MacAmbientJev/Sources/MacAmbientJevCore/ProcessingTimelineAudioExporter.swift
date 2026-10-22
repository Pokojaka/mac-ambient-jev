import Foundation

public enum ProcessingTimelineAudioExporterError: LocalizedError, Equatable {
    case tooManyFrames
    case sourceLengthMismatch(startFrame: Int64, expected: Int, actual: Int)
    case nonFiniteSample(frame: Int64)
    case temporaryFileNotRemoved(path: String, writeFailure: String, cleanupFailure: String)

    public var errorDescription: String? {
        switch self {
        case .tooManyFrames:
            "処理用音声のフレーム数がCAF形式の上限を超えています"
        case .sourceLengthMismatch(let startFrame, let expected, let actual):
            "処理用音声の読み取り長が一致しません（開始フレーム: \(startFrame)、期待: \(expected)、実際: \(actual)）"
        case .nonFiniteSample(let frame):
            "処理用音声に有限でないサンプルがあります（フレーム: \(frame)）"
        case .temporaryFileNotRemoved(let path, let writeFailure, let cleanupFailure):
            "処理用音声を書き出せませんでした: \(writeFailure)。一時ファイル \(path) も削除できませんでした: \(cleanupFailure)"
        }
    }
}

/// Streams a canonical timeline into a 16-kHz mono float32 CAF in bounded buffers.
public struct ProcessingTimelineAudioExporter: Sendable {
    public let framesPerBuffer: Int64

    public init(framesPerBuffer: Int64) {
        precondition(framesPerBuffer > 0 && framesPerBuffer <= Int64(Int.max / 4))
        self.framesPerBuffer = framesPerBuffer
    }

    /// Writes a hidden sibling first, then publishes it over `destinationURL`.
    public func export(
        reader: any TimelineAudioReading,
        to destinationURL: URL,
        sessionURL: URL
    ) throws {
        let committedFrames = reader.info.committedFrames
        guard committedFrames <= (Int64.max - 4) / 4 else {
            throw ProcessingTimelineAudioExporterError.tooManyFrames
        }

        let parent = destinationURL.deletingLastPathComponent()
        try SessionFileAccess.createDirectory(parent, relativeTo: sessionURL)
        let temporaryURL = parent.appending(path: ".\(UUID().uuidString).tmp")
        do {
            try write(reader: reader, committedFrames: committedFrames, to: temporaryURL, sessionURL: sessionURL)
            try SessionFileAccess.rename(temporaryURL, to: destinationURL, relativeTo: sessionURL)
        } catch {
            do {
                try SessionFileAccess.removeIfPresent(temporaryURL, relativeTo: sessionURL)
            } catch let cleanupError {
                throw ProcessingTimelineAudioExporterError.temporaryFileNotRemoved(
                    path: temporaryURL.path,
                    writeFailure: error.localizedDescription,
                    cleanupFailure: cleanupError.localizedDescription
                )
            }
            throw error
        }
    }

    private func write(
        reader: any TimelineAudioReading,
        committedFrames: Int64,
        to url: URL,
        sessionURL: URL
    ) throws {
        let handle = try SessionFileAccess.openHandle(
            url, relativeTo: sessionURL, writable: true, create: true, exclusive: true
        )
        var closed = false
        defer {
            if !closed { try? handle.close() }
        }

        try handle.write(contentsOf: Self.header(committedFrames: committedFrames))
        var startFrame: Int64 = 0
        while startFrame < committedFrames {
            let requestedFrames = min(framesPerBuffer, committedFrames - startFrame)
            let requestedCount = Int(requestedFrames)
            let endFrame = startFrame + requestedFrames
            let samples = try reader.readSamples(frameRange: startFrame..<endFrame)
            guard samples.count == requestedCount else {
                throw ProcessingTimelineAudioExporterError.sourceLengthMismatch(
                    startFrame: startFrame,
                    expected: requestedCount,
                    actual: samples.count
                )
            }

            var buffer = Data()
            buffer.reserveCapacity(requestedCount * MemoryLayout<Float>.size)
            for (index, sample) in samples.enumerated() {
                guard sample.isFinite else {
                    throw ProcessingTimelineAudioExporterError.nonFiniteSample(
                        frame: startFrame + Int64(index)
                    )
                }
                Self.appendLittleEndian(sample.bitPattern, to: &buffer)
            }
            try handle.write(contentsOf: buffer)
            startFrame = endFrame
        }

        try handle.synchronize()
        try handle.close()
        closed = true
    }

    private static func header(committedFrames: Int64) -> Data {
        var data = Data()
        data.append(contentsOf: "caff".utf8)
        appendBigEndian(UInt16(1), to: &data)
        appendBigEndian(UInt16(0), to: &data)

        data.append(contentsOf: "desc".utf8)
        appendBigEndian(Int64(32), to: &data)
        appendBigEndian(Double(16_000).bitPattern, to: &data)
        data.append(contentsOf: "lpcm".utf8)
        appendBigEndian(UInt32(3), to: &data)
        appendBigEndian(UInt32(4), to: &data)
        appendBigEndian(UInt32(1), to: &data)
        appendBigEndian(UInt32(1), to: &data)
        appendBigEndian(UInt32(32), to: &data)

        data.append(contentsOf: "data".utf8)
        appendBigEndian(Int64(4) + committedFrames * 4, to: &data)
        appendBigEndian(UInt32(0), to: &data)
        return data
    }

    private static func appendBigEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
