import MacAmbientJevCore
import SwiftUI

struct SavedSessionsView: View {
    let sessions: [SavedSessionSummary]
    let selectedSessionID: UUID?
    let isUnavailableForReprocess: Bool
    let isSelectionUnavailable: Bool
    let queuedSessionIDs: Set<UUID>
    let sessionExports: [UUID: AppState.SessionExportState]
    let hasExportDestination: Bool
    let onRefresh: () -> Void
    let onSelect: (UUID) -> Void
    let onReprocess: (UUID) -> Void
    let onExport: (UUID) -> Void
    let onRevealExport: (UUID) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: selectedBinding) {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .tag(session.sessionID)
                }
            }
            .disabled(isSelectionUnavailable)
            .navigationTitle("保存済み録音")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onRefresh) {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .help("保存済み録音一覧を更新")
                }
            }
        } detail: {
            if let session = sessions.first(where: { $0.sessionID == selectedSessionID }) {
                detail(for: session)
            } else {
                ContentUnavailableView(
                    "録音を選択してください",
                    systemImage: "waveform",
                    description: Text("選んだ録音の処理状態を確認できます。")
                )
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var selectedBinding: Binding<UUID?> {
        Binding(
            get: { selectedSessionID },
            set: { value in
                guard !isSelectionUnavailable, let value else { return }
                onSelect(value)
            }
        )
    }

    private func sessionRow(_ session: SavedSessionSummary) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(session.createdAt.map(Self.dateText) ?? "日時を読み取れません")
                    .font(.headline)
                Text(session.originalFilename ?? sourceName(session.sourceKind, captureSource: session.captureSource))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText(session))
                    .font(.caption)
                    .foregroundStyle(session.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button {
                onReprocess(session.sessionID)
            } label: {
                if queuedSessionIDs.contains(session.sessionID) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("再処理")
                }
            }
            .controlSize(.small)
            .disabled(isUnavailableForReprocess || !session.canReprocess || queuedSessionIDs.contains(session.sessionID))
            .help(reprocessHelp(session))
        }
        .padding(.vertical, AppSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isSelectionUnavailable else { return }
            onSelect(session.sessionID)
        }
    }

    private func detail(for session: SavedSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(session.createdAt.map(Self.dateText) ?? "日時を読み取れません")
                .font(.title2.weight(.semibold))
            LabeledContent("種類", value: sourceName(session.sourceKind, captureSource: session.captureSource))
            LabeledContent("処理状態", value: statusText(session))
            if let duration = session.durationSeconds {
                LabeledContent("長さ", value: SavedSessionDisplayText.duration(duration))
            }
            if session.hasActiveTranscript {
                Label("保存済みの文字起こしを表示中", systemImage: "text.alignleft")
                    .foregroundStyle(.secondary)
            } else {
                Text("この録音には表示できる確定文字起こしがありません。")
                    .foregroundStyle(.secondary)
            }
            exportControls(for: session)
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !session.audioAvailable {
                Label("保存済み音声が見つからないため、再処理できません。", systemImage: "waveform.slash")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func exportControls(for session: SavedSessionSummary) -> some View {
        let state = sessionExports[session.sessionID]
        HStack(spacing: AppSpacing.sm) {
            Button {
                onExport(session.sessionID)
            } label: {
                if state == .exporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label(hasExportDestination ? "書き出す" : "書き出す…", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(!session.hasActiveTranscript || state == .exporting || queuedSessionIDs.contains(session.sessionID))
            .help(exportHelp(session))

            if case .exported = state {
                Button {
                    onRevealExport(session.sessionID)
                } label: {
                    Label("Finderで表示", systemImage: "folder")
                }
                .help("書き出したフォルダを Finder で表示")
            }
        }
        switch state {
        case .exported(let folder):
            Text("書き出し済み: \(folder.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .exporting, nil:
            EmptyView()
        }
    }

    private func exportHelp(_ session: SavedSessionSummary) -> String {
        if !session.hasActiveTranscript { return "確定文字起こしがないため書き出せません" }
        if queuedSessionIDs.contains(session.sessionID) { return "処理が終わってから書き出せます" }
        if !hasExportDestination { return "書き出し先フォルダを選んでから、文字起こしと音声を書き出します" }
        return "文字起こしと音声を書き出し先フォルダに保存"
    }

    private func sourceName(_ kind: SessionSourceKind?, captureSource: CaptureSource?) -> String {
        switch kind {
        case .live:
            return captureSource == .systemAudio ? "システム音声" : "マイク"
        case .importedFile:
            return "読み込み音声"
        case nil:
            return "不明"
        }
    }

    private func statusText(_ session: SavedSessionSummary) -> String {
        if let error = session.errorMessage { return "読み込みエラー: \(error)" }
        if !session.audioAvailable { return "保存済み音声がありません" }
        return switch session.processingStatus {
        case .notProcessed: "未処理"
        case .running: "処理中"
        case .complete: session.hasActiveTranscript ? "文字起こしあり" : "処理完了"
        case .classificationPending: "文字起こしあり・意味分類を再試行"
        case .failed(let reason): "再処理が必要: \(reason ?? "処理に失敗しました")"
        }
    }

    private func reprocessHelp(_ session: SavedSessionSummary) -> String {
        if isUnavailableForReprocess { return "録音または読み込みが終わってから再処理できます" }
        if queuedSessionIDs.contains(session.sessionID) { return "この録音は処理待ち、または処理中です" }
        if let error = session.errorMessage { return error }
        if !session.audioAvailable { return "保存済み音声がありません" }
        return "保存済み音声から文字起こしをやり直す"
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

}
