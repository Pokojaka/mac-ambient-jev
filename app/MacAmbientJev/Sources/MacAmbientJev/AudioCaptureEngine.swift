import AVFoundation
import CoreMedia
import Foundation
import MacAmbientJevCore
import IOKit.audio
import Synchronization

enum AudioCaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case inputUnavailable
    case noAudioCaptured
    case writerFailure(String)
    case insufficientDiskSpace(Int64)
    case cancelled
    case captureFailure(String)

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
        case .insufficientDiskSpace(let bytes):
            "90分の録音に必要な空き容量がありません（必要: \(bytes / 1_000_000) MB）"
        case .cancelled:
            "録音の開始を中止しました"
        case .captureFailure(let message):
            message
        }
    }
}

struct AudioCaptureStopResult: Sendable, Equatable {
    let checkpoint: AudioCheckpoint
    let didOverflow: Bool
}

final class AudioCaptureReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let invalidBufferCount = Atomic<UInt64>(0)
    private let formatChangeNotified = Atomic(false)
    let lastBufferMillis = Atomic<Int64>(0)
    let silentSinceMillis = Atomic<Int64>(0)
    private(set) var lastEndFrame: Int64 = 0
    private var originPTS: CMTime?

    private let ring: AudioBlockRing
    private let sampleRate: Double
    private let channelCount: Int
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let onFormatChange: @Sendable () -> Void
    private let clock: any CaptureClock

    init(
        ring: AudioBlockRing,
        sampleRate: Double,
        channelCount: Int,
        onFormatChange: @escaping @Sendable () -> Void,
        clock: any CaptureClock = SystemCaptureClock()
    ) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.onFormatChange = onFormatChange
        self.clock = clock
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
        process(sampleBuffer)
    }

    // Capture callbacks are serialized by AVCaptureAudioDataOutput's delegate queue.
    func process(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        if originPTS == nil, pts.isValid { originPTS = pts }
        let startFrame: Int64
        if let originPTS, pts.isValid {
            let frames = CMTimeGetSeconds(CMTimeSubtract(pts, originPTS)) * sampleRate
            startFrame = frames.isFinite && abs(frames) < 1_000_000_000_000
                ? Int64(frames.rounded()) : lastEndFrame
        } else {
            startFrame = lastEndFrame
        }
        if frameCount > 0 {
            let (end, overflow) = startFrame.addingReportingOverflow(Int64(frameCount))
            if !overflow { lastEndFrame = max(lastEndFrame, end) }
        }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mSampleRate == sampleRate,
              Int(format.mChannelsPerFrame) == channelCount,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              format.mBitsPerChannel == 32 else {
            _ = invalidBufferCount.add(1, ordering: .relaxed)
            if frameCount > 0 {
                ring.noteMissing(startFrame: startFrame, frameCount: frameCount)
            }
            if !formatChangeNotified.exchange(true, ordering: .relaxed) {
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
        guard status == noErr, buffers.count == channelCount, frameCount > 0 else {
            _ = invalidBufferCount.add(1, ordering: .relaxed)
            if frameCount > 0 {
                ring.noteMissing(startFrame: startFrame, frameCount: frameCount)
            }
            return
        }

        var peak: Float = 0
        let valid = withUnsafeTemporaryAllocation(
            of: UnsafeMutablePointer<Float>.self, capacity: channelCount
        ) { channels -> Bool in
            for index in 0..<channelCount {
                let buffer = buffers[index]
                guard frameCount <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
                      let data = buffer.mData else {
                    ring.noteMissing(startFrame: startFrame, frameCount: frameCount)
                    _ = invalidBufferCount.add(1, ordering: .relaxed)
                    return false
                }
                channels[index] = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    peak = max(peak, abs(channels[index][frame]))
                }
            }
            _ = ring.pushPlanarFloat32(
                channelData: channels.baseAddress!,
                channelCount: channelCount,
                frameCount: frameCount,
                startFrame: startFrame
            )
            return true
        }
        guard valid else { return }
        let millis = Int64(clock.now() * 1_000)
        lastBufferMillis.store(millis, ordering: .relaxed)
        if peak < 0.00031622776 {
            if silentSinceMillis.load(ordering: .relaxed) == 0 {
                silentSinceMillis.store(millis, ordering: .relaxed)
            }
        } else {
            silentSinceMillis.store(0, ordering: .relaxed)
        }
    }
}

@MainActor
final class AudioCaptureEngine {
    private let paths: AppPaths
    private let bufferFrameCount: Int
    private let ringCapacity: Int
    private let chunkDurationSeconds: Double
    private let power: RecordingPowerLifetime
    private let clock: any CaptureClock
    private let diskSpace: any CaptureDiskSpaceProviding
    private let failureObservers: CaptureFailureObservers

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var receiver: AudioCaptureReceiver?
    private var callbackQueue: DispatchQueue?
    private var ring: AudioBlockRing?
    private var drain: AudioCaptureDrain?
    private var drainTask: Task<String?, Never>?
    private var overflowAtStart: UInt64 = 0
    private var healthTask: Task<Void, Never>?
    private var startingCancelled = false
    private var startingFailure: String?
    private var awaitingFirstBuffer = false

    private(set) var activeSessionID: UUID?
    private(set) var timeline: ProcessingTimeline?

    var isRecording: Bool {
        session != nil
    }

