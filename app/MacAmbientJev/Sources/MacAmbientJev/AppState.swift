import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime
import UniformTypeIdentifiers

extension AudioCheckpoint {
    /// Replacement silence is durable, but is not captured microphone input.
    var hasCapturedAudio: Bool {
        guard committedFrames > 0 else { return false }
        var coveredThrough: Int64 = 0
        for gap in gapEvents {
            if gap.startFrame > coveredThrough { return true }
            guard gap.startFrame >= 0, gap.startFrame < committedFrames,
                  gap.frameCount > 0 else { continue }
            let end = gap.startFrame + min(gap.frameCount, committedFrames - gap.startFrame)
            coveredThrough = max(coveredThrough, end)
            if coveredThrough >= committedFrames { return false }
        }
        return coveredThrough < committedFrames
    }
}

/// Incremental VAD is independent of capture and consumes only durable checkpoints.
protocol LiveVADProcessing: Sendable {
    var segmentationRunID: String { get }
    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
}

extension LiveVADSession: LiveVADProcessing {}

@MainActor
protocol AppCaptureEngine {
    func start(
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws
    func cancelStarting()
    func committedCheckpoint() async throws -> AudioCheckpoint
    func stop() async throws -> AudioCaptureStopResult
    func terminate()
}

extension AudioCaptureEngine: AppCaptureEngine {}

final class TerminationObservation {
    private let token: NSObjectProtocol

