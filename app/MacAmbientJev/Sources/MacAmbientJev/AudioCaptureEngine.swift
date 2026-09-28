import AVFoundation
import CoreMedia
import Foundation
import MacAmbientJevCore
import Synchronization

enum AudioCaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case inputUnavailable
    case noAudioCaptured
    case writerFailure(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "すでに録音中です"
        case .notRecording:
            "録音は開始されていません"
        case .invalidInputFormat:
            "マイクの音声形式を利用できません"
        case .inputUnavailable:
            "マイクから音声を取得できませんでした"
        case .noAudioCaptured:
            "マイクから音声が届きませんでした。入力デバイスとマイク権限を確認してください"
        case .writerFailure(let message):
            "録音データの保存中にエラーが発生しました: \(message)"
        }
    }
}

struct AudioCaptureStopResult: Sendable, Equatable {
    let checkpoint: AudioCheckpoint
    let didOverflow: Bool
}

private final class AudioCaptureReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let invalidBufferCount = Atomic<UInt64>(0)

    private let ring: AudioBlockRing
    private let sampleRate: Double
    private let channelCount: Int
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let onFormatChange: @Sendable () -> Void

    init(
        ring: AudioBlockRing,
        sampleRate: Double,
        channelCount: Int,
        onFormatChange: @escaping @Sendable () -> Void
    ) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.onFormatChange = onFormatChange
        self.buffers = AudioBufferList.allocate(maximumBuffers: channelCount)
    }

    deinit {
        free(buffers.unsafeMutablePointer)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mSampleRate == sampleRate,
              Int(format.mChannelsPerFrame) == channelCount,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              format.mBitsPerChannel == 32 else {
            if invalidBufferCount.add(1, ordering: .relaxed).oldValue == 0 {
                onFormatChange()
            }
            return
        }

        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &block
        )
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard status == noErr, buffers.count == channelCount, frameCount > 0 else {
            _ = invalidBufferCount.add(1, ordering: .relaxed)
            return
        }

        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: channelCount) { channels in
            for index in 0..<channelCount {
                let buffer = buffers[index]
                guard Int(buffer.mDataByteSize) >= frameCount * MemoryLayout<Float>.size,
                      let data = buffer.mData else {
                    _ = invalidBufferCount.add(1, ordering: .relaxed)
                    return
                }
                channels[index] = data.assumingMemoryBound(to: Float.self)
            }
            _ = ring.pushPlanarFloat32(
                channelData: channels.baseAddress!,
                channelCount: channelCount,
                frameCount: frameCount
            )
        }
    }
}

@MainActor
final class AudioCaptureEngine {
    private let paths: AppPaths
    private let bufferFrameCount: Int
    private let ringCapacity: Int
    private let chunkDurationSeconds: Double

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var receiver: AudioCaptureReceiver?
    private var callbackQueue: DispatchQueue?
    private var ring: AudioBlockRing?
    private var drain: AudioCaptureDrain?
    private var drainTask: Task<String?, Never>?
    private var overflowAtStart: UInt64 = 0

    private(set) var activeSessionID: UUID?
    private(set) var timeline: ProcessingTimeline?

    var isRecording: Bool {
        session != nil
    }

    init(
        paths: AppPaths,
        bufferFrameCount: Int = 16_384,
        ringCapacity: Int = 64,
        chunkDurationSeconds: Double = LiveTranscriptionCadence.durableChunkDurationSeconds
    ) {
        precondition(bufferFrameCount > 0)
        precondition(ringCapacity > 0)
        precondition(chunkDurationSeconds > 0)
        self.paths = paths
        self.bufferFrameCount = bufferFrameCount
        self.ringCapacity = ringCapacity
        self.chunkDurationSeconds = chunkDurationSeconds
    }

    func start(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard session == nil else {
            throw AudioCaptureEngineError.alreadyRecording
        }

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureEngineError.inputUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(
            input.device.activeFormat.formatDescription
        )?.pointee else {
            throw AudioCaptureEngineError.invalidInputFormat
        }
        let channelCount = Int(format.mChannelsPerFrame)

        guard format.mSampleRate > 0, channelCount > 0 else {
            throw AudioCaptureEngineError.invalidInputFormat
        }

        let processingDirectory = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)

        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            sampleRate: format.mSampleRate,
            channelCount: channelCount,
            chunkDurationSeconds: chunkDurationSeconds
        )
        let ring = AudioBlockRing(
            capacity: ringCapacity,
            blockFrameCapacity: bufferFrameCount * channelCount
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer)

        let captureSession = AVCaptureSession()
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.audioSettings = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        guard captureSession.canAddInput(input), captureSession.canAddOutput(audioOutput) else {
            throw AudioCaptureEngineError.inputUnavailable
        }
        captureSession.addInput(input)
        captureSession.addOutput(audioOutput)
        let receiver = AudioCaptureReceiver(
            ring: ring,
            sampleRate: format.mSampleRate,
            channelCount: channelCount,
            onFormatChange: {
                Task { @MainActor in
                    onFailure("入力デバイスの音声形式が変わったため、録音を保存できていません。録音を停止してください")
                }
            }
        )
        let callbackQueue = DispatchQueue(label: "app.mac-ambient-jev.capture")
        audioOutput.setSampleBufferDelegate(receiver, queue: callbackQueue)
        captureSession.startRunning()
        guard captureSession.isRunning else {
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            throw AudioCaptureEngineError.inputUnavailable
        }

        let task = Task.detached(priority: .utility) { () -> String? in
            while !Task.isCancelled {
                do {
                    _ = try await drain.drainAvailable()
                } catch {
                    let message = error.localizedDescription
                    await onFailure("録音の保存に失敗しました: \(message)")
                    return message
                }

                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    return nil
                }
            }

            return nil
        }

        self.session = captureSession
        self.output = audioOutput
        self.receiver = receiver
        self.callbackQueue = callbackQueue
        self.ring = ring
        self.drain = drain
        self.drainTask = task
        self.overflowAtStart = ring.overflowCount
        self.activeSessionID = sessionID
        self.timeline = ProcessingTimeline(
            sampleRate: format.mSampleRate,
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
            let session,
            let output,
            let receiver,
            let callbackQueue,
            let ring,
            let drain
        else {
            throw AudioCaptureEngineError.notRecording
        }

        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        callbackQueue.sync {}

        defer {
            self.session = nil
            self.output = nil
            self.receiver = nil
            self.callbackQueue = nil
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
        guard checkpoint.committedFrames > 0 else {
            throw receiver.invalidBufferCount.load(ordering: .relaxed) > 0
                ? AudioCaptureEngineError.invalidInputFormat
                : AudioCaptureEngineError.noAudioCaptured
        }

        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: ring.overflowCount > overflowAtStart
                || receiver.invalidBufferCount.load(ordering: .relaxed) > 0
        )
    }
}
