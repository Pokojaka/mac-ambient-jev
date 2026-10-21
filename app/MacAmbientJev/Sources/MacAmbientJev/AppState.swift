import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevRuntime
import MacAmbientJevPipeline
import UniformTypeIdentifiers

typealias LiveVADFactory = @MainActor (
    _ processingDirectory: URL, _ initialCheckpoint: AudioCheckpoint, _ measureMicInputLevels: Bool, _ sessionURL: URL
) async throws -> any LiveVADProcessing

enum MicInputVolumePreference {
    static let key = "capture.automaticMicInputVolume"
    static let initialValue = true

    static func register(in defaults: UserDefaults) {
        defaults.register(defaults: [key: initialValue])
    }

    static func read(from defaults: UserDefaults) throws(MicInputVolumePreferenceError) -> Bool {
        guard let value = defaults.object(forKey: key) as? Bool else {
            throw .unreadable
        }
        return value
    }
}

enum MicInputVolumePreferenceError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "マイクの入力音量を自動調整する設定を読み込めません"
    }
}

@MainActor
protocol AppCaptureEngine {
    func start(
        sessionID: UUID,
        source: CaptureSource,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onWarning: @escaping @MainActor @Sendable (String) -> Void,
        onPermissionWaiting: @escaping @MainActor @Sendable () -> Void,
        onDropouts: @escaping @MainActor @Sendable (UInt64) -> Void,
        onSilenceChanged: @escaping @MainActor @Sendable (Bool) -> Void
    ) async throws
    func cancelStarting()
    func committedCheckpoint() async throws -> AudioCheckpoint
    func stop() async throws -> AudioCaptureStopResult
    func terminate()
    func configureMicInputVolume(
        automaticAdjustmentEnabled: Bool,
        onStatus: @escaping @MainActor @Sendable (UUID, MicInputStatus) -> Void
    )
    func consumeMicSpeechLevels(_ windows: [MicLevelWindow], sessionID: UUID)
    func micSpeechMonitoringUnavailable(sessionID: UUID)
}

extension AudioCaptureEngine: AppCaptureEngine {}

final class TerminationObservation {
    private let token: NSObjectProtocol
    private let center: NotificationCenter

    init(center: NotificationCenter, onTermination: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in onTermination() }
    }

    deinit { center.removeObserver(token) }
}

@MainActor
final class AppState: ObservableObject {
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

    @Published var statusText = UserFacingStatus.idle.text
    @Published var statusTone: StatusTone = .neutral
    @Published var recording = RecordingLifecycle()
    var recordingPhase: RecordingPhase { recording.phase }
    @Published var captureSource: CaptureSource = .microphone
    @Published var captureWarningText: String?
    /// Live input-level status of the current microphone recording. Only failures outlive the recording.
    @Published var micInputStatus: MicInputStatus?
    @Published var isMicrophoneSilent = false
    @Published var dropoutCount: UInt64 = 0
    @Published var modelPreparation: ModelPreparation = .idle
    @Published var processingState: ProcessingState = .idle
    @Published var processingStatusText: String?
    @Published var processingQueue = SessionProcessingQueue()
    @Published var savedSessionOperations = SavedSessionOperations()
    @Published var exportDirectoryPath: String?
    @Published var exportDestinationMessage: String?

    var savedSessions: [SavedSessionSummary] { savedSessionOperations.sessions }
    var selectedSavedSessionURL: URL? { savedSessionOperations.selectedSessionURL }
    var sessionExports: [UUID: SessionExportState] { savedSessionOperations.exports }

    let transcriptViewModel = LiveTranscriptViewModel()
    let liveTranscription = LiveTranscriptionState()
    let decisionUsageCounter: DecisionUsageCounter

    let paths: AppPaths
    let exportDestination: ExportDestinationStore
    let captureEngine: any AppCaptureEngine
    let decisionProviderFactory: DecisionProviderFactory
    let sessionProcessor: NativeSessionProcessor
    // Device-rate disk requirements and the in-recording floor are enforced by AudioCaptureEngine.
    let microphoneAccess: @MainActor () async -> Bool
    let pausesProcessing: Bool
    let userDefaults: UserDefaults
    let makeLiveVADSession: LiveVADFactory
    let thermalMonitor: any ThermalMonitoring
    let liveTranscriptionSleep: @MainActor (Duration) async throws -> Void

