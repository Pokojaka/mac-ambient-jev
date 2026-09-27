import AVFoundation
import SwiftUI
import MacAmbientJevCore

struct SettingsView: View {
    private static let apiKeyAccount = "jev-api-key"

    @EnvironmentObject private var appState: AppState

    @AppStorage("jev.isPaused") private var isJevPaused = false
    @AppStorage(ExportDestinationStore.autoExportKey) private var isAutoExportEnabled = true
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isCheckingJev = false
    @State private var microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)

    private let secretStore: any SecretStore
    private let onRetryDeferred: () -> Void

    init(
        secretStore: any SecretStore = KeychainStore(),
        onRetryDeferred: @escaping () -> Void = {}
    ) {
        self.secretStore = secretStore
        self.onRetryDeferred = onRetryDeferred
    }

    var body: some View {
        Form {
            Section("音声認識モデル") {
                LabeledContent("状態", value: appState.modelPreparation.statusText)

                if case .preparing(let progress) = appState.modelPreparation {
                    ProgressView(value: progress)
                        .accessibilityLabel("音声認識モデルの準備")
                } else if appState.modelPreparation != .ready {
                    Button("モデルを準備") {
                        appState.prepareASRModel()
                    }
                }

                Text("初回は約2.5 GBをアプリ内にダウンロードします。録音中でも音声の保存と発話検出は続きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("保存先") {
                LabeledContent("書き出し先") {
                    Text(appState.exportDirectoryPath ?? "未設定")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("フォルダを選択…") {
                        appState.chooseExportDirectory()
                    }
                    Button("Finderで表示") {
                        Task { await appState.revealExportDirectory() }
                    }
                    .disabled(appState.exportDirectoryPath == nil)
                }

                Toggle("処理完了後に自動で書き出す", isOn: $isAutoExportEnabled)
                    .disabled(appState.exportDirectoryPath == nil)

                Text("録音ごとにフォルダを作り、文字起こし（transcript.txt）と音声を保存します。録音した音声は可逆圧縮の FLAC、読み込んだ音声は元のファイルのままです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let message = appState.exportDestinationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Jev") {
                Toggle("Jev の意味分類を使用する", isOn: jevEnabledBinding)

                Text(
                    "録音、音声認識、話者分離、場面判定はローカルで動作します。Jev を停止しても文字起こしは継続します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LabeledContent("APIキー") {
                    Text(hasStoredKey ? "Keychain に保存済み" : "未設定")
                        .foregroundStyle(.secondary)
                }

                SecureField(
                    hasStoredKey
                        ? "新しいAPIキーで置き換える"
                        : "APIキーを入力",
                    text: $apiKey
                )
                .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Keychain に保存") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if hasStoredKey {
                        Button("削除", role: .destructive) {
                            deleteAPIKey()
                        }
                        .disabled(isCheckingJev)
                    }
                }

                if hasStoredKey {
                    HStack {
                        Button("Jev 接続を確認") {
                            Task { await checkJevConnection() }
                        }
                        .disabled(isJevPaused || isCheckingJev)

                        Button("保留中の分類を再試行") {
                            onRetryDeferred()
                        }
                        .disabled(isJevPaused || isCheckingJev)
                    }
                }

                if let statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .accessibilityElement(children: .combine)
                }
                if isCheckingJev {
                    ProgressView("Jev の応答を待っています")
                        .controlSize(.small)
                }
            }

            Section("マイク録音テスト") {
                LabeledContent("マイク権限", value: microphonePermissionText)

                Button("マイク権限を確認") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
                .disabled(microphoneAccess != .notDetermined)

                Text("メイン画面で「録音を開始」を押し、声を入れてから「録音を停止」を押してください。保存状態と文字起こしを確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if microphoneAccess == .denied || microphoneAccess == .restricted {
                    Text("マイクを使用する場合は、システム設定の「プライバシーとセキュリティ」→「マイク」で許可してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("送信される情報") {
                Text("内容優先度判定では現在の発話テキストだけを送信します。")
                Text("場面転換の補助判定では現在の発話、直前3発話まで、現在の場面状態だけを送信します。")
                Text("原音声、音声ファイルのパス、話者埋め込み、セッション全文は送信しません。")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .task {
            refreshStoredKeyState()
            microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var jevEnabledBinding: Binding<Bool> {
        Binding(
            get: { !isJevPaused },
            set: { enabled in
                isJevPaused = !enabled
                if enabled {
                    onRetryDeferred()
                }
            }
        )
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try secretStore.save(trimmed, account: Self.apiKeyAccount)
            apiKey = ""
            hasStoredKey = true
            statusIsError = false
            statusMessage = "APIキーを Keychain に保存しました"
            if !isJevPaused {
                onRetryDeferred()
            }
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private var microphonePermissionText: String {
        switch microphoneAccess {
        case .authorized: "許可済み"
        case .notDetermined: "未確認"
        case .denied: "拒否"
        case .restricted: "利用できません"
        @unknown default: "確認できません"
        }
    }

    private func checkJevConnection() async {
        guard hasStoredKey, !isJevPaused, !isCheckingJev else { return }
        isCheckingJev = true
        defer { isCheckingJev = false }

        do {
            guard let key = try secretStore.load(account: Self.apiKeyAccount), !key.isEmpty else {
                hasStoredKey = false
                statusIsError = true
                statusMessage = "APIキーが保存されていません"
                return
            }
            let decision = try await JevClient(apiKey: key).classifyPriority(
                text: "これは接続確認のためのテスト文です。"
            )
            statusIsError = false
            statusMessage = "Jev から応答を受信しました（\(decision.priority == .primary ? "通常表示" : "低優先度")）"
        } catch {
            statusIsError = true
            statusMessage = "Jev 接続を確認できませんでした: \(error.localizedDescription)"
        }
    }

    private func deleteAPIKey() {
        do {
            try secretStore.delete(account: Self.apiKeyAccount)
            apiKey = ""
            hasStoredKey = false
            statusIsError = false
            statusMessage = "保存済みのAPIキーを削除しました"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func refreshStoredKeyState() {
        do {
            hasStoredKey = try secretStore.load(account: Self.apiKeyAccount) != nil
            statusIsError = false
        } catch {
            hasStoredKey = false
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
