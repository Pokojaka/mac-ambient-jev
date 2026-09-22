import AVFoundation
import Combine
import Foundation
import MacAmbientJevCore

@MainActor
final class AppState: ObservableObject {
    enum RecordingPhase: Equatable {
        case idle
        case requestingPermission
        case starting
        case recording
        case stopping
    }

    enum StatusTone: Equatable {
        case neutral
        case recording
        case warning
        case error
    }

    @Published private(set) var statusText = "待機中"
    @Published private(set) var statusTone: StatusTone = .neutral
    @Published private(set) var recordingPhase: RecordingPhase = .idle

    private let paths: AppPaths
    private let captureEngine: AudioCaptureEngine
    private let diskMonitor = DiskSpaceMonitor(
        warningThresholdBytes: 2_000_000_000,
        criticalThresholdBytes: 1_000_000_000
    )

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
    }

    var isRecording: Bool {
        recordingPhase == .recording
    }

    var isBusy: Bool {
        switch recordingPhase {
        case .requestingPermission, .starting, .stopping:
            true
        case .idle, .recording:
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

    func showImportPending() {
        guard recordingPhase == .idle else { return }
        setStatus("音声ファイルの読み込みは次の実装段階で接続します", tone: .neutral)
    }

    func startRecording() async {
        guard recordingPhase == .idle else { return }

        recordingPhase = .requestingPermission
        setStatus("マイクへのアクセスを確認しています", tone: .neutral)

        guard await requestMicrophoneAccessIfNeeded() else {
            recordingPhase = .idle
            setStatus(
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
                setStatus(
                    "空き容量が1 GB未満のため、新しい録音を開始できません。",
                    tone: .error
                )
                return
            case .warning:
                setStatus(
                    "空き容量が2 GB未満です。長時間録音では容量不足に注意してください。",
                    tone: .warning
                )
            case .normal:
                break
            }
        } catch {
            // 容量取得に失敗しても録音自体は拒否しない。
            setStatus("空き容量を確認できませんでした。録音を開始します。", tone: .warning)
        }

        recordingPhase = .starting
        if statusTone != .warning {
            setStatus("録音を開始しています", tone: .neutral)
        }

        do {
            try await captureEngine.start(sessionID: UUID())
            recordingPhase = .recording
            setStatus("録音中", tone: .recording)
        } catch {
            recordingPhase = .idle
            setStatus(error.localizedDescription, tone: .error)
        }
    }

    func stopRecording() async {
        guard recordingPhase == .recording else { return }

        recordingPhase = .stopping
        setStatus("録音を保存しています", tone: .neutral)

        do {
            let checkpoint = try await captureEngine.stop()
            let durationSeconds = checkpoint.sampleRate > 0
                ? Double(checkpoint.committedFrames) / checkpoint.sampleRate
                : 0

            recordingPhase = .idle
            setStatus(
                "録音を保存しました（\(Self.formatDuration(durationSeconds))）",
                tone: .neutral
            )
        } catch AudioCaptureEngineError.ringOverflow {
            recordingPhase = .idle
            setStatus(
                "録音は保存しましたが、保存処理が追いつかず一部の音声が欠落した可能性があります。",
                tone: .warning
            )
        } catch {
            recordingPhase = .idle
            setStatus(error.localizedDescription, tone: .error)
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

    private func setStatus(_ text: String, tone: StatusTone) {
        statusText = text
        statusTone = tone
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
