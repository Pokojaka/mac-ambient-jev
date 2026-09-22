import SwiftUI
import MacAmbientJevCore

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            transcriptHeader
            Divider()

            if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "文字起こしはまだありません",
                    systemImage: "waveform",
                    description: Text("録音を開始するか、音声ファイルを読み込むとここに文字起こしが表示されます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptList
            }
        }
    }

    private var transcriptHeader: some View {
        HStack(spacing: AppSpacing.sm) {
            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.autoFollowEnabled {
                Button {
                    viewModel.resumeAutoFollow()
                } label: {
                    Label("最新へ戻る", systemImage: "arrow.down")
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.lg) {
                    ForEach(viewModel.rows) { row in
                        transcriptRow(row)
                            .id(row.id)
                    }
                }
                .padding(AppSpacing.lg)
            }
            .onChange(of: viewModel.rows.count) {
                guard viewModel.autoFollowEnabled,
                      let last = viewModel.rows.last else { return }

                if reduceMotion {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase != .idle {
                    viewModel.pauseAutoFollow()
                }
            }
        }
    }

    private func transcriptRow(_ row: LiveTranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(row.text)
                .font(.body)
                .foregroundStyle(row.isLowPriority ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppSpacing.sm) {
                Text(formatTime(row.startMilliseconds))
                    .monospacedDigit()

                if let speaker = row.speakers.first?.id {
                    Text(speaker)
                }

                sceneLabel(row.scene)

                if let scope = scopeLabel(row.scopeSpans) {
                    Text(scope)
                }

                if row.isLowPriority {
                    Label("低優先度", systemImage: "arrow.down.circle")
                        .help("意味分類により優先度が低いと判定された発話です")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sceneLabel(_ scene: SceneState) -> some View {
        switch scene {
        case .lecture:
            Label("講義", systemImage: "person.fill")
        case .discussion:
            Label("討論", systemImage: "person.2.fill")
        case .discussionCandidate:
            Label("討論候補", systemImage: "person.2")
        case .lectureCandidate:
            Label("講義候補", systemImage: "person")
        case .unknown:
            EmptyView()
        }
    }

    private func scopeLabel(
        _ spans: [MaterializedScopeSpan]
    ) -> String? {
        guard !spans.isEmpty else { return nil }

        let scopes = Set(spans.map(\.scope))
        if scopes.count > 1 {
            return "音響範囲: 混在"
        }

        switch scopes.first {
        case .near:
            return "音響範囲: 近傍"
        case .background:
            return "音響範囲: 背景"
        case .unknown:
            return "音響範囲: 未判定"
        case nil:
            return nil
        }
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld", minutes, seconds)
    }
}