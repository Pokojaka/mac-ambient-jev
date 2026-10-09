import AVFoundation
import CoreMedia
import Foundation
import MacAmbientJevCore
import MacAmbientJevAppleSupport
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
    case diskSpaceUnavailable(String)
    case cancelled
    case captureFailure(String)
    case micInputVolumeNotConfigured

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
        case .writerFailure(let cause):
            "録音の保存に失敗しました: \(cause)"
        case .insufficientDiskSpace(let bytes):
            "90分の録音に必要な空き容量がありません（必要: \(bytes / 1_000_000) MB）"
        case .diskSpaceUnavailable(let cause):
            "空き容量を確認できないため録音を開始できません: \(cause)"
        case .cancelled:
            "録音の開始を中止しました"
        case .captureFailure(let message):
            message
        case .micInputVolumeNotConfigured:
            "マイク入力音量の設定が録音開始前に指定されていません"
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
    /// The storage failure that ended the recording; `checkpoint` is then the healthy durable prefix.
    public let writerFailure: String?
    /// Core Audio refused to release part of the system-audio tap.
    public let systemAudioReleaseFailure: String?

    public init(
        checkpoint: AudioCheckpoint, didOverflow: Bool,
        dropoutCount: UInt64, gapCount: Int,
        totalGapFrames: Int64, sleepAssertionHeld: Bool,
        writerFailure: String?, systemAudioReleaseFailure: String?
    ) {
        self.checkpoint = checkpoint
        self.didOverflow = didOverflow || !checkpoint.gapEvents.isEmpty
        self.dropoutCount = dropoutCount
        self.gapCount = gapCount
        self.totalGapFrames = totalGapFrames
        self.sleepAssertionHeld = sleepAssertionHeld
        self.writerFailure = writerFailure
        self.systemAudioReleaseFailure = systemAudioReleaseFailure
    }
}

