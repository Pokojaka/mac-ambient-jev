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
    }
}

private struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Clean Transcription Core")
                .font(.title2)

            Button("録音を開始") {
                appState.statusText = "録音の準備をしています"
            }

            Button("音声ファイルを読み込む") {
                appState.statusText = "音声ファイルを選択してください"
            }

            Text(appState.statusText)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 520, minHeight: 320)
        .padding(24)
    }
}
