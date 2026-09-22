import AVFoundation
import Foundation
import MacAmbientJevCore

enum AudioCaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case writerFailure(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "すでに録音中です"
        case .notRecording:
            "録音は開始されていません"
        case .invalidInputFormat:
            "マイクの音声形式を利用できません"
        case .writerFailure(let message):
            "録音データの保存中にエラーが発生しました: \(message)"
        }
    }
}

struct AudioCaptureStopResult: Sendable, Equatable {
    let checkpoint: AudioCheckpoint
    let didOverflow: Bool
}

@MainActor
final class AudioCaptureEngine {
    private let paths: AppPaths
    private let bufferFrameCount: AVAudioFrameCount
    private let ringCapacity: Int

    private var engine: AVAudioEngine?
    private var ring: AudioBlockRing?
    private var drain: AudioCaptureDrain?
    private var drainTask: Task<String?, Never>?
    private var overflowAtStart: UInt64 = 0

    private(set) var activeSessionID: UUID?
    private(set) var timeline: ProcessingTimeline?

    var isRecording: Bool {
        engine != nil
    }

    init(
        paths: AppPaths,
        bufferFrameCount: AVAudioFrameCount = 2_048,
        ringCapacity: Int = 64
    ) {
        precondition(bufferFrameCount > 0)
        precondition(ringCapacity > 0)
        self.paths = paths
        self.bufferFrameCount = bufferFrameCount
        self.ringCapacity = ringCapacity
    }

    func start(sessionID: UUID) async throws {
        guard engine == nil else {
            throw AudioCaptureEngineError.alreadyRecording
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let channelCount = Int(inputFormat.channelCount)

        guard inputFormat.sampleRate > 0, channelCount > 0 else {
            throw AudioCaptureEngineError.invalidInputFormat
        }

        let processingDirectory = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)

        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            sampleRate: inputFormat.sampleRate,
            channelCount: channelCount
        )
        let ring = AudioBlockRing(
            capacity: ringCapacity,
            blockFrameCapacity: Int(bufferFrameCount) * channelCount
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer)

        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferFrameCount,
            format: inputFormat
        ) { buffer, _ in
            guard
                let channelData = buffer.floatChannelData,
                buffer.frameLength > 0
            else {
                return
            }

            _ = ring.pushPlanarFloat32(
                channelData: channelData,
                channelCount: Int(buffer.format.channelCount),
                frameCount: Int(buffer.frameLength)
            )
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        let task = Task.detached(priority: .utility) { () -> String? in
            while !Task.isCancelled {
                do {
                    _ = try await drain.drainAvailable()
                } catch {
                    return error.localizedDescription
                }

                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return nil
                }
            }

            return nil
        }

        self.engine = audioEngine
        self.ring = ring
        self.drain = drain
        self.drainTask = task
        self.overflowAtStart = ring.overflowCount
        self.activeSessionID = sessionID
        self.timeline = ProcessingTimeline(
            sampleRate: inputFormat.sampleRate,
            channelCount: channelCount,
            sampleFormat: .float32LE
        )
    }

    /// Returns the portion of the recording that is already durable on disk.
    /// The current partial writer chunk is intentionally left in memory.
    func committedCheckpoint() async throws -> AudioCheckpoint {
        guard let drain else {
            throw AudioCaptureEngineError.notRecording
        }
        return try await drain.committedSnapshot()
    }

    func stop() async throws -> AudioCaptureStopResult {
        guard
            let engine,
            let ring,
            let drain
        else {
            throw AudioCaptureEngineError.notRecording
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        defer {
            self.engine = nil
            self.ring = nil
            self.drain = nil
            self.drainTask = nil
            self.activeSessionID = nil
        }

        let backgroundFailure: String?
        if let drainTask {
            drainTask.cancel()
            backgroundFailure = await drainTask.value
        } else {
            backgroundFailure = nil
        }

        let checkpoint = try await drain.finish()

        if let backgroundFailure {
            throw AudioCaptureEngineError.writerFailure(backgroundFailure)
        }

        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: ring.overflowCount > overflowAtStart
        )
    }
}
