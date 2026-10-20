import Foundation
#if os(Windows)
import ucrt
#endif

public enum DurableAudioWriterError: LocalizedError, Equatable {
    case incompatibleCheckpoint
    case corruptChunk(String)
    case checkpointFrameCountMismatch
    case outOfSpace(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleCheckpoint:
            "保存済み音声の索引が録音の形式と一致しません"
        case .corruptChunk(let filename):
            "保存済み音声の断片 \(filename) が壊れています"
        case .checkpointFrameCountMismatch:
            "保存済み音声の長さが索引と一致しません"
        case .outOfSpace(let filename):
            "空き容量が不足したため \(filename) を書き込めませんでした"
        case .writeFailed(let filename):
            "\(filename) を書き込めませんでした"
        }
    }

    /// Maps a file-system failure while writing `filename` to its user-facing cause.
    static func writing<T>(_ filename: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DurableAudioWriterError {
            throw error
        } catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ELOOP) {
            throw error
        } catch {
            let nsError = error as NSError
            var posixSpaceErrors = [Int(ENOSPC)]
            #if !os(Windows)
            posixSpaceErrors.append(Int(EDQUOT))
            #endif
            let causes = [nsError, nsError.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
            let outOfSpace = causes.contains {
                ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                    || ($0.domain == NSPOSIXErrorDomain && posixSpaceErrors.contains($0.code))
                    || ($0.domain == "NSWin32ErrorDomain" && [39, 112].contains($0.code))
            }
            throw outOfSpace ? DurableAudioWriterError.outOfSpace(filename)
                : DurableAudioWriterError.writeFailed(filename)
        }
    }
}
private struct AudioChunkCommit: Codable {
    let index: Int
    let frames: Int
}

public struct AudioGapEvent: Codable, Sendable, Equatable {
    public let startFrame: Int64
    public let frameCount: Int64
    public let reason: AudioGapReason

    public init(startFrame: Int64, frameCount: Int64, reason: AudioGapReason) {
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.reason = reason
    }
}


public struct AudioCheckpoint: Codable, Sendable, Equatable {
    public let committedFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let sampleFormat: PCMSampleFormat
    public let chunkFiles: [String]
    public let chunkFrameCounts: [Int]
    public let gapEvents: [AudioGapEvent]

    public init(
        committedFrames: Int64,
        sampleRate: Double,
        channelCount: Int,
        sampleFormat: PCMSampleFormat,
        chunkFiles: [String],
        chunkFrameCounts: [Int],
        gapEvents: [AudioGapEvent]
    ) {
        self.committedFrames = committedFrames
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.chunkFiles = chunkFiles
        self.chunkFrameCounts = chunkFrameCounts
        self.gapEvents = gapEvents
    }
}

extension AudioCheckpoint {
    public var hasPlainUniqueChunkFiles: Bool {
        Set(chunkFiles.map { $0.uppercased() }).count == chunkFiles.count
            && chunkFiles.allSatisfy(PortableFileName.isValid)
    }