    init(
        paths: AppPaths,
        bufferFrameCount: Int = 16_384,
        ringCapacity: Int = 64,
        chunkDurationSeconds: Double = LiveTranscriptionCadence.durableChunkDurationSeconds,
        power: any RecordingPowerProviding = SystemRecordingPower(),
        clock: any CaptureClock = SystemCaptureClock(),
        diskSpace: any CaptureDiskSpaceProviding = VolumeCaptureDiskSpace(),
        notifications: any CaptureNotificationProviding = SystemCaptureNotifications()
    ) {
        precondition(bufferFrameCount > 0)
        precondition(ringCapacity > 0)
        precondition(chunkDurationSeconds > 0)
        self.paths = paths
        self.bufferFrameCount = bufferFrameCount
        self.ringCapacity = ringCapacity
        self.chunkDurationSeconds = chunkDurationSeconds
        self.power = RecordingPowerLifetime(provider: power)
        self.clock = clock
        self.diskSpace = diskSpace
        self.failureObservers = CaptureFailureObservers(provider: notifications)
    }

    func start(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in },
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
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
        let required = CaptureDiskPolicy.requiredStartBytes(
            sampleRate: format.mSampleRate, channelCount: channelCount
        )
        if let available = try diskSpace.availableBytes(at: paths.root),
           !CaptureDiskPolicy.mayStart(
            availableBytes: available, sampleRate: format.mSampleRate, channelCount: channelCount
           ) {
            throw AudioCaptureEngineError.insufficientDiskSpace(required)
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
        let slotSamples = min(bufferFrameCount, 512) * channelCount
        let ring = AudioBlockRing(
            capacity: max(ringCapacity, AudioBlockRing.capacityForDuration(
                sampleRate: format.mSampleRate,
                blockFrameCapacity: slotSamples,
                channelCount: channelCount
            )),
            blockFrameCapacity: slotSamples,
            sampleRate: format.mSampleRate
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
        awaitingFirstBuffer = true
        startingFailure = nil
        let reportFailure: @MainActor @Sendable (String) -> Void = { [weak self] message in
            if self?.awaitingFirstBuffer == true { self?.startingFailure = message }
            onFailure(message)
        }
        let receiver = AudioCaptureReceiver(
            ring: ring,
            sampleRate: format.mSampleRate,
            channelCount: channelCount,
            onFormatChange: {
                Task { @MainActor in
                    reportFailure("入力デバイスの音声形式が変わったため、録音を停止しました")
                }
            },
            clock: clock
        )
        let callbackQueue = DispatchQueue(label: "app.mac-ambient-jev.capture")
        startingCancelled = false
        let powerAcquired = power.begin()
        if !powerAcquired {
            onWarning("スリープ防止を設定できませんでした。録音中はスリープを避けてください")
        }
        audioOutput.setSampleBufferDelegate(receiver, queue: callbackQueue)
        let startedAt = clock.now()
        captureSession.startRunning()
        guard captureSession.isRunning else {
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            power.end()
            throw AudioCaptureEngineError.inputUnavailable
        }

        let task = Task.detached(priority: .utility) { () -> String? in
            while !Task.isCancelled {
                do {
                    _ = try await drain.drainAvailable()
                } catch {
                    let message = error.localizedDescription
                    await reportFailure("録音の保存に失敗しました: \(message)")
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
        failureObservers.start(session: captureSession, device: device, onFailure: reportFailure)
        if CaptureInputWarnings.isLowRateBluetooth(
            transportType: device.transportType, sampleRate: format.mSampleRate
        ) {
            onWarning("Bluetoothマイクは音質が低下します")
        }
        while true {
            let state = CaptureStartStatus.evaluate(
                startedAt: startedAt, now: clock.now(),
                lastBufferMillis: receiver.lastBufferMillis.load(ordering: .relaxed),
                cancelled: startingCancelled || Task.isCancelled,
                failure: startingFailure
            )
            switch state {
            case .ready:
                awaitingFirstBuffer = false
                let monitor = CaptureHealthMonitor(
                    clock: clock, diskSpace: diskSpace, directory: paths.root,
                    startedAt: startedAt, onFailure: reportFailure,
                    onWarning: onWarning, onDropouts: onDropouts,
                    onSilenceChanged: onSilenceChanged
                )
                healthTask = Task {
                    while !Task.isCancelled, self.activeSessionID == sessionID {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                        guard monitor.poll(
                            lastBufferMillis: receiver.lastBufferMillis.load(ordering: .relaxed),
                            silentSinceMillis: receiver.silentSinceMillis.load(ordering: .relaxed),
                            dropouts: ring.dropoutCount
                        ) else { break }
                    }
                }
                return
            case .waiting:
                try? await Task.sleep(for: .milliseconds(50))
            case .cancelled, .failed, .timedOut:
                awaitingFirstBuffer = false
                _ = try? await stop()
                switch state {
                case .cancelled: throw AudioCaptureEngineError.cancelled
                case .failed(let message): throw AudioCaptureEngineError.captureFailure(message)
                case .timedOut: throw AudioCaptureEngineError.noAudioCaptured
                default: preconditionFailure("Unexpected startup state")
                }
            }
        }
    }

    func cancelStarting() {
        startingCancelled = true
    }

    /// Termination cannot await a final partial chunk; previously committed chunks stay recoverable.
    func terminate() {
        healthTask?.cancel()
        drainTask?.cancel()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        failureObservers.stop()
        power.end()
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
        ring.finish(tailFrame: receiver.lastEndFrame)
        healthTask?.cancel()
        healthTask = nil
        failureObservers.stop()

        defer {
            self.session = nil
            self.output = nil
            self.receiver = nil
            self.callbackQueue = nil
            self.ring = nil
            self.drain = nil
            self.drainTask = nil
            self.activeSessionID = nil
            self.power.end()
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
        guard checkpoint.hasCapturedAudio else {
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
