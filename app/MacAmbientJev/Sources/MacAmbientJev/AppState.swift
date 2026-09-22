import AppKit
import AVFoundation
import Combine
import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum RecordingPhase: Equatable {
        case idle
        case requestingPermission
        case starting
        case recording
        case stopping
        case importing
    }

    enum StatusTone: Equatable {
        case neutral
        case recording
        case warning
        case error
    }

    private enum PendingProcessing {
        case imported(sessionID: UUID, originalURL: URL)
        case timeline(sessionID: UUID, checkpoint: AudioCheckpoint)
        case finishLive(sessionID: UUID, checkpoint: AudioCheckpoint)
        case resumeASR(
            sessionID: UUID,
            checkpoint: AudioCheckpoint,
            plan: ASRRecoveryPlan
        )
        case selectCompletedASR(
            sessionID: UUID,
            checkpoint: AudioCheckpoint,
            plan: ASRRecoveryPlan
        )
        case diarization(
            sessionID: UUID,
            checkpoint: AudioCheckpoint,
            plan: ASRRecoveryPlan
        )
    }

    private struct LiveASRBatch {
        let segments: [SegmentReference]
        let checkpoint: AudioCheckpoint
    }

    @Published private(set) var statusText = UserFacingStatus.idle.text
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var recordingPhase: RecordingPhase = .idle
    @Published private(set) var processingState: ProcessingState = .idle
    @Published private(set) var processingStatusText: String?

    let transcriptViewModel = LiveTranscriptViewModel()
    let jevUsageCounter: JevUsageCounter

    private let paths: AppPaths
    private let captureEngine: AudioCaptureEngine
    private let sessionProcessor: NativeSessionProcessor
    private let diskMonitor = DiskSpaceMonitor(
        warningThresholdBytes: 2_000_000_000,
        criticalThresholdBytes: 1_000_000_000
    )

    private var recordingSessionID: UUID?
    private var pendingProcessing: [PendingProcessing] = []
    private var processingTask: Task<Void, Never>?

    private var liveVADSession: LiveVADSession?
    private var liveVADTask: Task<Void, Never>?
    private var liveVADSegmentCount = 0
    private var liveVADFailureText: String?

    private var liveASRQueues: [UUID: [LiveASRBatch]] = [:]
    private var liveASRTasks: [UUID: Task<Void, Never>] = [:]
    private var liveASRFailures: [UUID: String] = [:]

    init(fileManager: FileManager = .default) {
        let paths = AppPaths.systemDefault(fileManager: fileManager)

        let jevUsageCounter = JevUsageCounter()

        self.paths = paths
        self.jevUsageCounter = jevUsageCounter
        self.captureEngine = AudioCaptureEngine(paths: paths)
        self.sessionProcessor = NativeSessionProcessor(
            paths: paths,
            allowExternalJev: true,
            jevUsageCounter: jevUsageCounter
        )

        Task { [weak self] in
            await self?.recoverPendingSessions()
        }
    }

    var isRecording: Bool {
        recordingPhase == .recording
    }

    var isBusy: Bool {
        switch recordingPhase {
        case .requestingPermission, .starting, .stopping, .importing:
            true
        case .idle, .recording:
            false
        }
    }

    var isProcessing: Bool {
        switch processingState {
        case .running, .backlogged:
            true
        case .idle, .complete, .partialFailure:
            false
        }
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func importAudioFile() async {
        guard recordingPhase == .idle else { return }

        let panel = NSOpenPanel()
        panel.title = "文字起こしする音声ファイルを選択"
        panel.prompt = "読み込む"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        recordingPhase = .importing
        setCaptureStatus(UserFacingStatus.importingAudio.text, tone: .neutral)

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sessionID = UUID()
        let sessionURL = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        do {
            try prepareSession(
                sessionID: sessionID,
                sessionURL: sessionURL,
                sourceKind: .importedFile,
                originalFilename: sourceURL.lastPathComponent
            )
            let imported = try AudioImporter().importFile(
                sourceURL,
                into: sessionURL
            )

            recordingPhase = .idle
            setCaptureStatus(
                "「\(sourceURL.lastPathComponent)」を読み込みました",
                tone: .neutral
            )
            enqueueProcessing(
                .imported(
                    sessionID: sessionID,
                    originalURL: imported.originalURL
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: sessionURL)
            recordingPhase = .idle
            setCaptureStatus(
                "音声ファイルを読み込めませんでした: \(error.localizedDescription)",
                tone: .error
            )
        }
    }

    func startRecording() async {
        guard recordingPhase == .idle else { return }

        recordingPhase = .requestingPermission
        setCaptureStatus(UserFacingStatus.checkingMicrophone.text, tone: .neutral)

        guard await requestMicrophoneAccessIfNeeded() else {
            recordingPhase = .idle
            setCaptureStatus(
                "マイクへのアクセスが許可されていません。システム設定の「プライバシーとセキュリティ」→「マイク」で許可してください。",
                tone: .error
            )
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: paths.root,
                withIntermediateDirectories: true
            )

            switch try currentDiskSpaceLevel() {
            case .critical:
                recordingPhase = .idle
                setCaptureStatus(
                    "空き容量が1 GB未満のため、新しい録音を開始できません。",
                    tone: .error
                )
                return
            case .warning:
                setCaptureStatus(
                    "空き容量が2 GB未満です。長時間録音では容量不足に注意してください。",
                    tone: .warning
                )
            case .normal:
                break
            }
        } catch {
            setCaptureStatus(
                "空き容量を確認できませんでした。録音を開始します。",
                tone: .warning
            )
        }

        recordingPhase = .starting
        if statusTone != .warning {
            setCaptureStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        }

        let sessionID = UUID()
        let sessionURL = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        do {
            try prepareSession(
                sessionID: sessionID,
                sessionURL: sessionURL,
                sourceKind: .live,
                originalFilename: nil
            )
            try await captureEngine.start(sessionID: sessionID)
            recordingSessionID = sessionID
            recordingPhase = .recording
            setCaptureStatus("録音中", tone: .recording)

            do {
                try await startLiveVAD(sessionID: sessionID)
            } catch {
                liveVADFailureText = error.localizedDescription
                processingStatusText =
                    "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)"
            }
        } catch {
            try? FileManager.default.removeItem(at: sessionURL)
            recordingSessionID = nil
            recordingPhase = .idle
            setCaptureStatus(error.localizedDescription, tone: .error)
        }
    }

    func stopRecording() async {
        guard recordingPhase == .recording,
              let sessionID = recordingSessionID else {
            return
        }

        recordingPhase = .stopping
        setCaptureStatus("録音を保存しています", tone: .neutral)

        do {
            await stopLiveVADPolling()

            let result = try await captureEngine.stop()
            let checkpoint = result.checkpoint

            if let liveVADSession {
                do {
                    let progress = try await liveVADSession.finish(
                        checkpoint: checkpoint
                    )
                    liveVADSegmentCount = progress.totalSegmentCount
                    await enqueueLiveASR(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint
                    )
                } catch {
                    liveVADFailureText = error.localizedDescription
                }
            }
            liveVADSession = nil

            let durationSeconds = checkpoint.sampleRate > 0
                ? Double(checkpoint.committedFrames) / checkpoint.sampleRate
                : 0

            recordingSessionID = nil
            recordingPhase = .idle

            if result.didOverflow {
                setCaptureStatus(
                    "録音は保存しましたが、一部の音声が欠落した可能性があります。",
                    tone: .warning
                )
            } else if let liveVADFailureText {
                setCaptureStatus(
                    "録音を保存しました。発話検出を後で再実行します: \(liveVADFailureText)",
                    tone: .warning
                )
            } else {
                let segmentSuffix = liveVADSegmentCount > 0
                    ? "・発話 \(liveVADSegmentCount)区間"
                    : ""
                setCaptureStatus(
                    "録音を保存しました（\(Self.formatDuration(durationSeconds))\(segmentSuffix)）",
                    tone: .neutral
                )
            }

            if liveVADFailureText == nil {
                enqueueProcessing(
                    .finishLive(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                )
            } else {
                await sessionProcessor.cancelLiveTranscription(
                    sessionID: sessionID
                )
                cleanupLiveASRState(sessionID: sessionID)
                enqueueProcessing(
                    .timeline(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                )
            }

            liveVADFailureText = nil
            liveVADSegmentCount = 0
        } catch {
            await stopLiveVADPolling()
            liveVADSession = nil
            liveVADFailureText = nil
            liveVADSegmentCount = 0
            await sessionProcessor.cancelLiveTranscription(
                sessionID: sessionID
            )
            cleanupLiveASRState(sessionID: sessionID)
            recordingSessionID = nil
            recordingPhase = .idle
            setCaptureStatus(error.localizedDescription, tone: .error)
        }
    }

    private func startLiveVAD(sessionID: UUID) async throws {
        let checkpoint = try await captureEngine.committedCheckpoint()
        let directory = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)

        liveVADFailureText = nil
        liveVADSegmentCount = 0
        let vadSession = try await LiveVADSession.make(
            processingDirectory: directory,
            initialCheckpoint: checkpoint
        )
        liveVADSession = vadSession

        liveASRQueues[sessionID] = []
        liveASRFailures[sessionID] = nil
        do {
            _ = try await sessionProcessor.startLiveTranscription(
                sessionID: sessionID,
                segmentationRunID: vadSession.segmentationRunID,
                sampleRate: checkpoint.sampleRate
            )
        } catch {
            liveASRFailures[sessionID] = error.localizedDescription
            processingStatusText =
                "録音は継続しています。ライブ文字起こしを開始できませんでした: \(error.localizedDescription)"
        }

        liveVADTask?.cancel()
        liveVADTask = Task { [weak self] in
            await self?.runLiveVADLoop(sessionID: sessionID)
        }
    }

    private func runLiveVADLoop(sessionID: UUID) async {
        while !Task.isCancelled,
              recordingSessionID == sessionID,
              recordingPhase == .recording {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  recordingSessionID == sessionID,
                  let liveVADSession else {
                return
            }

            do {
                let checkpoint = try await captureEngine.committedCheckpoint()
                let progress = try await liveVADSession.processAvailable(
                    checkpoint: checkpoint
                )
                liveVADSegmentCount = progress.totalSegmentCount

                if !progress.emittedSegments.isEmpty {
                    await enqueueLiveASR(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint
                    )
                    processingStatusText =
                        "録音中に発話を検出しています（\(progress.totalSegmentCount)区間）"
                }
            } catch {
                liveVADFailureText = error.localizedDescription
                processingStatusText =
                    "録音は継続しています。発話検出を停止しました: \(error.localizedDescription)"
                return
            }
        }
    }

    private func stopLiveVADPolling() async {
        guard let liveVADTask else { return }
        liveVADTask.cancel()
        _ = await liveVADTask.value
        self.liveVADTask = nil
    }

    private func enqueueLiveASR(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint
    ) async {
        guard !segments.isEmpty,
              liveASRFailures[sessionID] == nil else {
            return
        }

        do {
            _ = try await sessionProcessor.registerLiveSegments(
                sessionID: sessionID,
                segments: segments
            )
        } catch {
            liveASRFailures[sessionID] = error.localizedDescription
            processingStatusText =
                "録音は継続しています。発話区間を保存できませんでした: \(error.localizedDescription)"
            return
        }

        liveASRQueues[sessionID, default: []].append(
            LiveASRBatch(
                segments: segments,
                checkpoint: checkpoint
            )
        )

        guard liveASRTasks[sessionID] == nil else { return }
        liveASRTasks[sessionID] = Task { [weak self] in
            await self?.drainLiveASRQueue(sessionID: sessionID)
        }
    }

    private func drainLiveASRQueue(sessionID: UUID) async {
        while liveASRFailures[sessionID] == nil,
              var queue = liveASRQueues[sessionID],
              !queue.isEmpty {
            let batch = queue.removeFirst()
            liveASRQueues[sessionID] = queue

            let statusHandler: NativeSessionProcessor.StatusHandler = {
                [weak self] text in
                await MainActor.run {
                    guard let self else { return }
                    self.processingStatusText = text
                    self.transcriptViewModel.setStatus(text)
                }
            }
            let updateHandler: NativeSessionProcessor.UpdateHandler = {
                [weak self] segments, state in
                await MainActor.run {
                    guard let self else { return }
                    self.processingState = state
                    self.transcriptViewModel.update(segments: segments)
                }
            }

            do {
                _ = try await sessionProcessor.processLiveSegments(
                    sessionID: sessionID,
                    segments: batch.segments,
                    checkpoint: batch.checkpoint,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            } catch {
                liveASRFailures[sessionID] = error.localizedDescription
                liveASRQueues[sessionID] = []
                processingStatusText =
                    "録音は継続しています。ライブ文字起こしを停止しました: \(error.localizedDescription)"
            }
        }

        liveASRTasks[sessionID] = nil

        if liveASRFailures[sessionID] == nil,
           let queue = liveASRQueues[sessionID],
           !queue.isEmpty {
            liveASRTasks[sessionID] = Task { [weak self] in
                await self?.drainLiveASRQueue(sessionID: sessionID)
            }
        }
    }

    private func waitForLiveASRDrain(sessionID: UUID) async {
        while let task = liveASRTasks[sessionID] {
            _ = await task.value
        }
    }

    private func cleanupLiveASRState(sessionID: UUID) {
        liveASRQueues[sessionID] = nil
        liveASRTasks[sessionID] = nil
        liveASRFailures[sessionID] = nil
    }

    private func enqueueProcessing(_ request: PendingProcessing) {
        pendingProcessing.append(request)

        if processingTask != nil {
            processingState = .backlogged
            processingStatusText = "文字起こし処理が待機中です"
            transcriptViewModel.setStatus("文字起こし処理が待機中です")
            return
        }

        processingTask = Task { [weak self] in
            await self?.drainProcessingQueue()
        }
    }

    private func drainProcessingQueue() async {
        while !pendingProcessing.isEmpty {
            let request = pendingProcessing.removeFirst()
            processingState = .running

            let statusHandler: NativeSessionProcessor.StatusHandler = { [weak self] text in
                await MainActor.run {
                    guard let self else { return }
                    self.processingStatusText = text
                    self.transcriptViewModel.setStatus(text)
                }
            }

            let updateHandler: NativeSessionProcessor.UpdateHandler = { [weak self] segments, state in
                await MainActor.run {
                    guard let self else { return }
                    self.processingState = state
                    self.transcriptViewModel.update(segments: segments)
                }
            }

            switch request {
            case .imported(let sessionID, let originalURL):
                await sessionProcessor.processImportedSession(
                    sessionID: sessionID,
                    originalURL: originalURL,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .timeline(let sessionID, let checkpoint):
                await sessionProcessor.processTimelineSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .finishLive(let sessionID, let checkpoint):
                await waitForLiveASRDrain(sessionID: sessionID)

                if let failure = liveASRFailures[sessionID] {
                    await sessionProcessor.cancelLiveTranscription(
                        sessionID: sessionID
                    )
                    cleanupLiveASRState(sessionID: sessionID)
                    processingStatusText =
                        "ライブ文字起こしを再処理します: \(failure)"
                    pendingProcessing.insert(
                        .timeline(
                            sessionID: sessionID,
                            checkpoint: checkpoint
                        ),
                        at: 0
                    )
                } else {
                    let result = await sessionProcessor.finishLiveTranscription(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                    cleanupLiveASRState(sessionID: sessionID)

                    if case .fallbackRequired(let reason) = result {
                        processingStatusText =
                            "録音後に文字起こしを再実行します: \(reason)"
                        pendingProcessing.insert(
                            .timeline(
                                sessionID: sessionID,
                                checkpoint: checkpoint
                            ),
                            at: 0
                        )
                    }
                }
            case .resumeASR(let sessionID, let checkpoint, let plan):
                await sessionProcessor.resumePendingASRSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .selectCompletedASR(let sessionID, let checkpoint, let plan):
                await sessionProcessor.selectCompletedASRSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            case .diarization(let sessionID, let checkpoint, let plan):
                await sessionProcessor.runRecoveredDiarizationSession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    plan: plan,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
            }

            if !pendingProcessing.isEmpty {
                processingState = .backlogged
                processingStatusText = "次の文字起こし処理を開始します"
                transcriptViewModel.setStatus("次の文字起こし処理を開始します")
            }
        }

        if processingState == .running || processingState == .backlogged {
            processingState = .complete
        }
        processingTask = nil
    }

    private func recoverPendingSessions() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions()

            guard !candidates.isEmpty else { return }

            processingStatusText = "未完了の文字起こしを復旧しています（\(candidates.count)件）"
            transcriptViewModel.setStatus(
                "未完了の文字起こしを復旧しています"
            )

            for candidate in candidates {
                let sessionID = candidate.manifest.sessionID

                switch (candidate.action, candidate.source) {
                case (.resumeASR(let plan), .processingTimeline(let checkpoint)):
                    enqueueProcessing(
                        .resumeASR(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.selectCompletedASR(let plan), .processingTimeline(let checkpoint)):
                    enqueueProcessing(
                        .selectCompletedASR(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.runDiarization(let plan), .processingTimeline(let checkpoint)):
                    enqueueProcessing(
                        .diarization(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            plan: plan
                        )
                    )

                case (.reprocess, .processingTimeline(let checkpoint)):
                    enqueueProcessing(
                        .timeline(
                            sessionID: sessionID,
                            checkpoint: checkpoint
                        )
                    )

                case (_, .importedOriginal(let originalURL)):
                    // Old sessions without a durable checkpoint cannot safely
                    // resume frame-addressed ASR. Rebuild the timeline
                    // idempotently from the preserved original instead.
                    enqueueProcessing(
                        .imported(
                            sessionID: sessionID,
                            originalURL: originalURL
                        )
                    )
                }
            }
        } catch {
            processingState = .partialFailure(error.localizedDescription)
            processingStatusText =
                "未完了セッションを復旧できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "未完了セッションを復旧できませんでした"
            )
        }
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func currentDiskSpaceLevel() throws -> DiskSpaceLevel {
        let values = try paths.applicationSupportURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )

        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            return .normal
        }

        return diskMonitor.level(forAvailableBytes: bytes)
    }

    private func prepareSession(
        sessionID: UUID,
        sessionURL: URL,
        sourceKind: SessionSourceKind,
        originalFilename: String?
    ) throws {
        let createdURL = try SessionBootstrapper().createSession(
            paths: paths,
            sessionID: sessionID,
            sourceKind: sourceKind,
            originalFilename: originalFilename
        )
        precondition(
            createdURL.standardizedFileURL == sessionURL.standardizedFileURL
        )
    }

    private func setCaptureStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }

        return String(
            format: "%02d:%02d",
            minutes,
            remainingSeconds
        )
    }
}