    /// Rebuilds the latest committed timeline from the JSON snapshot, the chunk
    /// index and contiguous atomically published chunk files. Readers need not wait for finish().
    public static func loadRecovered(from directory: URL, relativeTo root: URL) throws -> AudioCheckpoint? {
        let checkpointURL = directory.appending(path: DurableAudioWriter.checkpointFilename)
        guard let data = try SessionFileAccess.readIfPresent(checkpointURL, relativeTo: root) else { return nil }
        let snapshot = try JSONDecoder().decode(AudioCheckpoint.self, from: data)
        guard snapshot.sampleFormat == CanonicalAudio.sampleFormat,
              snapshot.hasPlainUniqueChunkFiles,
              snapshot.channelCount == CanonicalAudio.channelCount,
              snapshot.sampleRate == CanonicalAudio.sampleRate,
              snapshot.chunkFrameCounts.count == snapshot.chunkFiles.count,
              snapshot.chunkFrameCounts.allSatisfy({ (1...Int(Int32.max)).contains($0) }) else {
            throw DurableAudioWriterError.incompatibleCheckpoint
        }
        var indexedFrames: Int64 = 0
        for count in snapshot.chunkFrameCounts {
            let (sum, overflow) = indexedFrames.addingReportingOverflow(Int64(count))
            guard !overflow else { throw DurableAudioWriterError.checkpointFrameCountMismatch }
            indexedFrames = sum
        }
        guard indexedFrames == snapshot.committedFrames else {
            throw DurableAudioWriterError.checkpointFrameCountMismatch
        }

        let chunkIndex = try loadChunkIndex(from: directory, relativeTo: root)
        let bytesPerFrame = MemoryLayout<Float>.size * snapshot.channelCount
        var files = snapshot.chunkFiles
        var counts: [Int] = []
        var frames: Int64 = 0
        for (index, filename) in files.enumerated() {
            let size = try SessionFileAccess.fileSize(directory.appending(path: filename), relativeTo: root)
            guard size > 0, size % bytesPerFrame == 0 else {
                throw DurableAudioWriterError.corruptChunk(filename)
            }
            let (expectedBytes, overflow) = snapshot.chunkFrameCounts[index]
                .multipliedReportingOverflow(by: bytesPerFrame)
            guard !overflow, expectedBytes == size else {
                throw DurableAudioWriterError.corruptChunk(filename)
            }
            if let committed = chunkIndex[index], committed != size / bytesPerFrame {
                throw DurableAudioWriterError.corruptChunk(filename)
            }
            let count = size / bytesPerFrame
            counts.append(count)
            frames += Int64(count)
        }

        // A crash after publishing a chunk but before the next snapshot leaves
        // complete trailing chunks that still belong to the timeline.
        var next = files.count
        while true {
            let filename = String(format: "chunk-%06d.f32le", next)
            let url = directory.appending(path: filename)
            let size: Int
            do { size = try SessionFileAccess.fileSize(url, relativeTo: root) }
            catch let error as CocoaError where (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(ENOENT) { break }
            guard size > 0, size % bytesPerFrame == 0 else {
                throw DurableAudioWriterError.corruptChunk(filename)
            }
            if let committed = chunkIndex[next], committed != size / bytesPerFrame {
                throw DurableAudioWriterError.corruptChunk(filename)
            }
            let count = size / bytesPerFrame
            files.append(filename)
            counts.append(count)
            let (total, overflow) = frames.addingReportingOverflow(Int64(count))
            guard !overflow else { throw DurableAudioWriterError.checkpointFrameCountMismatch }
            frames = total
            next += 1
        }
        if let unexpected = chunkIndex.keys.first(where: { $0 >= next }) {
            throw DurableAudioWriterError.corruptChunk(
                String(format: "chunk-%06d.f32le", unexpected)
            )
        }
        return AudioCheckpoint(
            committedFrames: frames, sampleRate: snapshot.sampleRate,
            channelCount: snapshot.channelCount, sampleFormat: snapshot.sampleFormat,
            chunkFiles: files, chunkFrameCounts: counts,
            gapEvents: try loadGapEvents(
                from: directory, relativeTo: root, snapshotEvents: snapshot.gapEvents,
                snapshotFrames: snapshot.committedFrames, committedFrames: frames
            )
        )
    }

    private static func loadGapEvents(
        from directory: URL, relativeTo root: URL, snapshotEvents: [AudioGapEvent],
        snapshotFrames: Int64, committedFrames: Int64
    ) throws -> [AudioGapEvent] {
        let url = directory.appending(path: DurableAudioWriter.gapEventsFilename)
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: root) else {
            throw DurableAudioWriterError.incompatibleCheckpoint
        }
        let recovered = try SessionRecovery.recoverJSONL(data)
        var lines = recovered.lines
        // Only newline-terminated records were fully appended and synchronized.
        if data.last != 0x0A && !recovered.droppedIncompleteTail && !lines.isEmpty {
            lines.removeLast()
        }
        let decoded = try lines.map { try JSONDecoder().decode(AudioGapEvent.self, from: $0) }
        guard decoded.starts(with: snapshotEvents)
                || committedGaps(Array(decoded.prefix(snapshotEvents.count)), through: snapshotFrames) == snapshotEvents else {
            throw DurableAudioWriterError.incompatibleCheckpoint
        }
        // The gap record is synced before its silence. A crash can leave a valid
        // log entry whose corresponding audio never reached a durable chunk.
        for event in decoded {
            guard event.startFrame >= 0, event.frameCount > 0 else {
                throw DurableAudioWriterError.incompatibleCheckpoint
            }
        }
        return committedGaps(decoded, through: committedFrames)
    }

