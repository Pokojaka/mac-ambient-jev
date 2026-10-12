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
    static let lowPriorityCollapsedTitle = "低優先度の発話"

    @ObservedObject var viewModel: LiveTranscriptViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedLowPriorityRowIDs: Set<String> = []
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
            }
        }
        .padding(.horizontal, AppSpacing.lg)
        .padding(.vertical, AppSpacing.sm)
    }

    private func transcriptList(proxy: ScrollViewProxy) -> some View {
        let rows = viewModel.rows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                    let heading = Self.speakerHeading(for: entry.offset, in: rows)
                    transcriptRow(entry.element, speakerHeading: heading)
                        .padding(.top, Self.topSpacing(forIndex: entry.offset, speakerHeading: heading))
                        .id(entry.element.id)
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

    static func speakerHeading(for index: Int, in rows: [LiveTranscriptRow]) -> String? {
        let labels = rows[index].displaySpeakerLabels
        guard !labels.isEmpty else { return nil }
        guard index == 0 || rows[index - 1].displaySpeakerLabels != labels else { return nil }
        return labels.joined(separator: " / ")
    }

    /// A new speaker heading gets the larger gap; rows continuing the same turn stay close.
    static func topSpacing(forIndex index: Int, speakerHeading: String?) -> CGFloat {
        if index == 0 { return 0 }
        return speakerHeading == nil ? AppSpacing.xs : AppSpacing.md
    }

    private func transcriptRow(_ row: LiveTranscriptRow, speakerHeading: String?) -> some View {
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
            .help("詳細")
            .accessibilityLabel("時刻 \(formatTime(row.startMilliseconds))、詳細を表示")
            .popover(isPresented: detailPopover(for: row.id), arrowEdge: .trailing) {
                transcriptDetails(row)
                    .padding(AppSpacing.md)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                if let speakerHeading {
                    Text(speakerHeading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if row.shouldCollapseRow {
                    DisclosureGroup(isExpanded: lowPriorityExpansion(for: row.id)) {
                        transcriptText(row)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(Self.lowPriorityCollapsedTitle, systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .help("優先度が低い本文です")
                    }
                    .accessibilityHint("除去後の本文を表示または閉じます")
                    .accessibilityValue(row.text)
                } else {
                    transcriptText(row)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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

    static func clauseStateDescription(_ state: TranscriptClauseState) -> String {
        switch state {
        case .awaitingNextSegment: "発話文: 続き待ち"
        case .boundaryPending: "発話文: 境界判定を保留中"
        case .priorityPending: "発話文: 優先度判定を待っています"
        case .classified: "発話文: 判定済み"
        }
    }

    private func detailPopover(for rowID: String) -> Binding<Bool> {
        Binding(
            get: { detailRowID == rowID },
            set: { isShown in
                if !isShown, detailRowID == rowID { detailRowID = nil }
            }
        )
    }

    private func lowPriorityExpansion(for rowID: String) -> Binding<Bool> {
        Binding(
            get: { expandedLowPriorityRowIDs.contains(rowID) },
            set: { isExpanded in
                if isExpanded {
                    expandedLowPriorityRowIDs.insert(rowID)
                } else {
                    expandedLowPriorityRowIDs.remove(rowID)
                }
            }
        )
    }

    private func transcriptText(_ row: LiveTranscriptRow) -> Text {
        row.textFragments.reduce(Text("")) { result, fragment in
            let color: Color = fragment.style == .lowPriority ? .secondary : .primary
            return result + Text(fragment.text).foregroundColor(color)
        }
    }

    private func transcriptDetails(_ row: LiveTranscriptRow) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            Text(Self.clauseStateDescription(row.clauseState))

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
    }

    private func formatTime(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld", minutes, seconds)
    }
}
