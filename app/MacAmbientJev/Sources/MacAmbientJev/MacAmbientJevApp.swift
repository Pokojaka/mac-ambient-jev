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
    @StateObject private var transcriptViewModel = LiveTranscriptViewModel()

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            LiveTranscriptView(viewModel: transcriptViewModel)
        }
        .frame(minWidth: 720, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.statusText = "音声ファイルの読み込みは次の実装段階で接続します"
                } label: {
                    Label("音声ファイルを読み込む", systemImage: "doc.badge.plus")
                }
                .disabled(appState.isBusy || appState.isRecording)

                Button {
                    Task {
                        await appState.toggleRecording()
                    }
                } label: {
                    Label(
                        appState.isRecording ? "録音を停止" : "録音を開始",
                        systemImage: appState.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(appState.isBusy)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: AppSpacing.sm) {
            statusIcon

            Text(appState.statusText)
                .font(.callout)
                .foregroundStyle(statusTextStyle)
                .lineLimit(2)

            Spacer()

            if appState.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("処理中")
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private var statusIcon: some View {
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
                .accessibilityLabel("警告")
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("エラー")
        }
    }

    private var statusTextStyle: some ShapeStyle {
        switch appState.statusTone {
        case .neutral, .recording:
            AnyShapeStyle(Color.secondary)
        case .warning:
            AnyShapeStyle(Color.primary)
        case .error:
            AnyShapeStyle(Color.primary)
        }
    }
}
