import SwiftUI
import MacAmbientJevCore

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(viewModel.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.autoFollowEnabled {
                    Button("最新へ戻る") {
                        viewModel.resumeAutoFollow()
                    }
                }
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.text)
                                    .opacity(row.isLowPriority ? 0.45 : 1.0)
                                    .textSelection(.enabled)

                                HStack(spacing: 8) {
                                    Text(formatTime(row.startMilliseconds))
                                    if let speaker = row.speakers.first?.id {
                                        Text(speaker)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(row.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.rows.count) {
                    guard viewModel.autoFollowEnabled,
                          let last = viewModel.rows.last else { return }
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    if phase != .idle {
                        viewModel.pauseAutoFollow()
                    }
                }
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
