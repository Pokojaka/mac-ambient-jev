import SwiftUI
import MacAmbientJevCore

@main
struct MacAmbientJevApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 620)
    }
}

private struct ContentView: View {
    @EnvironmentObject private var appState: AppState

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
                    Task {
                        await appState.toggleRecording()
                    }
                } label: {
                    Label(
                        appState.isRecording ? "録音を停止" : "録音を開始",
                        systemImage: appState.isRecording
                            ? "stop.circle.fill"
                            : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(appState.isBusy)
            }
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
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
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
