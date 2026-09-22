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
                    appState.statusText = "音声ファイルを選択してください"
                } label: {
                    Label("音声ファイルを読み込む", systemImage: "doc.badge.plus")
                }

                Button {
                    appState.statusText = "録音の準備をしています"
                } label: {
                    Label("録音を開始", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: AppSpacing.sm) {
            Image(systemName: "circle.fill")
                .font(.system(size: AppIconSize.small))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(appState.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }
}
