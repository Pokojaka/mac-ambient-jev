import AVFoundation
import CoreMedia
import Foundation
import MacAmbientJevCore
import IOKit.audio
import Synchronization

public enum AudioCaptureEngineError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidInputFormat
    case inputUnavailable
    case noSystemAudioCaptured
    case noAudioCaptured
    case writerFailure(String)
    case insufficientDiskSpace(Int64)
    case cancelled
    case captureFailure(String)

    public var errorDescription: String? {
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
        case .noSystemAudioCaptured:
            "システム音声が届きませんでした。再生中の音声とシステムオーディオ録音の権限を確認してください"
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

public struct AudioCaptureStopResult: Sendable, Equatable {
    public let checkpoint: AudioCheckpoint
    public let didOverflow: Bool
    public let dropoutCount: UInt64
    public let gapCount: Int
    public let totalGapFrames: Int64
    public let sleepAssertionHeld: Bool
}

final class AudioCaptureReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let sink: TimestampedMonoSink
    private let sampleRate: Double
    private let channelCount: Int
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let pointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let strides: UnsafeMutablePointer<Int>
    private let onFormatChange: @Sendable () -> Void
    private let formatChangeNotified = Atomic(false)
    private var originPTS: CMTime?
    private var lastTimestampEnd: Int64 = 0

    var invalidBufferCount: UInt64 { sink.invalidBufferCount.load(ordering: .relaxed) }
    var lastBufferMillis: Int64 { sink.lastBufferMillis.load(ordering: .relaxed) }
    var silentSinceMillis: Int64 { sink.silentSinceMillis.load(ordering: .relaxed) }
    var lastEndFrame: Int64 { sink.lastEndFrame }

    init(ring: AudioBlockRing, sampleRate: Double, channelCount: Int,
         onFormatChange: @escaping @Sendable () -> Void,
         clock: any CaptureClock = SystemCaptureClock(), frameCapacity: Int = 16_384) {
        self.sink = TimestampedMonoSink(ring: ring, frameCapacity: frameCapacity, clock: clock)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.onFormatChange = onFormatChange
        self.buffers = AudioBufferList.allocate(maximumBuffers: channelCount)
        self.pointers = .allocate(capacity: channelCount)
        self.strides = .allocate(capacity: channelCount)
    }

    init(sink: TimestampedMonoSink, sampleRate: Double, channelCount: Int,
         onFormatChange: @escaping @Sendable () -> Void) {
        self.sink = sink
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.onFormatChange = onFormatChange
        self.buffers = AudioBufferList.allocate(maximumBuffers: channelCount)
        self.pointers = .allocate(capacity: channelCount)
        self.strides = .allocate(capacity: channelCount)
    }

    deinit {
        free(buffers.unsafeMutablePointer)
        pointers.deallocate()
        strides.deallocate()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        process(sampleBuffer)
    }

    // AVCapture's delegate queue serializes callbacks.
    func process(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        if originPTS == nil, pts.isValid { originPTS = pts }
        let start: Int64
        if let originPTS, pts.isValid {
            let frames = CMTimeGetSeconds(CMTimeSubtract(pts, originPTS)) * sampleRate
            start = frames.isFinite && abs(frames) < 1_000_000_000_000
                ? Int64(frames.rounded()) : lastTimestampEnd
        } else {
            start = lastTimestampEnd
        }
        if count > 0, !start.addingReportingOverflow(Int64(count)).overflow {
            lastTimestampEnd = max(lastTimestampEnd, start + Int64(count))
        }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mSampleRate == sampleRate, Int(format.mChannelsPerFrame) == channelCount,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
              format.mBitsPerChannel == 32 else {
            sink.missing(startFrame: start, frameCount: count)
            if !formatChangeNotified.exchange(true, ordering: .relaxed) { onFormatChange() }
            return
        }
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: buffers.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, buffers.count == channelCount, count > 0 else {
            sink.missing(startFrame: start, frameCount: count)
            return
        }
        for index in 0..<channelCount {
            let buffer = buffers[index]
            guard count <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
                  let data = buffer.mData else {
                sink.missing(startFrame: start, frameCount: count)
                return
            }
            pointers[index] = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            strides[index] = 1
        }
        sink.receive(channels: UnsafePointer(pointers), strides: UnsafePointer(strides),
                     channelCount: channelCount, frameCount: count, startFrame: start)
    }
}

@MainActor
public final class AudioCaptureEngine {
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
    private var sleepAssertionHeld = false
    private var healthTask: Task<Void, Never>?
    private var startingCancelled = false
    private var startingFailure: String?
    private var awaitingFirstBuffer = false

    private(set) public var activeSessionID: UUID?
    private(set) public var timeline: ProcessingTimeline?
    private var tap: (any SystemAudioTapProviding)?
    private var sink: TimestampedMonoSink?
    private let tapFactory: @MainActor () throws -> any SystemAudioTapProviding

