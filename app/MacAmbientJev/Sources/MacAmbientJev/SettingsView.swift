import AVFoundation
import SwiftUI
import MacAmbientJevCore
import MacAmbientJevAppleSupport

struct SettingsView: View {
    private static let apiKeyAccount = "jev-api-key"

    @EnvironmentObject private var appState: AppState

    @AppStorage(MicInputVolumePreference.key)
    private var automaticMicInputVolume = MicInputVolumePreference.initialValue
    @AppStorage(ExportDestinationStore.autoExportKey)
    private var isAutoExportEnabled = ExportDestinationStore.autoExportInitialValue
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var checkingEngine: DecisionEngineChoice?
    @State private var checkedLocalModelIdentity: ClauseTaggerModelIdentity?
    @State private var isRevealingExportDirectory = false
    @State private var isRetryingDeferred = false
    @State private var microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)

    private let secretStore: any SecretStore

    init(secretStore: any SecretStore) {
        self.secretStore = secretStore
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
                LabeledContent("録音データ") {
                    Text(appState.paths.sessionsRoot.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Button("Finderで表示") {
                    appState.revealSessionsRoot()
                }

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
                        isRevealingExportDirectory = true
                        Task {
                            await appState.revealExportDirectory()
                            isRevealingExportDirectory = false
                        }
                    }
                    .disabled(appState.exportDirectoryPath == nil || isRevealingExportDirectory)
                    if isRevealingExportDirectory {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Finderで表示しています")
                    }
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

            Section("発話文の判定") {
                if appState.decisionPause != nil {
                    Toggle("境界判定と優先度判定を使用する", isOn: decisionEnabledBinding)
                        .disabled(decisionControlsDisabled)
                } else {
                    Label("境界判定と優先度判定を使用する", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("判定エンジン", selection: decisionEngineBinding) {
                    if appState.decisionEngine == nil {
                        Text("設定エラー").tag(Optional<DecisionEngineChoice>.none)
                    }
                    ForEach(DecisionEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(Optional(choice))
                    }
                }
                .disabled(decisionControlsDisabled || checkingEngine != nil || isRetryingDeferred)

                if let error = appState.decisionPreferenceError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text(
                    "録音、発話区間検出、音声認識、話者分離はローカルで動作します。BTSJ の発話文では、「けど」「が」「し」に続くフィラーや倒置・後付けだけでは新しい単位に分割しません。選択したエンジンが境界判定と優先度判定を行い、停止中も文字起こしは継続します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if selectedEngineChoice == .jev {
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
                    .disabled(appState.decisionPreferenceError != nil)

                    HStack {
                        Button("Keychain に保存") {
                            saveAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            appState.decisionPreferenceError != nil
                                || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        if hasStoredKey {
                            Button("削除", role: .destructive) {
                                deleteAPIKey()
                            }
                            .disabled(appState.decisionPreferenceError != nil || checkingEngine != nil)

                            Button("Jev 接続を確認") {
                                Task { await checkSelectedEngine() }
                            }
                            .disabled(
                                appState.decisionPreferenceError != nil
                                    || appState.decisionPause != false
                                    || checkingEngine != nil
                            )
                        }
                    }
                } else if selectedEngineChoice == .localModel {
                    LabeledContent("モデルの場所") {
                        Text(LocalClauseTagger.modelDirectory(paths: appState.paths).path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Text("この場所に ClauseTagger.mlpackage と tokenizer.json が必要です。モデルのダウンロードや別の保存先はありません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("モデルを確認") {
                        Task { await checkSelectedEngine() }
                    }
                    .disabled(decisionControlsDisabled || checkingEngine != nil)

                    if let checkedLocalModelIdentity {
                        Text("モデル ID: \(checkedLocalModelIdentity.modelID)")
                            .font(.caption)
                            .textSelection(.enabled)
                        Text("revision: \(checkedLocalModelIdentity.revision)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                HStack {
                    Button("保留中の判定を再試行") {
                        isRetryingDeferred = true
                        Task {
                            await appState.retryDeferredDecisions()
                            isRetryingDeferred = false
                        }
                    }
                    .disabled(
                        decisionControlsDisabled
                            || appState.decisionPause != false
                            || checkingEngine != nil
                            || isRetryingDeferred
                            || selectedEngineChoice == nil
                    )
                    if isRetryingDeferred {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("保留中の判定を再試行しています")
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
                if let checkingEngine {
                    ProgressView("\(checkingEngine.displayName) を確認しています")
                        .controlSize(.small)
                }
            }

            Section("マイク録音テスト") {
                Toggle("マイクの入力音量を自動調整する", isOn: $automaticMicInputVolume)
                    .disabled(appState.recordingPhase != .idle)

                Text("マイク録音中にシステムの入力音量を変更します。録音を停止すると元に戻します。手動で変更した場合は、その音量を保ちます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                if selectedEngineChoice == .jev {
                    Text("対象区間の ASR 原文と候補位置、次区間の先頭60 Character以内、優先度判定の発話文本文だけを Jev に送ります。")
                    Text("原音声、音声ファイルのパス、話者埋め込み、セッション全文は送信しません。")
                } else if selectedEngineChoice == .localModel {
                    Text("ローカルモデルの判定テキストはネットワークに送信しません。")
                    Text("原音声、音声ファイルのパス、話者埋め込み、セッション全文も送信しません。")
                } else {
                    Text("判定エンジンの設定が不正なため、判定テキストの送信先を決定できません。")
                }
            }
            .font(.callout)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .task {
            appState.refreshDecisionPreferences()
            refreshStoredKeyStateIfJevSelected()
            microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onChange(of: appState.decisionEngine) { _, _ in
            statusMessage = nil
            statusIsError = false
            checkedLocalModelIdentity = nil
            apiKey = ""
            hasStoredKey = false
            refreshStoredKeyStateIfJevSelected()
        }
    }

    private var selectedEngineChoice: DecisionEngineChoice? {
        appState.decisionEngine
    }

    private var decisionControlsDisabled: Bool {
        appState.decisionPreferenceError != nil
            || appState.decisionEngine == nil
            || appState.decisionPause == nil
            || appState.recordingPhase != .idle
            || appState.isProcessing
    }

    private var decisionEngineBinding: Binding<DecisionEngineChoice?> {
        Binding(
            get: { appState.decisionEngine },
            set: { choice in
                guard let choice else { return }
                do {
                    try appState.selectDecisionEngine(choice)
                } catch {
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
        )
    }

    private var decisionEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                guard let isPaused = appState.decisionPause else { return false }
                return !isPaused
            },
            set: { enabled in
                guard appState.decisionPause != nil,
                      appState.decisionPreferenceError == nil else { return }
                do {
                    try appState.setDecisionPaused(!enabled)
                    if enabled {
                        Task { await appState.retryDeferredDecisions() }
                    }
                } catch {
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
        )
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appState.decisionPreferenceError == nil,
              selectedEngineChoice == .jev,
              !trimmed.isEmpty else { return }

        do {
            try secretStore.save(trimmed, account: Self.apiKeyAccount)
            apiKey = ""
            hasStoredKey = true
            statusIsError = false
            statusMessage = "APIキーを Keychain に保存しました"
            if selectedEngineChoice == .jev, appState.decisionPause == false {
                Task { await appState.retryDeferredDecisions() }
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

    private func checkSelectedEngine() async {
        guard let selectedChoice = selectedEngineChoice,
              !decisionControlsDisabled,
              checkingEngine == nil else { return }
        if selectedChoice == .jev, (appState.decisionPause != false || !hasStoredKey) {
            return
        }

        checkingEngine = selectedChoice
        statusMessage = nil
        statusIsError = false
        defer { checkingEngine = nil }

        switch selectedChoice {
        case .jev:
            await checkJevConnection()
        case .localModel:
            await checkLocalModel()
        }
    }

    private func checkJevConnection() async {
        do {
            guard let key = try secretStore.load(account: Self.apiKeyAccount), !key.isEmpty else {
                hasStoredKey = false
                statusIsError = true
                statusMessage = "APIキーが保存されていません"
                return
            }
            let response = try await JevClient(
                apiKey: key,
                transport: URLSessionJevHTTPTransport(session: .shared)
            ).classifyPriorities([
                PriorityTextTarget(key: "u0001", text: "これは接続確認のためのテスト文です。")
            ])
            guard response.decisions.count == 1,
                  let decision = response.decisions["u0001"] else {
                throw JevClientError.unexpectedAnswers
            }
            statusIsError = false
            statusMessage = "Jev から応答を受信しました（\(decision.priority == .primary ? "通常表示" : "低優先度")）"
        } catch {
            statusIsError = true
            statusMessage = "Jev 接続を確認できませんでした: \(error.localizedDescription)"
        }
    }

    private func checkLocalModel() async {
        checkedLocalModelIdentity = nil
        let factory = appState.selectedDecisionProviderFactory
        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try factory.localModelIdentity()
            }.value
            checkedLocalModelIdentity = identity
            statusIsError = false
            statusMessage = "ローカルモデルのメタデータを確認しました"
        } catch {
            statusIsError = true
            statusMessage = "ローカルモデルを確認できませんでした: \(error.localizedDescription)"
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

    private func refreshStoredKeyStateIfJevSelected() {
        guard selectedEngineChoice == .jev else { return }
        refreshStoredKeyState()
    }

    private func refreshStoredKeyState() {
        do {
            hasStoredKey = try secretStore.contains(account: Self.apiKeyAccount)
            statusIsError = false
        } catch {
            hasStoredKey = false
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
