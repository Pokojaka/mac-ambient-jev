import AppKit
import AVFoundation
import Combine
import Foundation
import MacAmbientJevCore
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
    }

    @Published private(set) var statusText = "待機中"
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var recordingPhase: RecordingPhase = .idle
    @Published private(set) var processingState: ProcessingState = .idle
    @Published private(set) var processingStatusText: String?

    let transcriptViewModel = LiveTranscriptViewModel()

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

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)

        let cache = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches", directoryHint: .isDirectory)

        let paths = AppPaths(
            applicationSupportURL: applicationSupport,
            cacheURL: cache
        )

        self.paths = paths
        self.captureEngine = AudioCaptureEngine(paths: paths)
        self.sessionProcessor = NativeSessionProcessor(paths: paths)

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
        setCaptureStatus("音声ファイルを読み込んでいます", tone: .neutral)

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
        setCaptureStatus("マイクへのアクセスを確認しています", tone: .neutral)

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
            setCaptureStatus("録音を開始しています", tone: .neutral)
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
            let result = try await captureEngine.stop()
            let checkpoint = result.checkpoint
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
            } else {
                setCaptureStatus(
                    "録音を保存しました（\(Self.formatDuration(durationSeconds))）",
                    tone: .neutral
                )
            }

            enqueueProcessing(
                .timeline(
                    sessionID: sessionID,
                    checkpoint: checkpoint
                )
            )
        } catch {
            recordingSessionID = nil
            recordingPhase = .idle
            setCaptureStatus(error.localizedDescription, tone: .error)
        }
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
                switch candidate.source {
                case .processingTimeline(let checkpoint):
                    enqueueProcessing(
                        .timeline(
                            sessionID: candidate.manifest.sessionID,
                            checkpoint: checkpoint
                        )
                    )
                case .importedOriginal(let originalURL):
                    enqueueProcessing(
                        .imported(
                            sessionID: candidate.manifest.sessionID,
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
        let manifest = SessionManifest(
            sessionID: sessionID,
            createdAt: Date(),
            sourceKind: sourceKind,
            originalFilename: originalFilename
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true
        )
        try encoder.encode(manifest).write(
            to: sessionURL.appending(path: "session.json"),
            options: .atomic
        )
        _ = try SessionWriter(sessionURL: sessionURL)
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
