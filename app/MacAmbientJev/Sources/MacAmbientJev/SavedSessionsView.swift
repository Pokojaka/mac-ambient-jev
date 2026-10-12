import MacAmbientJevCore
import SwiftUI

struct SavedSessionsView: View {
    let sessions: [SavedSessionSummary]
    let selectedSessionURL: URL?
    let isUnavailableForReprocess: Bool
    let isSelectionUnavailable: Bool
    let queuedSessionIDs: Set<UUID>
    let sessionExports: [UUID: AppState.SessionExportState]
    let hasExportDestination: Bool
    let onRefresh: () -> Void
    let onSelect: (URL) -> Void
    let onReprocess: (UUID) -> Void
    let onExport: (UUID) -> Void
    let onRevealExport: (UUID) -> Void
    let onRevealSessionFolder: (URL) -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: selectedBinding) {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .tag(session.sessionURL)
                }
            }
            .disabled(isSelectionUnavailable)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
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
            if let session = sessions.first(where: { $0.sessionURL == selectedSessionURL }) {
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

    private var selectedBinding: Binding<URL?> {
        Binding(
            get: { selectedSessionURL },
            set: { value in
                guard !isSelectionUnavailable, let value else { return }
                onSelect(value)
            }
        )
    }

    private func sessionRow(_ summary: SavedSessionSummary) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                switch summary {
                case .readable(let session):
                    Text(Self.dateText(session.createdAt))
                        .font(.headline)
                    Text(sourceLabel(session.source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(statusText(session))
                        .font(.caption)
                        .foregroundStyle(hasProblem(session) ? Color.red : Color.secondary)
                        .lineLimit(2)
                case .unreadable(let sessionURL, _, let reason):
                    Text("日時を読み取れません")
                        .font(.headline)
                    Text(sessionURL.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("読み込みエラー: \(reason)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button {
                if case .readable(let session) = summary { onReprocess(session.sessionID) }
            } label: {
                if isQueued(summary) {
                    ProgressView().controlSize(.small)
                } else {
                    Text("再処理")
                }
            }
            .controlSize(.small)
            .disabled(isUnavailableForReprocess || !summary.canReprocess || isQueued(summary))
            .help(reprocessHelp(summary))
        }
        .padding(.vertical, AppSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isSelectionUnavailable else { return }
            onSelect(summary.sessionURL)
        }
    }

    @ViewBuilder
    private func detail(for summary: SavedSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            switch summary {
            case .readable(let session):
                readableDetail(session)
            case .unreadable(let sessionURL, let sessionID, let reason):
                Text("日時を読み取れません")
                    .font(.title2.weight(.semibold))
                LabeledContent("フォルダ", value: sessionURL.lastPathComponent)
                    .textSelection(.enabled)
                if let sessionID {
                    LabeledContent("セッション ID", value: sessionID.uuidString)
                        .textSelection(.enabled)
                }
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                revealSessionFolderButton(sessionURL)
            }
            Spacer()
        }
        .padding(AppSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func readableDetail(_ session: SavedSession) -> some View {
        Text(Self.dateText(session.createdAt))
            .font(.title2.weight(.semibold))
        LabeledContent("種類", value: sourceName(session.source))
        if case .imported(let originalFilename) = session.source {
            LabeledContent("元のファイル", value: originalFilename)
        }
        LabeledContent("処理状態", value: statusText(session))
        switch session.duration {
        case .seconds(let seconds):
            LabeledContent("長さ", value: SavedSessionDisplayText.duration(seconds))
        case .unreadable(let reason):
            LabeledContent("長さ", value: reason)
        case .unknown:
            EmptyView()
        }
        if session.hasActiveTranscript {
            Label("保存済みの文字起こしを表示中", systemImage: "text.alignleft")
                .foregroundStyle(.secondary)
        } else {
            Text("この録音には表示できる確定文字起こしがありません。")
                .foregroundStyle(.secondary)
        }
        exportControls(for: session)
        revealSessionFolderButton(session.sessionURL)
        switch session.audio {
        case .available:
            if case .corrupted(let reason) = session.processingStatus {
                Label("\(reason)。保存済み音声から再処理できます。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .missing:
            Label("保存済み音声が見つからないため、再処理できません。", systemImage: "waveform.slash")
                .foregroundStyle(.orange)
        case .unreadable(let reason):
            Label("\(reason)。再処理できません。", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func exportControls(for session: SavedSession) -> some View {
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
            .disabled(exportUnavailableReason(session) != nil || state == .exporting || queuedSessionIDs.contains(session.sessionID))
            .help(exportHelp(session))

            if case .exported = state {
                Button {
                    onRevealExport(session.sessionID)
                } label: {
                    Label("書き出し先を Finder で表示", systemImage: "folder")
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
            if let reason = exportUnavailableReason(session) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func revealSessionFolderButton(_ sessionURL: URL) -> some View {
        Button {
            onRevealSessionFolder(sessionURL)
        } label: {
            Label("録音データを Finder で表示", systemImage: "externaldrive")
        }
        .help("アプリ内に保存している、この録音のフォルダを Finder で表示")
    }

    private func exportUnavailableReason(_ session: SavedSession) -> String? {
        if case .corrupted = session.processingStatus { return "文字起こしデータが破損しているため書き出せません" }
        if !session.hasActiveTranscript { return "確定文字起こしがないため書き出せません" }
        if session.audioSource == nil { return "保存済み音声を使えないため書き出せません" }
        return nil
    }

    private func exportHelp(_ session: SavedSession) -> String {
        if let reason = exportUnavailableReason(session) { return reason }
        if queuedSessionIDs.contains(session.sessionID) { return "処理が終わってから書き出せます" }
        if !hasExportDestination { return "書き出し先フォルダを選んでから、文字起こしと音声を書き出します" }
        return "文字起こしと音声を書き出し先フォルダに保存"
    }

    private func sourceName(_ source: SessionSource) -> String {
        switch source {
        case .recording(.microphone): "マイク"
        case .recording(.systemAudio): "システム音声"
        case .imported: "読み込み音声"
        }
    }

    private func sourceLabel(_ source: SessionSource) -> String {
        switch source {
        case .recording: sourceName(source)
        case .imported(let originalFilename): originalFilename
        }
    }

    private func hasProblem(_ session: SavedSession) -> Bool {
        switch (session.audio, session.processingStatus) {
        case (.unreadable, _), (_, .corrupted): true
        default: false
        }
    }

    private func statusText(_ session: SavedSession) -> String {
        switch session.audio {
        case .missing: return "保存済み音声がありません"
        case .unreadable(let reason): return "音声を読めません: \(reason)"
        case .available: break
        }
        return switch session.processingStatus {
        case .notProcessed: "未処理"
        case .running: "処理中"
        case .paused: "一時停止中（発熱）"
        case .complete: session.hasActiveTranscript ? "文字起こしあり" : "処理完了"
        case .classificationPending: "文字起こしあり・判定を再試行"
        case .failed(let reason): "再処理が必要: \(reason ?? "処理に失敗しました")"
        case .corrupted: "文字起こしデータが破損しています（音声から再処理できます）"
        }
    }

    private func isQueued(_ summary: SavedSessionSummary) -> Bool {
        guard case .readable(let session) = summary else { return false }
        return queuedSessionIDs.contains(session.sessionID)
    }

    private func reprocessHelp(_ summary: SavedSessionSummary) -> String {
        if isUnavailableForReprocess { return "録音または読み込みが終わってから再処理できます" }
        if isQueued(summary) { return "この録音は処理待ち、または処理中です" }
        switch summary {
        case .unreadable(_, _, let reason):
            return reason
        case .readable(let session):
            switch session.audio {
            case .available: return "保存済み音声から文字起こしをやり直す"
            case .missing: return "保存済み音声がありません"
            case .unreadable(let reason): return reason
            }
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

}