    init(onTermination: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in onTermination() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

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

    enum ModelPreparation: Equatable {
        case idle
        case preparing(Double)
        case ready
        case failed(String)

        var statusText: String {
            switch self {
            case .idle: "録音開始時に準備します"
            case .preparing(let progress) where progress < 0.8:
                "音声認識モデルをダウンロード中（\(Int(progress * 100))%）"
            case .preparing(let progress):
                "音声認識モデルを読み込み中（\(Int(progress * 100))%）"
            case .ready: "準備完了"
            case .failed(let message): "準備できませんでした: \(message)"
            }
        }
    }

    enum PendingProcessing {
        case imported(sessionID: UUID, originalURL: URL)
        case timeline(sessionID: UUID, checkpoint: AudioCheckpoint)
        case finishLive(sessionID: UUID, checkpoint: AudioCheckpoint)
        case finalize(sessionID: UUID, source: SavedSessionAudioSource)
        case retryContentPriority(
            sessionID: UUID,
            checkpoint: AudioCheckpoint,
            segmentIDs: [String]
        )
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

        var sessionID: UUID {
            switch self {
            case .imported(let sessionID, _),
                 .timeline(let sessionID, _),
                 .finishLive(let sessionID, _),
                 .finalize(let sessionID, _),
                 .retryContentPriority(let sessionID, _, _),
                 .resumeASR(let sessionID, _, _),
                 .selectCompletedASR(let sessionID, _, _),
                 .diarization(let sessionID, _, _):
                sessionID
            }
        }
    }

    private struct LiveASRBatch {
        let segments: [SegmentReference]
        let checkpoint: AudioCheckpoint
        let enqueuedAt: Date
    }

    @Published private(set) var statusText = UserFacingStatus.idle.text
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var recordingPhase: RecordingPhase = .idle
    @Published private(set) var captureWarningText: String?
    @Published private(set) var isMicrophoneSilent = false
    @Published private(set) var dropoutCount: UInt64 = 0
    @Published private(set) var modelPreparation: ModelPreparation = .idle
    @Published private(set) var processingState: ProcessingState = .idle
    @Published private(set) var processingStatusText: String?
    @Published private(set) var savedSessions: [SavedSessionSummary] = []
    @Published private(set) var selectedSavedSessionID: UUID?

    let transcriptViewModel = LiveTranscriptViewModel()
    let jevUsageCounter: JevUsageCounter

    private let paths: AppPaths
    private let captureEngine: any AppCaptureEngine
    private let sessionProcessor: NativeSessionProcessor
    // Device-rate disk requirements and the in-recording floor are enforced by AudioCaptureEngine.
    private let microphoneAccess: (@MainActor () async -> Bool)?
    private let pausesProcessing: Bool

    private var recordingSessionID: UUID?
    private var displayedSessionID: UUID?
    private var pendingCaptureFailure: (sessionID: UUID, message: String)?
    private(set) var pendingProcessing: [PendingProcessing] = []
    private var currentlyProcessingSessionID: UUID?
    private var finalizationGate = SavedSessionReprocessGate()
    private var processingTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var terminationObserver: TerminationObservation?

    private var liveVADSession: (any LiveVADProcessing)?
    private var liveVADTask: Task<Void, Never>?
    private var liveVADSegmentCount = 0
    private var liveVADFailureText: String?

    private var liveASRQueues: [UUID: [LiveASRBatch]] = [:]
    private var liveASRTasks: [UUID: Task<Void, Never>] = [:]
    private var liveASRFailures: [UUID: String] = [:]

    init(
        fileManager: FileManager = .default,
        paths: AppPaths? = nil,
        captureEngine: (any AppCaptureEngine)? = nil,
        microphoneAccess: (@MainActor () async -> Bool)? = nil,
        pausesProcessing: Bool = false,
        liveVADSession: (any LiveVADProcessing)? = nil
    ) {
        let paths = paths ?? AppPaths.systemDefault(fileManager: fileManager)

        let jevUsageCounter = JevUsageCounter()

        self.paths = paths
        self.jevUsageCounter = jevUsageCounter
        self.captureEngine = captureEngine ?? AudioCaptureEngine(paths: paths)
        self.microphoneAccess = microphoneAccess
        self.pausesProcessing = pausesProcessing
        self.liveVADSession = liveVADSession
        self.sessionProcessor = NativeSessionProcessor(
            paths: paths,
            allowExternalJev: true,
            jevUsageCounter: jevUsageCounter
        )

        terminationObserver = TerminationObservation { [weak self] in
            MainActor.assumeIsolated { self?.terminateCapture() }
        }

        if !pausesProcessing {
            Task { [weak self] in
                await self?.recoverPendingSessions()
            }
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

    var queuedFinalizationSessionIDs: Set<UUID> {
        finalizationGate.sessionIDs
            .union(pendingProcessing.map(\.sessionID))
            .union(currentlyProcessingSessionID.map { [$0] } ?? [])
    }

    func refreshSavedSessions() {
        do {
            savedSessions = try SavedSessionCatalog().list(
                sessionsRoot: paths.sessionsRoot
            )
        } catch {
            processingStatusText = "保存済み録音を読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func selectSavedSession(sessionID: UUID) {
        guard SavedSessionSelectionPolicy.canSelect(
            isRecording: recordingPhase != .idle
        ) else {
            return
        }
        selectedSavedSessionID = sessionID
        displayedSessionID = sessionID
        transcriptViewModel.update(segments: [])
        transcriptViewModel.setStatus("保存済みの文字起こしを読み込んでいます")

        do {
            let sessionURL = paths.sessionsRoot.appending(
                path: sessionID.uuidString,
                directoryHint: .isDirectory
            )
            guard let metadata = try ProcessingMetadataStore(
                sessionURL: sessionURL
            ).load(), let activeRuns = metadata.activeRuns,
                  activeRuns.asr != nil else {
                transcriptViewModel.setStatus("この録音には確定文字起こしがありません")
                return
            }
            guard let audioSource = savedSessions
                .first(where: { $0.sessionID == sessionID })?.audioSource else {
                transcriptViewModel.setStatus("保存済み文字起こしの音声時間情報がありません")
                return
            }
            let sampleRate: Double
            switch audioSource {
            case .processingTimeline(let checkpoint):
                sampleRate = checkpoint.sampleRate
            case .importedOriginal(let originalURL):
                let original = try AVAudioFile(forReading: originalURL)
                sampleRate = original.processingFormat.sampleRate
                guard sampleRate.isFinite, sampleRate > 0 else {
                    transcriptViewModel.setStatus("保存済み文字起こしの音声時間情報がありません")
                    return
                }
            }

            let eventsURL = sessionURL.appending(path: "events.jsonl")
            let lines: [Data]
            if FileManager.default.fileExists(atPath: eventsURL.path) {
                lines = try SessionRecovery.recoverJSONL(
                    Data(contentsOf: eventsURL)
                ).lines
            } else {
                lines = []
            }
            let events = try EventLogTranscriptReader().events(
                lines: lines,
                activeRuns: activeRuns
            )
            let segments = TranscriptMaterializer(
                sampleRate: sampleRate
            ).materialize(events: events, activeRuns: activeRuns)
            transcriptViewModel.update(segments: segments)
            transcriptViewModel.setStatus(
                segments.isEmpty ? "確定文字起こしはありません" : "保存済み文字起こしを表示中"
            )
        } catch {
            transcriptViewModel.setStatus(
                "保存済み文字起こしを読み込めませんでした: \(error.localizedDescription)"
            )
        }
    }

    func reprocess(sessionID: UUID) {
        guard recordingPhase == .idle,
              !finalizationGate.sessionIDs.contains(sessionID),
              currentlyProcessingSessionID != sessionID,
              !pendingProcessing.contains(where: { $0.sessionID == sessionID }),
              let session = savedSessions.first(where: { $0.sessionID == sessionID }),
              session.canReprocess,
              let source = session.audioSource else {
            return
        }
        selectSavedSession(sessionID: sessionID)
        guard finalizationGate.claim(sessionID) else { return }
        enqueueProcessing(.finalize(sessionID: sessionID, source: source))
    }

    func prepareASRModel() {
        guard modelPreparationTask == nil, modelPreparation != .ready else { return }
        modelPreparation = .preparing(0)
        modelPreparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sessionProcessor.prepareASR { [weak self] progress, _ in
                    Task { @MainActor in
                        guard let self,
                              case .preparing(let current) = self.modelPreparation else { return }
                        self.modelPreparation = .preparing(max(current, min(1, progress)))
                    }
                }
                modelPreparation = .ready
            } catch {
                modelPreparation = .failed(error.localizedDescription)
            }
            modelPreparationTask = nil
        }
    }

    func retryDeferredJev() async {
        do {
            let candidates = try SessionRecoveryScanner(
                sessionsRoot: paths.sessionsRoot
            ).pendingSessions()

            var queuedCount = 0
            for candidate in candidates {
                guard case .retryContentPriority(let segmentIDs)
                        = candidate.action,
                      case .processingTimeline(let checkpoint)
                        = candidate.source else {
                    continue
                }

                enqueueProcessing(
                    .retryContentPriority(
                        sessionID: candidate.manifest.sessionID,
                        checkpoint: checkpoint,
                        segmentIDs: segmentIDs
                    )
                )
                queuedCount += 1
            }

            if queuedCount == 0 {
                processingStatusText =
                    "再試行が必要な意味分類はありません"
                transcriptViewModel.setStatus(
                    "再試行が必要な意味分類はありません"
                )
            }
        } catch {
            processingStatusText =
                "保留中の意味分類を確認できませんでした: \(error.localizedDescription)"
            transcriptViewModel.setStatus(
                "保留中の意味分類を確認できませんでした"
            )
        }
    }

    func toggleRecording() async {
        switch recordingPhase {
        case .starting:
            captureEngine.cancelStarting()
            setCaptureStatus("録音の開始を中止しています", tone: .neutral)
        case .recording:
            await stopRecording()
        case .idle:
            await startRecording()
        case .requestingPermission, .stopping, .importing:
            break
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
            showNewSession(sessionID)
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
        captureWarningText = nil
        isMicrophoneSilent = false
        dropoutCount = 0

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
        } catch {
            recordingPhase = .idle
            setCaptureStatus("録音先を作成できませんでした: \(error.localizedDescription)", tone: .error)
            return
        }

        recordingPhase = .starting
        if statusTone != .warning {
            setCaptureStatus(UserFacingStatus.startingRecording.text, tone: .neutral)
        }

        let sessionID = UUID()
        let sessionURL = paths.sessionsRoot
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)

        recordingSessionID = sessionID
        do {
            try prepareSession(
                sessionID: sessionID,
                sessionURL: sessionURL,
                sourceKind: .live,
                originalFilename: nil
            )
            try await captureEngine.start(
                sessionID: sessionID,
                onFailure: { [weak self] message in
                    guard let self else { return }
                    if self.recordingPhase == .starting,
                       self.recordingSessionID == sessionID {
                        self.pendingCaptureFailure = (sessionID, message)
                    } else {
                        self.captureDidFail(sessionID: sessionID, message: message)
                    }
                },
                onWarning: { [weak self] message in
                    guard let self, self.recordingSessionID == sessionID else { return }
                    if let previous = self.captureWarningText {
                        if !previous.contains(message) {
                            self.captureWarningText = previous + " / " + message
                        }
                    } else {
                        self.captureWarningText = message
                    }
                },
                onDropouts: { [weak self] count in
                    guard let self, self.recordingSessionID == sessionID else { return }
                    self.dropoutCount = count
                },
                onSilenceChanged: { [weak self] silent in
                    guard let self, self.recordingSessionID == sessionID else { return }
                    self.isMicrophoneSilent = silent
                }
            )
            markRecordingStarted(sessionID: sessionID)
            if let failure = pendingCaptureFailure, failure.sessionID == sessionID {
                pendingCaptureFailure = nil
                captureDidFail(sessionID: sessionID, message: failure.message)
                return
            }
            showNewSession(sessionID)
            setCaptureStatus("録音中", tone: .recording)
            if !pausesProcessing {
                prepareASRModel()

                do {
                    try await startLiveVAD(sessionID: sessionID)
                } catch {
                    guard isCurrentRecording(sessionID) else { return }
                    liveVADFailureText = error.localizedDescription
                    processingStatusText =
                        "録音は継続しています。発話検出を開始できませんでした: \(error.localizedDescription)"
                }
            }
        } catch {
            pendingCaptureFailure = nil
            captureWarningText = nil
            isMicrophoneSilent = false
            let processing = sessionURL.appending(path: "audio/processing", directoryHint: .isDirectory)
            let keepSession: Bool
            do {
                let checkpoint = try AudioCheckpoint.loadRecovered(from: processing)
                keepSession = checkpoint?.hasCapturedAudio ?? false
            } catch {
                // Damaged durable data must remain available for recovery/diagnosis.
                keepSession = true
            }
            if keepSession {
                refreshSavedSessions()
            } else {
                try? FileManager.default.removeItem(at: sessionURL)
            }
            recordingSessionID = nil
            recordingPhase = .idle
            if case AudioCaptureEngineError.cancelled = error {
                setCaptureStatus("録音の開始を中止しました", tone: .neutral)
            } else {
                setCaptureStatus(error.localizedDescription, tone: .error)
            }
        }
    }

    func markRecordingStarted(sessionID: UUID) {
        recordingSessionID = sessionID
        recordingPhase = .recording
        liveASRQueues[sessionID] = []
        liveASRFailures[sessionID] = nil
    }

    @discardableResult
    func captureDidFail(sessionID: UUID, message: String) -> Task<Void, Never>? {
        guard isCurrentRecording(sessionID) else { return nil }
        recordingPhase = .stopping
        setCaptureStatus(message, tone: .error)
        return Task {
            await finishRecording(sessionID: sessionID, failureMessage: message)
        }
    }

    func stopRecording() async {
        guard recordingPhase == .recording,
              let sessionID = recordingSessionID else {
            return
        }

        recordingPhase = .stopping
        setCaptureStatus("録音を保存しています", tone: .neutral)
        await finishRecording(sessionID: sessionID, failureMessage: nil)
    }

    private func finishRecording(sessionID: UUID, failureMessage: String?) async {
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
            captureWarningText = nil
            isMicrophoneSilent = false
            recordingPhase = .idle

            if failureMessage == nil {
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
            }

            if liveVADFailureText == nil {
                enqueueProcessing(
                    .finishLive(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                )
            } else {
                cleanupLiveASRState(sessionID: sessionID)
                await sessionProcessor.cancelLiveTranscription(
                    sessionID: sessionID
                )
                enqueueProcessing(
                    .timeline(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                )
            }

            liveVADFailureText = nil
            if failureMessage != nil { refreshSavedSessions() }
            liveVADSegmentCount = 0
        } catch {
            await stopLiveVADPolling()
            liveVADSession = nil
            liveVADFailureText = nil
            liveVADSegmentCount = 0
            cleanupLiveASRState(sessionID: sessionID)
            await sessionProcessor.cancelLiveTranscription(
                sessionID: sessionID
            )
            recordingSessionID = nil
            captureWarningText = nil
            isMicrophoneSilent = false
            recordingPhase = .idle
            if failureMessage == nil {
                setCaptureStatus(error.localizedDescription, tone: .error)
            }
            if failureMessage != nil { refreshSavedSessions() }
        }
    }

    private func startLiveVAD(sessionID: UUID) async throws {
        let checkpoint = try await captureEngine.committedCheckpoint()
        guard isCurrentRecording(sessionID) else { return }
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
        guard isCurrentRecording(sessionID) else { return }
        liveVADSession = vadSession

        do {
            _ = try await sessionProcessor.startLiveTranscription(
                sessionID: sessionID,
                segmentationRunID: vadSession.segmentationRunID,
                sampleRate: checkpoint.sampleRate
            )
        } catch {
            liveASRFailures[sessionID] = error.localizedDescription
            if isCurrentRecording(sessionID) {
                processingStatusText =
                    "録音は継続しています。ライブ文字起こしを開始できませんでした: \(error.localizedDescription)"
            }
        }
        guard isCurrentRecording(sessionID) else {
            cleanupLiveASRState(sessionID: sessionID)
            await sessionProcessor.cancelLiveTranscription(sessionID: sessionID)
            return
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
                try await Task.sleep(
                    for: .milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds)
                )
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
                    if processingState != .backlogged {
                        processingStatusText =
                            "録音中に発話を検出しています（\(progress.totalSegmentCount)区間）"
                    }
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
                checkpoint: checkpoint,
                enqueuedAt: Date()
            )
        )

        guard liveASRTasks[sessionID] == nil else { return }
        liveASRTasks[sessionID] = Task { [weak self] in
            await self?.drainLiveASRQueue(sessionID: sessionID)
        }
    }

