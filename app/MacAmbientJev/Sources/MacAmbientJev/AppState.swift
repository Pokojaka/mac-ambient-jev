import AppKit
import AVFoundation
import Combine
import Dispatch
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevCapture
import MacAmbientJevRuntime
import UniformTypeIdentifiers

/// Incremental VAD is independent of capture and consumes only durable checkpoints.
protocol LiveVADProcessing: Sendable {
    var segmentationRunID: String { get }
    func processAvailable(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
    func finish(checkpoint: AudioCheckpoint) async throws -> LiveVADProgress
}

extension LiveVADSession: LiveVADProcessing {}

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

final class ThermalStateObservation {
    private let token: NSObjectProtocol
    private let center: NotificationCenter

    init(center: NotificationCenter, onChange: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in onChange() }
    }

    deinit { center.removeObserver(token) }
}

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
        case finishLive(sessionID: UUID, checkpoint: AudioCheckpoint)
        case finalize(sessionID: UUID, metadataPolicy: UnreadableMetadataPolicy)
        case retryContentPriority(
            sessionID: UUID,
            boundarySegments: [SegmentTextReference],
            clauses: [ClauseReference]
        )

        var sessionID: UUID {
            switch self {
            case .finishLive(let sessionID, _),
                 .finalize(let sessionID, _),
                 .retryContentPriority(let sessionID, _, _):
                sessionID
            }
        }

        var finalizesTranscript: Bool {
            switch self {
            case .finishLive, .finalize:
                true
            case .retryContentPriority:
                false
            }
        }
    }

    enum SessionExportState: Equatable {
        case exporting
        case exported(URL)
        case failed(String)
    }

    struct LiveASRBatch {
        let segments: [SegmentReference]
    }

    @Published var statusText = UserFacingStatus.idle.text
    @Published var statusTone: StatusTone = .neutral
    @Published var recordingPhase: RecordingPhase = .idle
    @Published var captureSource: CaptureSource = .microphone
    @Published var captureWarningText: String?
    /// Live input-level status of the current microphone recording. Only failures outlive the recording.
    @Published var micInputStatus: MicInputStatus?
    @Published var isMicrophoneSilent = false
    @Published var dropoutCount: UInt64 = 0
    @Published var modelPreparation: ModelPreparation = .idle
    @Published var processingState: ProcessingState = .idle
    @Published var processingStatusText: String?
    @Published var savedSessions: [SavedSessionSummary] = []
    @Published var selectedSavedSessionURL: URL?
    @Published var exportDirectoryPath: String?
    @Published var exportDestinationMessage: String?
    @Published var sessionExports: [UUID: SessionExportState] = [:]

    let transcriptViewModel = LiveTranscriptViewModel()
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

    var recordingSessionID: UUID?
    /// Set only while the current recording captures the microphone.
    var micInputSessionID: UUID?
    var displayedSessionID: UUID?
    var pendingCaptureFailure: (sessionID: UUID, message: String)?
    var pendingProcessing: [PendingProcessing] = []
    /// Finalizations held while the Mac is at critical thermal state, resumed in order when it cools.
    var thermallyHeldProcessing: [PendingProcessing] = []
    var thermalObserver: ThermalStateObservation?
    var currentlyProcessingSessionID: UUID?
    var finalizationGate = SavedSessionReprocessGate()
    var processingTask: Task<Void, Never>?
    /// True while launch maintenance may compact recordings; the processing queue does not start.
    var isMaintainingStorage = false
    var modelPreparationTask: Task<Void, Never>?
    var idleReleaseTask: Task<Void, Never>?
    var startupMaintenanceTask: Task<Void, Never>?
    var terminationObserver: TerminationObservation?

    var liveVADSession: (any LiveVADProcessing)?
    var liveVADTask: Task<Void, Never>?
    var liveVADSegmentCount = 0
    var liveVADFailureText: String?

    var liveASRQueues: [UUID: [LiveASRBatch]] = [:]
    var liveASRLatestCheckpoints: [UUID: AudioCheckpoint] = [:]
    var liveASRTasks: [UUID: Task<Void, Never>] = [:]
    var liveASRFailures: [UUID: String] = [:]
    var liveContentPriorityStatus: [UUID: String] = [:]
    var readLiveThermalPressure: @MainActor () -> ThermalPressure = AppState.currentThermalPressure

    init(
        paths: AppPaths,
        captureEngine: any AppCaptureEngine,
        microphoneAccess: @escaping @MainActor () async -> Bool,
        pausesProcessing: Bool,
        userDefaults: UserDefaults,
        engines: SessionProcessingEngines,
        makeLiveVADSession: @escaping LiveVADFactory,
        makeDecisions: (@Sendable (AppPaths, DecisionUsageCounter) -> NativeSessionProcessor.DecisionCoordinatorFactory)? = nil
    ) {
        let decisionUsageCounter = DecisionUsageCounter()
        let decisionProviderFactory = DecisionProviderFactory(usageCounter: decisionUsageCounter) {
            try LocalClauseTagger(modelDirectory: LocalClauseTagger.bundledModelDirectory())
        }

        self.paths = paths
        self.decisionUsageCounter = decisionUsageCounter
        self.captureEngine = captureEngine
        self.microphoneAccess = microphoneAccess
        self.pausesProcessing = pausesProcessing
        self.userDefaults = userDefaults
        self.exportDestination = ExportDestinationStore(defaults: userDefaults)
        self.makeLiveVADSession = makeLiveVADSession
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
            contentPriority: .localTagger(makeDecisionCoordinator, usageCounter: decisionUsageCounter)
        )
        self.exportDirectoryPath = exportDestination.path

        terminationObserver = TerminationObservation(center: .default) { [weak self] in
            MainActor.assumeIsolated { self?.terminateCapture() }
        }
        thermalObserver = ThermalStateObservation(center: .default) { [weak self] in
            MainActor.assumeIsolated { self?.resumeThermallyHeldProcessing() }
        }

        if !pausesProcessing {
            isMaintainingStorage = true
            startupMaintenanceTask = Task { [weak self] in
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
            .union(thermallyHeldProcessing.map(\.sessionID))
            .union(currentlyProcessingSessionID.map { [$0] } ?? [])
    }
}
