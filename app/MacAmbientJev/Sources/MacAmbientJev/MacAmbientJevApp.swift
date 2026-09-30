import SwiftUI
import MacAmbientJevCore

@main
struct MacAmbientJevApp: App {
    @StateObject private var appState: AppState

    init() {
        MicInputVolumePreference.register(in: .standard)
        _appState = StateObject(wrappedValue: AppState(
            userDefaults: .standard,
            makeLiveVADSession: AppState.makeFluidLiveVADSession
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 620)

        Settings {
            TabView {
                SettingsView(
                    onRetryDeferred: {
                        Task {
                            await appState.retryDeferredJev()
                        }
                    }
                )
                    .environmentObject(appState)
                    .tabItem {
                        Label("Jev", systemImage: "sparkles")
                    }

                DiagnosticsView(usageCounter: appState.jevUsageCounter)
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
    @State private var showsSavedSessions = false

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

                Button {
                    appState.refreshSavedSessions()
                    showsSavedSessions = true
                } label: {
                    Label("保存済み録音", systemImage: "waveform.and.mic")
                }

                Picker("録音元", selection: $appState.captureSource) {
                    Text("マイク").tag(CaptureSource.microphone)
                    Text("システム音声").tag(CaptureSource.systemAudio)
                }
                .fixedSize()
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

                Button {
                    openSettings()
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .help("Jev とマイクの設定を開く")
            }
        }
        .sheet(isPresented: $showsSavedSessions) {
            SavedSessionsView(
                sessions: appState.savedSessions,
                selectedSessionID: appState.selectedSavedSessionID,
                isUnavailableForReprocess: appState.recordingPhase != .idle,
                isSelectionUnavailable: appState.recordingPhase != .idle,
                queuedSessionIDs: appState.queuedFinalizationSessionIDs,
                onRefresh: appState.refreshSavedSessions,
                onSelect: appState.selectSavedSession(sessionID:),
                onReprocess: appState.reprocess(sessionID:)
            )
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

                    Spacer()

                    if appState.isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel("文字起こし処理中")
                    }
                }
            }

            if case .preparing = appState.modelPreparation {
                HStack(spacing: AppSpacing.sm) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.modelPreparation.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if case .failed = appState.modelPreparation {
                Text(appState.modelPreparation.statusText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private func micInputStatusRows(_ status: MicInputStatus) -> some View {
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
            case .unsupportedDevice, .pausedByExternalChange:
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