    func liveUpdateHandler(sessionID: UUID) -> NativeSessionProcessor.UpdateHandler {
        { [weak self] segments, state in
            await MainActor.run {
                guard let self,
                      self.displayedSessionID == sessionID,
                      self.recordingSessionID == sessionID,
                      self.recordingPhase == .recording else { return }
                self.processingState = state
                self.transcriptViewModel.update(segments: segments)
            }
        }
    }

    private func drainLiveASRQueue(sessionID: UUID) async {
        while liveASRFailures[sessionID] == nil,
              let pending = liveASRQueues[sessionID],
              let oldest = pending.first {
            if recordingSessionID == sessionID,
               recordingPhase == .recording {
                let pressure = Self.thermalPressure(
                    from: ProcessInfo.processInfo.thermalState
                )
                let pendingCount = pending.reduce(0) { $0 + $1.segments.count }
                let decision = LiveASRThermalPolicy.decision(
                    pressure: pressure,
                    pendingCount: pendingCount,
                    oldestPendingAge: Date().timeIntervalSince(oldest.enqueuedAt)
                )
                if case .wait(let delay) = decision {
                    processingState = .backlogged
                    let text = "発熱を抑えるため文字起こしを調整中（未処理 \(pendingCount)区間）"
                    processingStatusText = text
                    transcriptViewModel.setStatus(text)
                    try? await Task.sleep(for: delay)
                }
            }

            guard liveASRFailures[sessionID] == nil,
                  var queue = liveASRQueues[sessionID],
                  !queue.isEmpty else { break }
            let batch = queue.removeFirst()
            liveASRQueues[sessionID] = queue

            let statusHandler: NativeSessionProcessor.StatusHandler = {
                [weak self] text in
                await MainActor.run {
                    guard let self,
                          self.recordingSessionID == sessionID,
                          self.recordingPhase == .recording else { return }
                    self.processingStatusText = text
                    if self.displayedSessionID == sessionID {
                        self.transcriptViewModel.setStatus(text)
                    }
                }
            }

            let updateHandler = liveUpdateHandler(sessionID: sessionID)
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

    private static func thermalPressure(
        from state: ProcessInfo.ThermalState
    ) -> ThermalPressure {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
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
        if !pausesProcessing {
            switch request {
            case .imported, .timeline, .resumeASR, .finalize:
                prepareASRModel()
            case .finishLive, .retryContentPriority, .selectCompletedASR, .diarization:
                break
            }
        }

        pendingProcessing.append(request)
        guard !pausesProcessing else { return }

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
            let requestSessionID = request.sessionID
            currentlyProcessingSessionID = requestSessionID
            processingState = .running

            let statusHandler: NativeSessionProcessor.StatusHandler = { [weak self] text in
                await MainActor.run {
                    guard let self else { return }
                    self.processingStatusText = text
                    if self.displayedSessionID == requestSessionID {
                        self.transcriptViewModel.setStatus(text)
                    }
                }
            }

            let updateHandler: NativeSessionProcessor.UpdateHandler = { [weak self] segments, state in
                await MainActor.run {
                    guard let self, self.displayedSessionID == requestSessionID else { return }
                    self.processingState = state
                    self.transcriptViewModel.update(segments: segments)
                }
            }

            switch request {
            case .finalize(let sessionID, let source):
                switch source {
                case .processingTimeline(let checkpoint):
                    _ = await sessionProcessor.processFinalTranscript(
                        sessionID: sessionID,
                        checkpoint: checkpoint,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                case .importedOriginal(let originalURL):
                    _ = await sessionProcessor.processImportedSession(
                        sessionID: sessionID,
                        originalURL: originalURL,
                        onStatus: statusHandler,
                        onUpdate: updateHandler
                    )
                }
                finalizationGate.release(sessionID)
                refreshSavedSessions()
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
            case .retryContentPriority(
                let sessionID,
                let checkpoint,
                let segmentIDs
            ):
                await sessionProcessor.retryContentPrioritySession(
                    sessionID: sessionID,
                    checkpoint: checkpoint,
                    segmentIDs: segmentIDs,
                    onStatus: statusHandler,
                    onUpdate: updateHandler
                )
                refreshSavedSessions()
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
            currentlyProcessingSessionID = nil
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
                .filter { $0.manifest.sessionID != recordingSessionID }

            guard !candidates.isEmpty else { return }

            processingStatusText = "未完了の文字起こしを復旧しています（\(candidates.count)件）"
            transcriptViewModel.setStatus(
                "未完了の文字起こしを復旧しています"
            )

            for candidate in candidates {
                let sessionID = candidate.manifest.sessionID

                switch (candidate.action, candidate.source) {
                case (
                    .retryContentPriority(let segmentIDs),
                    .processingTimeline(let checkpoint)
                ):
                    enqueueProcessing(
                        .retryContentPriority(
                            sessionID: sessionID,
                            checkpoint: checkpoint,
                            segmentIDs: segmentIDs
                        )
                    )

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

                case (.finalize, .processingTimeline(let checkpoint)):
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
        if let microphoneAccess { return await microphoneAccess() }
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

    private func isCurrentRecording(_ sessionID: UUID) -> Bool {
        recordingSessionID == sessionID && recordingPhase == .recording
    }

    private func showNewSession(_ sessionID: UUID) {
        selectedSavedSessionID = nil
        displayedSessionID = sessionID
        transcriptViewModel.update(segments: [])
    }

    func terminateCapture() {
        captureEngine.terminate()
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