    public var isRecording: Bool { session != nil || tap != nil }

    public convenience init(paths: AppPaths) {
        self.init(paths: paths, bufferFrameCount: 16_384)
    }

    init(
        paths: AppPaths,
        bufferFrameCount: Int = 16_384,
        ringCapacity: Int = 64,
        chunkDurationSeconds: Double = LiveTranscriptionCadence.durableChunkDurationSeconds,
        power: any RecordingPowerProviding = SystemRecordingPower(),
        clock: any CaptureClock = SystemCaptureClock(),
        diskSpace: any CaptureDiskSpaceProviding = VolumeCaptureDiskSpace(),
        notifications: any CaptureNotificationProviding = SystemCaptureNotifications(),
        tapFactory: @escaping @MainActor () throws -> any SystemAudioTapProviding = { try SystemAudioTap() }
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
        self.tapFactory = tapFactory
    }


    public func start(
        sessionID: UUID,
        source: CaptureSource = .microphone,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void = { _ in },
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) async throws {
        guard !isRecording else { throw AudioCaptureEngineError.alreadyRecording }
        let device: AVCaptureDevice?
        let input: AVCaptureDeviceInput?
        let tapBackend: (any SystemAudioTapProviding)?
        let sampleRate: Double
        let inputChannels: Int
        if source == .systemAudio {
            let backend = try tapFactory()
            tapBackend = backend
            sampleRate = backend.sampleRate
            inputChannels = 1
            device = nil
            input = nil
        } else {
            tapBackend = nil
            guard let selected = AVCaptureDevice.default(for: .audio) else {
                throw AudioCaptureEngineError.inputUnavailable
            }
            let selectedInput = try AVCaptureDeviceInput(device: selected)
            guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(
                selectedInput.device.activeFormat.formatDescription
            )?.pointee else { throw AudioCaptureEngineError.invalidInputFormat }
            device = selected
            input = selectedInput
            sampleRate = format.mSampleRate
            inputChannels = Int(format.mChannelsPerFrame)
        }
        var handedOff = false
        defer { if !handedOff { tapBackend?.stop() } }
        guard sampleRate > 0, inputChannels > 0 else {
            throw AudioCaptureEngineError.invalidInputFormat
        }
        let required = CaptureDiskPolicy.requiredStartBytes(sampleRate: sampleRate, channelCount: 1)
        if let available = try diskSpace.availableBytes(at: paths.sessionsRoot),
           !CaptureDiskPolicy.mayStart(availableBytes: available, sampleRate: sampleRate, channelCount: 1) {
            throw AudioCaptureEngineError.insufficientDiskSpace(required)
        }
        let processingDirectory = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
        let writer = try DurableAudioWriter(
            directory: processingDirectory, sampleRate: sampleRate,
            channelCount: 1, chunkDurationSeconds: chunkDurationSeconds
        )
        let ring = AudioBlockRing(
            capacity: max(ringCapacity, AudioBlockRing.capacityForDuration(
                sampleRate: sampleRate, blockFrameCapacity: bufferFrameCount, channelCount: 1
            )),
            blockFrameCapacity: bufferFrameCount, sampleRate: sampleRate
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer)
        let sink = TimestampedMonoSink(ring: ring, frameCapacity: bufferFrameCount, clock: clock)
        var captureSession: AVCaptureSession?
        var audioOutput: AVCaptureAudioDataOutput?
        var receiver: AudioCaptureReceiver?
        var callbackQueue: DispatchQueue?
        if let input {
            let configuredSession = AVCaptureSession()
            let configuredOutput = AVCaptureAudioDataOutput()
            configuredOutput.audioSettings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true
            ]
            guard configuredSession.canAddInput(input), configuredSession.canAddOutput(configuredOutput) else {
                throw AudioCaptureEngineError.inputUnavailable
            }
            configuredSession.addInput(input)
            configuredSession.addOutput(configuredOutput)
            let configuredReceiver = AudioCaptureReceiver(
                sink: sink, sampleRate: sampleRate, channelCount: inputChannels,
                onFormatChange: { [onFailure] in
                    Task { @MainActor in onFailure("入力デバイスの音声形式が変わったため、録音を停止しました") }
                }
            )
            let queue = DispatchQueue(label: "app.mac-ambient-jev.capture")
            configuredOutput.setSampleBufferDelegate(configuredReceiver, queue: queue)
            captureSession = configuredSession
            audioOutput = configuredOutput
            receiver = configuredReceiver
            callbackQueue = queue
        }
        awaitingFirstBuffer = true
        startingFailure = nil
        startingCancelled = false
        let reportFailure: @MainActor @Sendable (String) -> Void = { [weak self] message in
            if self?.awaitingFirstBuffer == true { self?.startingFailure = message }
            onFailure(message)
        }
        let powerAcquired = power.begin()
        sleepAssertionHeld = powerAcquired
        if !powerAcquired {
            onWarning("スリープ防止を設定できませんでした。録音中はスリープを避けてください")
        }
        let startedAt = clock.now()
        do {
            if let tapBackend {
                try tapBackend.start(sink: sink, onFailure: reportFailure)
            } else if let captureSession {
                captureSession.startRunning()
                guard captureSession.isRunning else { throw AudioCaptureEngineError.inputUnavailable }
            }
        } catch {
            audioOutput?.setSampleBufferDelegate(nil, queue: nil)
            captureSession?.stopRunning()
            power.end()
            awaitingFirstBuffer = false
            throw error
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
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return nil }
            }
            return nil
        }
        self.tap = tapBackend
        self.session = captureSession
        self.output = audioOutput
        self.receiver = receiver
        self.callbackQueue = callbackQueue
        self.sink = sink
        self.ring = ring
        self.drain = drain
        self.drainTask = task
        self.overflowAtStart = ring.overflowCount
        self.activeSessionID = sessionID
        self.timeline = ProcessingTimeline(sampleRate: sampleRate, channelCount: 1, sampleFormat: .float32LE)
        handedOff = true
        if let captureSession, let device {
            failureObservers.start(session: captureSession, device: device, onFailure: reportFailure)
            if CaptureInputWarnings.isLowRateBluetooth(transportType: device.transportType, sampleRate: sampleRate) {
                onWarning("Bluetoothマイクは音質が低下します")
            }
        }
        while true {
            let state = CaptureStartStatus.evaluate(
                startedAt: startedAt, now: clock.now(),
                lastBufferMillis: sink.lastBufferMillis.load(ordering: .relaxed),
                cancelled: startingCancelled || Task.isCancelled, failure: startingFailure
            )
            switch state {
            case .ready:
                awaitingFirstBuffer = false
                let monitor = CaptureHealthMonitor(
                    clock: clock, diskSpace: diskSpace, directory: paths.sessionsRoot,
                    startedAt: startedAt, onFailure: reportFailure,
                    onWarning: onWarning, onDropouts: onDropouts,
                    onSilenceChanged: onSilenceChanged
                )
                healthTask = Task {
                    while !Task.isCancelled, self.activeSessionID == sessionID {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                        guard monitor.poll(
                            lastBufferMillis: sink.lastBufferMillis.load(ordering: .relaxed),
                            silentSinceMillis: sink.silentSinceMillis.load(ordering: .relaxed),
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
                case .timedOut:
                    throw source == .systemAudio
                        ? AudioCaptureEngineError.noSystemAudioCaptured
                        : AudioCaptureEngineError.noAudioCaptured
                default: preconditionFailure("Unexpected startup state")
                }
            }
        }
    }

    public func cancelStarting() {
        startingCancelled = true
    }

    /// Termination cannot await a final partial chunk; previously committed chunks stay recoverable.
    public func terminate() {
        healthTask?.cancel()
        drainTask?.cancel()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        tap?.stop()
        tap = nil
        failureObservers.stop()
        power.end()
    }

    /// Returns the portion of the recording that is already durable on disk.
    /// The current partial writer chunk is intentionally left in memory.
    public func committedCheckpoint() async throws -> AudioCheckpoint {
        guard let drain else {
            throw AudioCaptureEngineError.notRecording
        }
        return try await drain.committedSnapshot()
    }

    public func stop() async throws -> AudioCaptureStopResult {
        guard let ring, let drain, let sink else {
            throw AudioCaptureEngineError.notRecording
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning()
        callbackQueue?.sync {}
        tap?.stop()
        ring.finish(tailFrame: sink.lastEndFrame)
        healthTask?.cancel()
        healthTask = nil
        failureObservers.stop()
        defer {
            self.session = nil
            self.output = nil
            self.receiver = nil
            self.callbackQueue = nil
            self.tap = nil
            self.sink = nil
            self.ring = nil
            self.drain = nil
            self.drainTask = nil
            self.activeSessionID = nil
            self.power.end()
            self.sleepAssertionHeld = false
        }
        let backgroundFailure: String?
        if let drainTask {
            drainTask.cancel()
            backgroundFailure = await drainTask.value
        } else {
            backgroundFailure = nil
        }
        let checkpoint = try await drain.finish()
        let gaps = await drain.gapStatistics()
        if let backgroundFailure {
            throw AudioCaptureEngineError.writerFailure(backgroundFailure)
        }
        guard checkpoint.committedFrames > 0 else {
            throw sink.invalidBufferCount.load(ordering: .relaxed) > 0
                ? AudioCaptureEngineError.invalidInputFormat
                : AudioCaptureEngineError.noAudioCaptured
        }
        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: ring.overflowCount > overflowAtStart
                || sink.invalidBufferCount.load(ordering: .relaxed) > 0,
            dropoutCount: ring.dropoutCount,
            gapCount: gaps.count,
            totalGapFrames: gaps.frames,
            sleepAssertionHeld: sleepAssertionHeld
        )
    }
}
