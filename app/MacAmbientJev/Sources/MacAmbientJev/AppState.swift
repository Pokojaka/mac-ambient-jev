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