final class AudioCaptureReceiver: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let sink: TimestampedMonoSink
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
         clock: any CaptureClock, frameCapacity: Int,
         meter: RawInputMeter?) {
        self.sink = TimestampedMonoSink(ring: ring, frameCapacity: frameCapacity, clock: clock,
                                        meter: meter)
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

private struct MicInputVolumeConfiguration {
    let automaticAdjustmentEnabled: Bool
    let onStatus: @MainActor @Sendable (UUID, MicInputStatus) -> Void
}

@MainActor
public final class AudioCaptureEngine {
    static let micMeterPollInterval: Duration = .milliseconds(100)
    static let micAcknowledgementTimeout: TimeInterval = 1
    static let micPendingWriteTimeout: TimeInterval = 1.5

    private let paths: AppPaths
    private let bufferFrameCount: Int
    private let ringCapacity: Int
    private let chunkDurationSeconds: Double
    let power: RecordingPowerLifetime
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
    private var outputMonitorTask: Task<Void, Never>?
    private var startingCancelled = false
    private var startingFailure: String?
    private var awaitingFirstBuffer = false

    private var checkingSystemPermission = false
    private var permissionAnswer: Result<Bool, SystemAudioPermissionError>?
    private var permissionRequestTask: Task<Void, Never>?
    public private(set) var systemAudioPermissionResult: SystemAudioPermissionResult?
    private var pendingPermissionID: UUID?
    private(set) public var activeSessionID: UUID?
    private(set) public var timeline: ProcessingTimeline?
    private var tap: (any SystemAudioTapProviding)?
    private var captureSource: CaptureSource = .microphone
    private var sink: TimestampedMonoSink?
    private let tapFactory: @MainActor () throws -> any SystemAudioTapProviding
    private let systemAudioPermission: any SystemAudioPermissionProviding
    private let outputProcesses: any SystemAudioOutputProcessProviding
    private let micInputVolumeFactory: @MainActor () -> any MicInputVolumeControlling
    private var micInputVolumeConfiguration: MicInputVolumeConfiguration?
    private var micInputVolume: MicInputVolumeController?
    private var micMeterTask: Task<Void, Never>?

    public var isRecording: Bool { session != nil || tap != nil }

    public convenience init(paths: AppPaths) {
        self.init(paths: paths, bufferFrameCount: 16_384, micInputVolumeFactory: {
            CoreAudioMicInputVolume(hal: CoreAudioMicInputVolumeHAL(),
                                    acknowledgementTimeout: AudioCaptureEngine.micAcknowledgementTimeout)
        })
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
        tapFactory: @escaping @MainActor () throws -> any SystemAudioTapProviding = { try SystemAudioTap() },
        systemAudioPermission: any SystemAudioPermissionProviding = TCCSystemAudioPermission(),
        outputProcesses: any SystemAudioOutputProcessProviding = CoreAudioOutputProcesses(),
        micInputVolumeFactory: @escaping @MainActor () -> any MicInputVolumeControlling
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
        self.systemAudioPermission = systemAudioPermission
        self.outputProcesses = outputProcesses
        self.micInputVolumeFactory = micInputVolumeFactory
    }

    /// Required before every microphone recording; consumed by that recording's start.
    /// Touches no device: volume probing starts only after the first microphone buffer.
    public func configureMicInputVolume(
        automaticAdjustmentEnabled: Bool,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void
    ) {
        precondition(!isRecording && !checkingSystemPermission,
                     "Microphone input volume is configured only while idle")
        micInputVolumeConfiguration = MicInputVolumeConfiguration(
            automaticAdjustmentEnabled: automaticAdjustmentEnabled, onStatus: onStatus
        )
    }

    public func consumeMicSpeechLevels(_ windows: [MicLevelWindow], sessionID: UUID) {
        guard activeSessionID == sessionID, let micInputVolume,
              micInputVolume.sessionID == sessionID else { return }
        micInputVolume.consumeSpeech(windows)
    }

    public func micSpeechMonitoringUnavailable(sessionID: UUID) {
        guard activeSessionID == sessionID, let micInputVolume,
              micInputVolume.sessionID == sessionID else { return }
        micInputVolume.speechMonitoringUnavailable()
    }


    public func start(
        sessionID: UUID,
        source: CaptureSource,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onPermissionWaiting: @escaping @MainActor @Sendable () -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws {
        guard !isRecording, !checkingSystemPermission else { throw AudioCaptureEngineError.alreadyRecording }
        systemAudioPermissionResult = nil
        startingCancelled = false
        if source == .systemAudio {
            checkingSystemPermission = true
            defer { checkingSystemPermission = false }
            switch try await systemAudioPermission.preflight() {
            case .denied, .notDetermined:
                if startingCancelled || Task.isCancelled { throw AudioCaptureEngineError.cancelled }
                onPermissionWaiting()
                permissionAnswer = nil
                let requestID = UUID()
                pendingPermissionID = requestID
                permissionRequestTask = Task { [weak self, systemAudioPermission] in
                    let answer: Result<Bool, SystemAudioPermissionError>
                    do throws(SystemAudioPermissionError) {
                        answer = .success(try await systemAudioPermission.request())
                    } catch {
                        answer = .failure(error)
                    }
                    guard let self, self.pendingPermissionID == requestID else { return }
                    self.permissionAnswer = answer
                }
                while permissionAnswer == nil {
                    if startingCancelled || Task.isCancelled {
                        pendingPermissionID = nil
                        permissionRequestTask?.cancel()
                        permissionRequestTask = nil
                        throw AudioCaptureEngineError.cancelled
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                pendingPermissionID = nil
                permissionRequestTask = nil
                guard try permissionAnswer!.get() else { throw SystemAudioTapError.permissionDenied }
                systemAudioPermissionResult = .grantedNow
            case .authorized:
                systemAudioPermissionResult = .authorized
            }
            if startingCancelled || Task.isCancelled { throw AudioCaptureEngineError.cancelled }
        }
        let device: AVCaptureDevice?
        let input: AVCaptureDeviceInput?
        var micConfiguration: MicInputVolumeConfiguration?
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
            guard let configuration = micInputVolumeConfiguration else {
                throw AudioCaptureEngineError.micInputVolumeNotConfigured
            }
            micInputVolumeConfiguration = nil
            micConfiguration = configuration
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
        let run: PreparedRun
        do {
            run = try prepareRun(
                sessionID: sessionID, sampleRate: sampleRate, inputChannels: inputChannels,
                input: input, onFailure: onFailure, onWarning: onWarning
            )
            if startingCancelled || Task.isCancelled { throw AudioCaptureEngineError.cancelled }
        } catch {
            throw SystemAudioTapError.releasing(tapBackend, after: error)
        }
        let (ring, drain, sink) = (run.ring, run.drain, run.sink)
        let (captureSession, audioOutput) = (run.captureSession, run.audioOutput)
        awaitingFirstBuffer = true
        startingFailure = nil
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
            throw SystemAudioTapError.releasing(tapBackend, after: error)
        }
        let task = Task.detached(priority: .utility) { () -> String? in
            while !Task.isCancelled {
                do {
                    _ = try await drain.drainAvailable()
                } catch {
                    let cause = error.localizedDescription
                    await reportFailure(AudioCaptureEngineError.writerFailure(cause).localizedDescription)
                    return cause
                }
                do { try await Task.sleep(for: .milliseconds(20)) }
                catch { return nil }
            }
            return nil
        }
        installCapture(
            session: captureSession, output: audioOutput, receiver: run.receiver,
            callbackQueue: run.callbackQueue, tap: tapBackend, sink: sink,
            ring: ring, drain: drain, drainTask: task, sessionID: sessionID,
            timeline: ProcessingTimeline(
                sampleRate: CanonicalAudio.sampleRate, channelCount: CanonicalAudio.channelCount, sampleFormat: CanonicalAudio.sampleFormat
            )
        )
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
                    source: source, clock: clock, diskSpace: diskSpace, directory: paths.sessionsRoot,
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
                if let device, let micConfiguration {
                    beginMicInputVolume(
                        captureDeviceUID: device.uniqueID, sessionID: sessionID,
                        automaticAdjustmentEnabled: micConfiguration.automaticAdjustmentEnabled,
                        onStatus: micConfiguration.onStatus
                    )
                }
                if source == .systemAudio {
                    let outputMonitor = SystemAudioOutputMonitor(
                        provider: outputProcesses, captureStartMillis: Int64(startedAt * 1_000)
                    )
                    outputMonitorTask = Task {
                        while !Task.isCancelled, self.activeSessionID == sessionID {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                            let warned = await outputMonitor.poll(
                                nowMillis: Int64(clock.now() * 1_000),
                                everNonZero: sink.everNonZero.load(ordering: .acquiring)
                            )
                            guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                            if warned && !sink.everNonZero.load(ordering: .acquiring) {
                                onWarning("システム音声が届いていません。システム設定の「プライバシーとセキュリティ」で本アプリのシステムオーディオ録音が許可されているか確認してください")
                            }
                        }
                    }
                }
                return
            case .waiting:
                try? await Task.sleep(for: .milliseconds(50))
            case .cancelled, .failed, .timedOut:
                awaitingFirstBuffer = false
                let startupError: AudioCaptureEngineError = switch state {
                case .cancelled: .cancelled
                case .failed(let message): .captureFailure(message)
                case .timedOut: source == .systemAudio ? .noSystemAudioCaptured : .noAudioCaptured
                default: preconditionFailure("Unexpected startup state")
                }
                do {
                    _ = try await stop()
                } catch SystemAudioTapError.releaseFailed(let operations, _) {
                    throw SystemAudioTapError.releaseFailed(
                        operations: operations, after: startupError.localizedDescription
                    )
                } catch {
                    // Startup ended before audio was confirmed; the startup outcome is the reported
                    // error, and AppState decides from the durable files whether to keep the session.
                }
                throw startupError
            }
        }
    }

    private struct PreparedRun {
        let ring: AudioBlockRing
        let drain: AudioCaptureDrain
        let sink: TimestampedMonoSink
        let captureSession: AVCaptureSession?
        let audioOutput: AVCaptureAudioDataOutput?
        let receiver: AudioCaptureReceiver?
        let callbackQueue: DispatchQueue?
    }

    /// Creates the durable writer, ring and (for a microphone) the unstarted capture session.
    private func prepareRun(
        sessionID: UUID, sampleRate: Double, inputChannels: Int, input: AVCaptureDeviceInput?,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void
    ) throws -> PreparedRun {
        guard sampleRate > 0, inputChannels > 0 else {
            throw AudioCaptureEngineError.invalidInputFormat
        }
        try CaptureDiskPolicy.checkStart(
            diskSpace: diskSpace, directory: paths.sessionsRoot
        )
        let sessionURL = try SessionDirectoryLocator(fileManager: .default)
            .resolve(sessionsRoot: paths.sessionsRoot, sessionID: sessionID)
        let processingDirectory = SessionLayout(sessionURL: sessionURL).processingDirectory
        let writer = try DurableAudioWriter(
            directory: processingDirectory, chunkDurationSeconds: chunkDurationSeconds, sessionURL: sessionURL
        )
        let slotSamples = min(bufferFrameCount, 512)
        let ring = AudioBlockRing(
            capacity: max(ringCapacity, AudioBlockRing.capacityForDuration(
                sampleRate: sampleRate, blockFrameCapacity: slotSamples
            )),
            blockFrameCapacity: slotSamples, sampleRate: sampleRate
        )
        let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: sampleRate))
        let sink = TimestampedMonoSink(
            ring: ring, frameCapacity: bufferFrameCount, clock: clock,
            meter: input == nil ? nil : RawInputMeter(channelCount: inputChannels, sampleRate: sampleRate)
        )
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
        return PreparedRun(
            ring: ring, drain: drain, sink: sink, captureSession: captureSession,
            audioOutput: audioOutput, receiver: receiver, callbackQueue: callbackQueue
        )
    }

    /// Installs an already prepared run; the session is started by start().
    /// Tests can supply an unstarted, input-free session to exercise teardown
    /// and durable checkpoint paths without accessing a microphone.
    func installCapture(
        session: AVCaptureSession?, output: AVCaptureAudioDataOutput?,
        receiver: AudioCaptureReceiver?, callbackQueue: DispatchQueue?,
        tap: (any SystemAudioTapProviding)?, sink: TimestampedMonoSink,
        ring: AudioBlockRing, drain: AudioCaptureDrain,
        drainTask: Task<String?, Never>?, sessionID: UUID,
        timeline: ProcessingTimeline
    ) {
        self.session = session
        self.output = output
        self.receiver = receiver
        self.callbackQueue = callbackQueue
        self.tap = tap
        self.sink = sink
        self.ring = ring
        self.drain = drain
        self.drainTask = drainTask
        captureSource = tap == nil ? .microphone : .systemAudio
        overflowAtStart = ring.overflowCount
        activeSessionID = sessionID
        self.timeline = timeline
    }

    /// Starts volume ownership for a ready microphone run. The first valid buffer has arrived,
    /// so the sink's current end frame anchors capture time to the monotonic clock.
    func beginMicInputVolume(
        captureDeviceUID: String, sessionID: UUID, automaticAdjustmentEnabled: Bool,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void
    ) {
        guard captureSource == .microphone, activeSessionID == sessionID,
              let sink, let meter = sink.meter, micInputVolume == nil else {
            preconditionFailure("Microphone input volume requires the active microphone run")
        }
        let clock = clock
        let origin = clock.now() - Double(sink.lastEndFrame) / meter.sampleRate
        let controller = MicInputVolumeController(
            sessionID: sessionID,
            volume: automaticAdjustmentEnabled ? micInputVolumeFactory() : nil,
            pendingWriteTimeout: Self.micPendingWriteTimeout,
            now: { clock.now() - origin },
            onStatus: { [weak self] id, status in
                guard self?.activeSessionID == id else { return }
                onStatus(id, status)
            },
            onEffectiveChange: { meter.requestReset() }
        )
        micInputVolume = controller
        controller.bind(captureDeviceUID: captureDeviceUID)
        micMeterTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.micMeterPollInterval) } catch { return }
                guard let self, self.micInputVolume === controller else { return }
                self.pollMicMeter()
            }
        }
    }

    func pollMicMeter() {
        guard let micInputVolume, let meter = sink?.meter else { return }
        let rate = meter.sampleRate
        micInputVolume.consumeRaw(meter.takeWindows().map { window in
            MicLevelWindow(
                startSeconds: Double(window.startFrame) / rate,
                endSeconds: Double(window.startFrame + Int64(window.frameCount)) / rate,
                speechSeconds: 0, speechMeanSquare: nil, speechPeak: 0,
                inputPeak: window.peak, clippedFraction: window.clippedFraction
            )
        })
    }

    public func cancelStarting() {
        startingCancelled = true
    }

    /// Termination cannot await a final partial chunk; previously committed chunks stay recoverable.
    public func terminate() {
        micMeterTask?.cancel()
        micMeterTask = nil
        micInputVolume?.terminate()
        micInputVolume = nil
        healthTask?.cancel()
        drainTask?.cancel()
        output?.setSampleBufferDelegate(nil, queue: nil)
        outputMonitorTask?.cancel()
        outputMonitorTask = nil
        session?.stopRunning()
        // The process is exiting and has no surface left to show a refused release on.
        if let operations = releaseTap() {
            FileHandle.standardError.write(Data((SystemAudioTapError.releaseFailed(
                operations: operations, after: nil
            ).localizedDescription + "\n").utf8))
        }
        tap = nil
        failureObservers.stop()
        power.end()
    }

    /// Returns the operations Core Audio refused, if any.
    private func releaseTap() -> [String]? {
        guard let tap else { return nil }
        do {
            try tap.stop()
            return nil
        } catch SystemAudioTapError.releaseFailed(let operations, _) {
            return operations
        } catch {
            preconditionFailure("SystemAudioTapProviding.stop throws only releaseFailed")
        }
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
        let releaseFailure = releaseTap()
        ring.finish(tailFrame: sink.lastEndFrame)
        healthTask?.cancel()
        healthTask = nil
        outputMonitorTask?.cancel()
        outputMonitorTask = nil
        failureObservers.stop()
        micMeterTask?.cancel()
        micMeterTask = nil
        if let micInputVolume {
            await micInputVolume.stop()
            self.micInputVolume = nil
        }
        defer {
            self.session = nil
            self.output = nil
            self.receiver = nil
            self.callbackQueue = nil
            self.tap = nil
            self.captureSource = .microphone
            self.sink = nil
            self.ring = nil
            self.drain = nil
            self.drainTask = nil
            self.activeSessionID = nil
            self.power.end()
            self.sleepAssertionHeld = false
        }
        do {
            return try await finishRun(
                ring: ring, drain: drain, sink: sink,
                systemAudioReleaseFailure: releaseFailure.map {
                    SystemAudioTapError.releaseFailed(operations: $0, after: nil).localizedDescription
                }
            )
        } catch {
            guard let releaseFailure else { throw error }
            throw SystemAudioTapError.releaseFailed(operations: releaseFailure, after: error.localizedDescription)
        }
    }

    /// A storage failure keeps the healthy durable prefix: the flushed checkpoint when the final
    /// flush succeeds, otherwise the chunks the writer had already published.
    private func finishRun(
        ring: AudioBlockRing, drain: AudioCaptureDrain, sink: TimestampedMonoSink,
        systemAudioReleaseFailure: String?
    ) async throws -> AudioCaptureStopResult {
        var writerFailureCause: String?
        if let drainTask {
            drainTask.cancel()
            writerFailureCause = await drainTask.value
        }
        let checkpoint: AudioCheckpoint
        do {
            checkpoint = try await drain.finish()
        } catch {
            writerFailureCause = writerFailureCause ?? error.localizedDescription
            checkpoint = await drain.durableCheckpoint()
        }
        let gaps = await drain.gapStatistics()
        guard try checkpoint.info.hasCapturedAudio else {
            if let writerFailureCause {
                throw AudioCaptureEngineError.writerFailure(writerFailureCause)
            }
            if sink.invalidBufferCount.load(ordering: .relaxed) > 0 {
                throw AudioCaptureEngineError.invalidInputFormat
            }
            throw captureSource == .systemAudio
                ? AudioCaptureEngineError.noSystemAudioCaptured
                : AudioCaptureEngineError.noAudioCaptured
        }
        return AudioCaptureStopResult(
            checkpoint: checkpoint,
            didOverflow: ring.overflowCount > overflowAtStart
                || ring.dropoutCount > 0
                || sink.invalidBufferCount.load(ordering: .relaxed) > 0,
            dropoutCount: ring.dropoutCount,
            gapCount: gaps.count,
            totalGapFrames: gaps.frames,
            sleepAssertionHeld: sleepAssertionHeld,
            writerFailure: writerFailureCause.map {
                AudioCaptureEngineError.writerFailure($0).localizedDescription
            },
            systemAudioReleaseFailure: systemAudioReleaseFailure
        )
    }
}