    fileprivate static func committedGaps(_ events: [AudioGapEvent], through frames: Int64) -> [AudioGapEvent] {
        guard let last = events.last else { return events }
        if last.startFrame >= 0, last.startFrame < frames,
           last.frameCount > 0, last.frameCount <= frames - last.startFrame {
            return events
        }
        return events.compactMap { event in
            guard event.startFrame >= 0, event.frameCount > 0,
                  event.startFrame < frames else { return nil }
            return AudioGapEvent(
                startFrame: event.startFrame,
                frameCount: min(event.frameCount, frames - event.startFrame),
                reason: event.reason
            )
        }
    }
    private static func loadChunkIndex(from directory: URL, relativeTo root: URL) throws -> [Int: Int] {
        let url = directory.appending(path: DurableAudioWriter.chunkIndexFilename)
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: root) else {
            throw DurableAudioWriterError.incompatibleCheckpoint
        }
        let recovered = try SessionRecovery.recoverJSONL(data)
        let lines = data.last == 0x0A ? recovered.lines : Array(recovered.lines.dropLast(
            recovered.droppedIncompleteTail || recovered.lines.isEmpty ? 0 : 1
        ))
        var counts: [Int: Int] = [:]
        for line in lines {
            let entry = try JSONDecoder().decode(AudioChunkCommit.self, from: line)
            guard entry.index >= 0, (1...Int(Int32.max)).contains(entry.frames),
                  counts[entry.index].map({ $0 == entry.frames }) ?? true else {
                throw DurableAudioWriterError.incompatibleCheckpoint
            }
            counts[entry.index] = entry.frames
        }
        return counts
    }

    fileprivate static func repairChunkIndex(in directory: URL, relativeTo root: URL) throws {
        let url = directory.appending(path: DurableAudioWriter.chunkIndexFilename)
        guard let data = try SessionFileAccess.readIfPresent(url, relativeTo: root) else {
            try SessionFileAccess.writeAtomically(Data(), to: url, relativeTo: root)
            return
        }
        if data.last != 0x0A {
            let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            try SessionFileAccess.writeAtomically(Data(data.prefix(end)), to: url, relativeTo: root)
        }
    }


    private static func gapLogData(_ events: [AudioGapEvent]) throws -> Data {
        var data = Data()
        let encoder = JSONEncoder()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        return data
    }

    fileprivate static func repairGapLog(in directory: URL, relativeTo root: URL, events: [AudioGapEvent]) throws {
        let url = directory.appending(path: DurableAudioWriter.gapEventsFilename)
        let data = try gapLogData(events)
        if try SessionFileAccess.readIfPresent(url, relativeTo: root) != data {
            try SessionFileAccess.writeAtomically(data, to: url, relativeTo: root)
        }
    }
}

