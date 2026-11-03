import SwiftUI
import MacAmbientJevCore
import MacAmbientJevAppleSupport
import MacAmbientJevCapture
import MacAmbientJevRuntime

@main
struct MacAmbientJevApp: App {
    @StateObject private var appState: AppState

    init() {
        MicInputVolumePreference.register(in: .standard)
        let paths: AppPaths
        do {
            paths = try AppPaths.systemDefault(fileManager: .default)
        } catch {
            preconditionFailure("保存先を決められないため起動できません: \(error.localizedDescription)")
        }
        let models: MacModelStore
        do {
            models = try MacModelStore(paths: paths)
        } catch {
            preconditionFailure("同梱モデルマニフェストを読めないため起動できません: \(error.localizedDescription)")
        }
        _appState = StateObject(wrappedValue: AppState(
            paths: paths,
            captureEngine: AudioCaptureEngine(paths: paths),
            microphoneAccess: AppState.requestSystemMicrophoneAccess,
            pausesProcessing: false,
            userDefaults: .standard,
            engines: .production(models: models),
            modelProvisioning: MacModelProvisioning(store: models, transport: URLSessionModelTransport()),
            makeLiveVADSession: AppState.fluidLiveVADFactory(models: models),
            thermalMonitor: MacThermalMonitor(),
            liveTranscriptionSleep: { try await Task.sleep(for: $0) }
        ))
    }

    var body: some Scene {
        Window("MacAmbientJev", id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 620)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("保存済み録音", id: SavedSessionsWindow.id) {
            SavedSessionsWindow()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            TabView {
                SettingsView()
                    .environmentObject(appState)
                    .tabItem {
                        Label("一般", systemImage: "gearshape")
                    }

                DiagnosticsView(usageCounter: appState.decisionUsageCounter)
                    .tabItem {
                        Label("診断", systemImage: "waveform.path.ecg")
                    }
            }
            .padding(.top, AppSpacing.sm)
        }
    }
}

private struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            LiveTranscriptView(
                viewModel: appState.transcriptViewModel
            )
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.importAudioFile()
                    }
                } label: {
                    Label(
                        "音声ファイルを読み込む",
                        systemImage: "doc.badge.plus"
                    )
                }
                .disabled(appState.isBusy || appState.isRecording)
                .help(importHelp)

                Button {
                    appState.refreshSavedSessions()
                    openWindow(id: SavedSessionsWindow.id)
                } label: {
                    Label("保存済み録音", systemImage: "waveform.and.mic")
                }
                .help("これまでの録音と読み込んだ音声を一覧で表示")

                Picker("録音元", selection: $appState.captureSource) {
                    Text("マイク").tag(CaptureSource.microphone)
                    Text("システム音声").tag(CaptureSource.systemAudio)
                }
                .pickerStyle(.segmented)
                .help(appState.recordingPhase == .idle ? "録音する音声をマイクかシステム音声から選択" : "録音中は切り替え不可")
                .disabled(appState.recordingPhase != .idle)

                Button {
                    Task {
                        await appState.toggleRecording()
                    }
                } label: {
                    Label(
                        appState.isRecording || appState.recordingPhase == .starting
                            ? "録音を停止" : "録音を開始",
                        systemImage: appState.isRecording || appState.recordingPhase == .starting
                            ? "stop.circle.fill"
                            : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(appState.isBusy && appState.recordingPhase != .starting)
                .help(recordingHelp)

                Button {
                    openSettings()
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .help("音声認識モデル、保存先、マイクの設定を表示")
            }
        }
    }

    private var importHelp: String {
        if appState.isRecording { return "録音中は読み込み不可" }
        if appState.isBusy { return "録音操作の処理が終わると読み込み可能" }
        return "音声ファイルを読み込んで文字起こし"
    }

    private var recordingHelp: String {
        if appState.isRecording || appState.recordingPhase == .starting { return "録音を終えて文字起こしを確定" }
        if appState.isBusy { return "録音操作の処理が終わると開始可能" }
        return switch appState.captureSource {
        case .microphone: "マイクの音声を録音し、その場で文字起こし"
        case .systemAudio: "Mac で再生中の音声を録音し、その場で文字起こし"
        }
    }

    private var statusBar: some View {
        VStack(spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.sm) {
                captureStatusIcon

                Text(appState.statusText)
                    .font(.callout)
                    .foregroundStyle(captureStatusTextStyle)
                    .lineLimit(2)
                    .help(appState.statusText)

                Spacer()

                if appState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("録音操作を処理中")
                }
            }

            if let warning = appState.captureWarningText {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let micInputStatus = appState.micInputStatus {
                micInputStatusRows(micInputStatus)
            }
            if appState.isRecording, appState.isMicrophoneSilent {
                Text(appState.captureSource == .systemAudio
                     ? "システム音声が30秒以上無音です"
                     : "マイク入力が30秒以上無音です。ミュート設定を確認してください")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if appState.isRecording, appState.dropoutCount > 0 {
                Text("音声の欠落: \(appState.dropoutCount) 回")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let processingStatusText = appState.processingStatusText {
                HStack(spacing: AppSpacing.sm) {
                    processingStatusIcon

                    Text(processingStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(processingStatusText)

                    Spacer()

                    if appState.isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("文字起こし処理中")
                    }
                }
            }

            switch appState.modelPreparation.phase {
            case .downloading, .loading:
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.modelPreparation.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .failed:
                Text(appState.modelPreparation.summaryText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .idle, .ready:
                EmptyView()
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private func micInputStatusRows(_ status: MicInputStatus) -> some View {
        if appState.isRecording, status.speechMonitoringUnavailable {
            Text(MicInputStatus.speechMonitoringUnavailableText)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if appState.isRecording, let warning = status.warning {
            Text(warning.text)
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if appState.isRecording || status.adjustment.isFailure {
            switch status.adjustment {
            case .active, .disabledBySetting:
                Text(status.adjustment.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .unsupportedDevice, .pausedByExternalChange, .pausedByDefaultDeviceChange:
                Text(status.adjustment.text)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed, .restoreFailed:
                Label(status.adjustment.text, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("入力音量のエラー: \(status.adjustment.text)")
            }
        }
    }

    @ViewBuilder
    private var captureStatusIcon: some View {
        switch appState.statusTone {
        case .neutral:
            Image(systemName: "circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("録音中")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("録音の警告")
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("録音エラー")
        }
    }

    @ViewBuilder
    private var processingStatusIcon: some View {
        switch appState.processingState {
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .running:
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .accessibilityLabel("文字起こし処理中")
        case .backlogged:
            Image(systemName: "clock")
                .foregroundStyle(.orange)
                .accessibilityLabel("文字起こし待機中")
        case .complete:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("文字起こし完了")
        case .partialFailure:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel("文字起こしに一部失敗")
        }
    }

    private var captureStatusTextStyle: some ShapeStyle {
        switch appState.statusTone {
        case .neutral, .recording:
            AnyShapeStyle(Color.secondary)
        case .warning, .error:
            AnyShapeStyle(Color.primary)
        }
    }
}

private struct SavedSessionsWindow: View {
    static let id = "saved-sessions"

    @EnvironmentObject private var appState: AppState

    var body: some View {
        SavedSessionsView(
            sessions: appState.savedSessions,
            selectedSessionURL: appState.selectedSavedSessionURL,
            isUnavailableForReprocess: appState.recordingPhase != .idle,
            isSelectionUnavailable: appState.recordingPhase != .idle,
            queuedSessionIDs: appState.queuedFinalizationSessionIDs,
            sessionExports: appState.sessionExports,
            hasExportDestination: appState.exportDirectoryPath != nil,
            onRefresh: appState.refreshSavedSessions,
            onSelect: appState.selectSavedSession(sessionURL:),
            onReprocess: appState.reprocess(sessionID:),
            onExport: { sessionID in
                Task { await appState.exportSavedSession(sessionID: sessionID) }
            },
            onRevealExport: { sessionID in
                Task { await appState.revealExport(sessionID: sessionID) }
            },
            onRevealSessionFolder: appState.revealSessionFolder(sessionURL:)
        )
        .onAppear(perform: appState.refreshSavedSessions)
    }
}
