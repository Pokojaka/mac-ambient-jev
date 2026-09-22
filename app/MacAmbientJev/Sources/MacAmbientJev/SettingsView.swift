import SwiftUI
import MacAmbientJevCore

struct SettingsView: View {
    private static let apiKeyAccount = "jev-api-key"

    @AppStorage("jev.isPaused") private var isJevPaused = false
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let secretStore: any SecretStore

    init(secretStore: any SecretStore = KeychainStore()) {
        self.secretStore = secretStore
    }

    var body: some View {
        Form {
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
            }

            Section("送信される情報") {
                Text("内容優先度判定では現在の発話テキストだけを送信します。")
                Text("場面転換の補助判定では現在の発話、直前3発話まで、現在の場面状態だけを送信します。")
                Text("原音声、音声ファイルのパス、話者埋め込み、セッション全文は送信しません。")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 360)
        .task {
            refreshStoredKeyState()
        }
    }

    private var jevEnabledBinding: Binding<Bool> {
        Binding(
            get: { !isJevPaused },
            set: { isJevPaused = !$0 }
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
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
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
