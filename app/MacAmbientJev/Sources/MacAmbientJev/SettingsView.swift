import AVFoundation
import SwiftUI
import MacAmbientJevCore
import MacAmbientJevAppleSupport

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @AppStorage(MicInputVolumePreference.key)
    private var automaticMicInputVolume = MicInputVolumePreference.initialValue
    @AppStorage(ExportDestinationStore.autoExportKey)
    private var isAutoExportEnabled = ExportDestinationStore.autoExportInitialValue
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isCheckingModel = false
    @State private var checkedModelIdentity: ClauseTaggerModelIdentity?
    @State private var isRevealingExportDirectory = false
    @State private var isRetryingDeferred = false
    @State private var microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)

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
                    .help("音声認識モデル（約2.5 GB）をダウンロードしてアプリ内に保存")
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
                        .help(appState.paths.sessionsRoot.path)
                }

                Button("Finderで表示") {
                    appState.revealSessionsRoot()
                }
                .help("全録音を保存している sessions フォルダを開く")

                LabeledContent("書き出し先") {
                    Text(appState.exportDirectoryPath ?? "未設定")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(appState.exportDirectoryPath ?? "書き出し先は未設定")
                }

                HStack {
                    Button("フォルダを選択…") {
                        appState.chooseExportDirectory()
                    }
                    .help("文字起こしと音声の書き出し先を選択")
                    Button("Finderで表示") {
                        isRevealingExportDirectory = true
                        Task {
                            await appState.revealExportDirectory()
                            isRevealingExportDirectory = false
                        }
                    }
                    .disabled(appState.exportDirectoryPath == nil || isRevealingExportDirectory)
                    .help(appState.exportDirectoryPath == nil ? "書き出し先を選ぶと表示可能" : "書き出し先フォルダを開く")
                    if isRevealingExportDirectory {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Finderで表示しています")
                    }
                }

                Toggle("処理完了後に自動で書き出す", isOn: $isAutoExportEnabled)
                    .disabled(appState.exportDirectoryPath == nil)
                    .help(appState.exportDirectoryPath == nil ? "書き出し先を選ぶと設定可能" : "処理が終わった録音を書き出し先へ自動で保存")

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
                Text(
                    "録音、発話区間検出、音声認識、話者分離、発話文の判定はすべてこの Mac 上で動作し、判定テキストをネットワークに送信しません。BTSJ の発話文では、「けど」「が」「し」に続くフィラーや倒置・後付けだけでは新しい単位に分割しません。判定モデルを読み込めない間も文字起こしは継続します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("モデルを確認") {
                    Task { await checkModel() }
                }
                .disabled(decisionControlsDisabled)
                .help(decisionControlsDisabled ? "録音中・処理中は確認不可" : "発話文判定モデルを読み込めるか確認")

                if let checkedModelIdentity {
                    Text("モデル ID: \(checkedModelIdentity.modelID)")
                        .font(.caption)
                        .textSelection(.enabled)
                    Text("revision: \(checkedModelIdentity.revision)")
                        .font(.caption)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("保留中の判定を再試行") {
                        isRetryingDeferred = true
                        Task {
                            await appState.retryDeferredDecisions()
                            isRetryingDeferred = false
                        }
                    }
                    .disabled(decisionControlsDisabled)
                    .help(decisionControlsDisabled ? "録音中・処理中は再試行不可" : "判定できなかった発話文をもう一度判定")
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
                if isCheckingModel {
                    ProgressView("モデルを確認しています")
                        .controlSize(.small)
                }
            }

            Section("マイク録音テスト") {
                Toggle("マイクの入力音量を自動調整する", isOn: $automaticMicInputVolume)
                    .disabled(appState.recordingPhase != .idle)
                    .help(appState.recordingPhase == .idle ? "マイク録音中だけシステムの入力音量を自動で変更" : "録音中は切り替え不可")

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
                .help(microphoneAccess == .notDetermined ? "マイクの使用許可をシステムに要求" : "許可の変更はシステム設定から")

                Text("メイン画面で「録音を開始」を押し、声を入れてから「録音を停止」を押してください。保存状態と文字起こしを確認できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if microphoneAccess == .denied || microphoneAccess == .restricted {
                    Text("マイクを使用する場合は、システム設定の「プライバシーとセキュリティ」→「マイク」で許可してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 460)
        .task {
            microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var decisionControlsDisabled: Bool {
        appState.recordingPhase != .idle
            || appState.isProcessing
            || isCheckingModel
            || isRetryingDeferred
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

    private func checkModel() async {
        guard !decisionControlsDisabled else { return }
        isCheckingModel = true
        statusMessage = nil
        statusIsError = false
        checkedModelIdentity = nil
        defer { isCheckingModel = false }
        let factory = appState.decisionProviderFactory
        do {
            let identity = try await Task.detached(priority: .userInitiated) {
                try factory.localModelIdentity()
            }.value
            checkedModelIdentity = identity
            statusIsError = false
            statusMessage = "モデルのメタデータを確認しました"
        } catch {
            statusIsError = true
            statusMessage = "モデルを確認できませんでした: \(error.localizedDescription)"
        }
    }
}