public actor DurableAudioWriter {
    public static let checkpointFilename = "checkpoint.json"
    public static let gapEventsFilename = "audio-gaps.jsonl"

    public let directory: URL
    private let sessionURL: URL
    public let chunkDurationSeconds: Double

    public static let chunkIndexFilename = "audio-chunks.jsonl"
    private let framesPerChunk: Int
    private var pendingSamples: [Float] = []
    private var committedFrames: Int64
    private var chunkFiles: [String]
    private var chunkFrameCounts: [Int]
    private var gapEvents: [AudioGapEvent]
    private var nextChunkIndex: Int

    public init(directory: URL, chunkDurationSeconds: Double, sessionURL: URL) throws {
        precondition(chunkDurationSeconds > 0)

        self.directory = directory
        self.sessionURL = sessionURL
        self.chunkDurationSeconds = chunkDurationSeconds
        self.framesPerChunk = max(
            1,
            Int((CanonicalAudio.sampleRate * chunkDurationSeconds).rounded(.down))
        )

        try SessionFileAccess.createDirectory(directory, relativeTo: sessionURL)

        let checkpointURL = directory.appending(path: Self.checkpointFilename)
        let checkpoint = try AudioCheckpoint.loadRecovered(from: directory, relativeTo: sessionURL)
        self.committedFrames = checkpoint?.committedFrames ?? 0
        self.chunkFiles = checkpoint?.chunkFiles ?? []
        self.chunkFrameCounts = checkpoint?.chunkFrameCounts ?? []
        self.gapEvents = checkpoint?.gapEvents ?? []
        self.nextChunkIndex = checkpoint?.chunkFiles.count ?? 0

        // Restore a torn gap-log tail before any new append.
        try AudioCheckpoint.repairGapLog(in: directory, relativeTo: sessionURL, events: gapEvents)
        try AudioCheckpoint.repairChunkIndex(in: directory, relativeTo: sessionURL)

        // Initialization is a checkpoint boundary, including recovery of orphan chunks.
        let initialCheckpoint = AudioCheckpoint(
            committedFrames: committedFrames,
            sampleRate: CanonicalAudio.sampleRate,
            channelCount: CanonicalAudio.channelCount,
            sampleFormat: CanonicalAudio.sampleFormat,
            chunkFiles: chunkFiles,
            chunkFrameCounts: chunkFrameCounts,
            gapEvents: gapEvents
        )
        try SessionFileAccess.writeAtomically(JSONEncoder().encode(initialCheckpoint), to: checkpointURL, relativeTo: sessionURL)
    }

    public func append(samples: [Float]) throws {
        guard samples.allSatisfy(\.isFinite) else { throw CanonicalAudioError.invalidSamples }
        let samplesPerChunk = framesPerChunk
        var offset = 0
        while offset < samples.count {
            // A previous failed write leaves a full chunk pending for retry.
            if pendingSamples.count == samplesPerChunk {
                try writeChunk(sampleCount: samplesPerChunk)
            }
            let count = min(samplesPerChunk - pendingSamples.count, samples.count - offset)
            pendingSamples.append(contentsOf: samples[offset..<(offset + count)])
            offset += count
            if pendingSamples.count == samplesPerChunk {
                try writeChunk(sampleCount: samplesPerChunk)
            }
        }
    }

    /// Persists a discontinuity before its replacement silence enters the chunk stream.
    public func recordGap(
        startFrame: Int64, frameCount: Int64, reason: AudioGapReason
    ) throws {
        precondition(startFrame >= 0 && frameCount > 0)
        let event = AudioGapEvent(
            startFrame: startFrame, frameCount: frameCount, reason: reason
        )
        var line = try JSONEncoder().encode(event)
        line.append(0x0A)
        try appendSynchronized(line, to: Self.gapEventsFilename)
        gapEvents.append(event)
    }

    /// Returns only frames that have already been atomically committed as chunk files.
    ///
    /// Unlike checkpoint(), this does not flush the in-memory partial chunk. It is
    /// therefore safe to poll while capture continues without fragmenting the timeline.
    public func committedSnapshot() -> AudioCheckpoint {
        currentCheckpoint()
    }

    public func checkpoint() throws -> AudioCheckpoint {
        try flushPendingChunk()
        let checkpoint = currentCheckpoint()
        try persist(checkpoint)
        return checkpoint
    }

    public func finish() throws -> AudioCheckpoint {
        try checkpoint()
    }

    private func flushPendingChunk() throws {
        guard !pendingSamples.isEmpty else { return }
        try writeChunk(sampleCount: pendingSamples.count)
    }

    private func writeChunk(sampleCount: Int) throws {
        let filename = String(
            format: "chunk-%06d.f32le",
            nextChunkIndex
        )
        let url = directory.appending(path: filename)
        let data = pendingSamples[..<sampleCount].withUnsafeBytes { Data($0) }
        // An index record must never be durable before the chunk it names.
        try DurableAudioWriterError.writing(filename) {
            try SessionFileAccess.writeAtomically(data, to: url, relativeTo: sessionURL)
        }
        let frames = sampleCount
        var line = try JSONEncoder().encode(AudioChunkCommit(index: nextChunkIndex, frames: frames))
        line.append(0x0A)
        try appendSynchronized(line, to: Self.chunkIndexFilename)
        pendingSamples.removeAll(keepingCapacity: true)
        committedFrames += Int64(frames)
        chunkFiles.append(filename)
        chunkFrameCounts.append(frames)
        nextChunkIndex += 1
    }

    private func appendSynchronized(_ line: Data, to filename: String) throws {
        try DurableAudioWriterError.writing(filename) {
            let handle = try SessionFileAccess.openHandle(directory.appending(path: filename), relativeTo: sessionURL, writable: true)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.synchronize()
            try handle.close()
        }
    }

    private func currentCheckpoint() -> AudioCheckpoint {
        AudioCheckpoint(
            committedFrames: committedFrames,
            sampleRate: CanonicalAudio.sampleRate,
            channelCount: CanonicalAudio.channelCount,
            sampleFormat: CanonicalAudio.sampleFormat,
            chunkFiles: chunkFiles,
            chunkFrameCounts: chunkFrameCounts,
            gapEvents: AudioCheckpoint.committedGaps(gapEvents, through: committedFrames)
        )
    }

    private func persist(_ checkpoint: AudioCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try DurableAudioWriterError.writing(Self.checkpointFilename) {
            try SessionFileAccess.writeAtomically(data, to: directory.appending(path: Self.checkpointFilename), relativeTo: sessionURL)
        }
    }
}
