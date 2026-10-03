import SwiftUI
import MacAmbientJevCore

struct DiagnosticsView: View {
    let usageCounter: JevUsageCounter

    @State private var snapshot: JevUsageSnapshot?
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section("Jev 利用状況") {
                if let snapshot {
                    LabeledContent("送信回数", value: snapshot.sendCount.formatted())
                    LabeledContent(
                        "入力 token 数（Jev の報告分）",
                        value: snapshot.reportedInputTokens.formatted()
                    )
                    LabeledContent("成功件数", value: snapshot.successCount.formatted())
                    LabeledContent(
                        "token 数不明の件数",
                        value: snapshot.unreportedTokenSuccessCount.formatted()
                    )
                    LabeledContent("失敗件数", value: snapshot.failureCount.formatted())
                    LabeledContent(
                        "再試行待ち件数",
                        value: snapshot.retryPendingCount.formatted()
                    )
                } else {
                    ProgressView()
                }
            }

            Section {
                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    HStack {
                        Label("利用状況を更新", systemImage: "arrow.clockwise")
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 300)
        .task {
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await usageCounter.snapshot()
    }
}