    var recordingSessionID: UUID? { recording.sessionID }
    /// Set only while the current recording captures the microphone.
    var micInputSessionID: UUID?
    var displayedSessionID: UUID?
    private var thermalObservation: (any ThermalStateObservation)?
    lazy var processingCoordinator = SessionProcessingCoordinator(
        effects: self,
        processor: sessionProcessor,
        thermalMonitor: thermalMonitor
    )
    lazy var liveCoordinator: LiveTranscriptionCoordinator = LiveTranscriptionCoordinator(
        state: liveTranscription,
        effects: self,
        processor: sessionProcessor,
        thermalMonitor: thermalMonitor,
        sleep: liveTranscriptionSleep
    )
    var modelPreparationTask: Task<Void, Never>?
    var idleReleaseTask: Task<Void, Never>?
    var failureStopTask: Task<Void, Never>?
    var startupMaintenanceTask: Task<Void, Never>?
    var terminationObserver: TerminationObservation?

    init(
        paths: AppPaths,
        captureEngine: any AppCaptureEngine,
        microphoneAccess: @escaping @MainActor () async -> Bool,
        pausesProcessing: Bool,
        userDefaults: UserDefaults,
        engines: SessionProcessingEngines,
        makeLiveVADSession: @escaping LiveVADFactory,
        thermalMonitor: any ThermalMonitoring,
        liveTranscriptionSleep: @escaping @MainActor (Duration) async throws -> Void,
        makeDecisions: (@Sendable (AppPaths, DecisionUsageCounter) -> NativeSessionProcessor.DecisionCoordinatorFactory)? = nil
    ) {
        let decisionUsageCounter = DecisionUsageCounter()
        let decisionProviderFactory = DecisionProviderFactory(
            usageCounter: decisionUsageCounter,
            loadProvider: {
                let tagger = try LocalClauseTagger(modelDirectory: LocalClauseTagger.bundledModelDirectory())
                return LoadedDecisionProvider(provider: tagger, identity: tagger.identity)
            }
        )

        self.paths = paths
        self.decisionUsageCounter = decisionUsageCounter
        self.captureEngine = captureEngine
        self.microphoneAccess = microphoneAccess
        self.pausesProcessing = pausesProcessing
        self.userDefaults = userDefaults
        self.exportDestination = ExportDestinationStore(defaults: userDefaults)
        self.makeLiveVADSession = makeLiveVADSession
        self.thermalMonitor = thermalMonitor
        self.liveTranscriptionSleep = liveTranscriptionSleep
        self.decisionProviderFactory = decisionProviderFactory

        let makeDecisionCoordinator: NativeSessionProcessor.DecisionCoordinatorFactory
        if let makeDecisions {
            makeDecisionCoordinator = makeDecisions(paths, decisionUsageCounter)
        } else {
            makeDecisionCoordinator = { try decisionProviderFactory.makeCoordinator() }
        }
        self.sessionProcessor = NativeSessionProcessor(
            paths: paths,
            engines: engines,
            audioHandling: MacSessionProcessingAudio(),
            contentPriority: .localTagger(makeDecisionCoordinator, usageCounter: decisionUsageCounter),
            sleep: { try await Task.sleep(for: $0) }
        )
        self.exportDirectoryPath = exportDestination.path
        thermalObservation = thermalMonitor.observeChanges { [weak self] in
            self?.resumeThermallyHeldProcessing()
        }

        terminationObserver = TerminationObservation(center: .default) { [weak self] in
            MainActor.assumeIsolated { self?.terminateCapture() }
        }
        if !pausesProcessing {
            processingQueue.beginStorageMaintenance()
            startupMaintenanceTask = Task { [weak self] in
                guard let self else { return }
                await self.processingCoordinator.recoverPendingSessions(
                    effects: self,
                    scan: {
                        try SessionRecoveryScanner(sessionsRoot: self.paths.sessionsRoot).pendingSessions()
                    },
                    maintain: { items, willMaintain in
                        await SessionStorageMaintainer.maintain(items, willMaintain: willMaintain)
                    }
                )
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
        processingQueue.sessionIDs
    }
}
