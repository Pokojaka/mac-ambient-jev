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
            let rows = viewModel.rows
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                        transcriptRow(entry.element, speakerHeading: Self.speakerHeading(for: entry.offset, in: rows))
                            .id(entry.element.id)
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

    static func speakerHeading(for index: Int, in rows: [LiveTranscriptRow]) -> String? {
        let labels = rows[index].displaySpeakerLabels
        guard !labels.isEmpty else { return nil }
        guard index == 0 || rows[index - 1].displaySpeakerLabels != labels else { return nil }
        return labels.joined(separator: " / ")
    }

    private func transcriptRow(_ row: LiveTranscriptRow, speakerHeading: String?) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            Text(formatTime(row.startMilliseconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
                .accessibilityLabel("時刻 \(formatTime(row.startMilliseconds))")

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let speakerHeading {
                    Text(speakerHeading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup {
                    transcriptDetails(row)
                } label: {
                    transcriptText(row)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityHint("詳細を表示または閉じます。場面、音響範囲、優先度、話者区間を確認できます")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func transcriptText(_ row: LiveTranscriptRow) -> Text {
        row.textFragments.reduce(Text("")) { result, fragment in
            let piece = Text(fragment.text)
            if row.isLowPriority || fragment.isFiller {
                return result + piece.foregroundColor(.secondary)
            }
            return result + piece.foregroundColor(.primary)
        }
    }

    private func transcriptDetails(_ row: LiveTranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            sceneDescription(row.scene)
            scopeDescriptions(row.scopeSpans)

            if row.isLowPriority {
                Label("低優先度", systemImage: "arrow.down.circle")
                    .help("意味分類により優先度が低いと判定された発話です")
            }

            if !row.speakers.isEmpty {
                Text("話者区間")
                    .font(.caption.weight(.semibold))
                ForEach(Array(row.speakers.enumerated()), id: \.offset) { entry in
                    let span = entry.element
                    Text("\(span.displayLabel ?? span.id) · \(formatTime(span.startMilliseconds))–\(formatTime(span.endMilliseconds))")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, AppSpacing.xs)
    }

    @ViewBuilder
    private func sceneDescription(_ scene: SceneState) -> some View {
        switch scene {
        case .lecture:
            Label("場面: 講義", systemImage: "person.fill")
        case .discussion:
            Label("場面: 討論", systemImage: "person.2.fill")
        case .discussionCandidate:
            Label("場面: 討論候補", systemImage: "person.2")
        case .lectureCandidate:
            Label("場面: 講義候補", systemImage: "person")
        case .unknown:
            Text("場面: 未判定")
        }
    }

    @ViewBuilder
    private func scopeDescriptions(_ spans: [MaterializedScopeSpan]) -> some View {
        if spans.isEmpty {
            Text("音響範囲: 未判定")
        } else {
            ForEach(Array(spans.enumerated()), id: \.offset) { entry in
                let span = entry.element
                let label: String = switch span.scope {
                case .near: "近傍"
                case .background: "背景"
                case .unknown: "未判定"
                }
                Text("音響範囲: \(label) · \(formatTime(span.startMilliseconds))–\(formatTime(span.endMilliseconds))")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld", minutes, seconds)
    }
}
