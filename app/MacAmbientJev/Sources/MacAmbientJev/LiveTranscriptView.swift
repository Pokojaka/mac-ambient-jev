import SwiftUI
import MacAmbientJevCore

extension TranscriptDisplayState {
    /// Whole-screen badge; rows themselves carry no live/final marker.
    var badge: (text: String, systemImage: String)? {
        switch self {
        case .empty: nil
        case .live: ("ライブ（暫定）", "dot.radiowaves.left.and.right")
        case .finalizing: ("確定処理中", "hourglass")
        case .finalized: ("確定済み", "checkmark.seal")
        }
    }
}

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailRowID: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                transcriptHeader(proxy: proxy)
                Divider()

                if viewModel.rows.isEmpty {
                    ContentUnavailableView(
                        "文字起こしはまだありません",
                        systemImage: "waveform",
                        description: Text("録音を開始するか、音声ファイルを読み込むとここに文字起こしが表示されます。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    transcriptList(proxy: proxy)
                }
            }
        }
    }

    private func transcriptHeader(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: AppSpacing.sm) {
            if let badge = viewModel.displayState.badge {
                Label(badge.text, systemImage: badge.systemImage)
                    .font(.caption.weight(.semibold))
            }

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.autoFollowEnabled {
                Button {
                    viewModel.resumeAutoFollow()
                    scrollToLatest(proxy: proxy)
                } label: {
                    Label("最新へ戻る", systemImage: "arrow.down")
                }
                .help("最新の行までスクロールし、自動追従を再開")
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private func transcriptList(proxy: ScrollViewProxy) -> some View {
        let rows = viewModel.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.xs) {
                ForEach(rows) { row in
                    transcriptRow(row).id(row.id)
                }
            }
            .padding(AppSpacing.lg)
        }
        .onChange(of: viewModel.rows.count) {
            guard viewModel.autoFollowEnabled else { return }
            scrollToLatest(proxy: proxy)
        }
        .onScrollPhaseChange { _, phase in
            // Only user-driven scrolling stops following; the app's own animated scrollTo reports .animating.
            switch phase {
            case .interacting, .decelerating:
                viewModel.pauseAutoFollow()
            case .idle, .tracking, .animating:
                break
            }
        }
    }

    private func scrollToLatest(proxy: ScrollViewProxy) {
        guard let last = viewModel.rows.last else { return }
        if reduceMotion {
            proxy.scrollTo(last.id, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func transcriptRow(_ row: LiveTranscriptRow) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Button {
                detailRowID = row.id
            } label: {
                Text(formatTime(row.startMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("この行の発話文の判定状態を表示")
            .accessibilityLabel("時刻 \(formatTime(row.startMilliseconds))、詳細を表示")
            .popover(isPresented: detailPopover(for: row.id), arrowEdge: .trailing) {
                transcriptDetails(row)
                    .padding(AppSpacing.md)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(row.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if row.clauseState == .awaitingNextSegment {
                    Text(Self.awaitingNextSegmentTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    static let awaitingNextSegmentTitle = "発話文の続き待ち"

    private func detailPopover(for rowID: String) -> Binding<Bool> {
        Binding(
            get: { detailRowID == rowID },
            set: { isShown in
                if !isShown, detailRowID == rowID { detailRowID = nil }
            }
        )
    }

    private func transcriptDetails(_ row: LiveTranscriptRow) -> some View {
        Text(row.clauseState.rowDetailsDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld", minutes, seconds)
    }
}
