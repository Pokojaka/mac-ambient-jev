import SwiftUI
import MacAmbientJevCore

struct DiagnosticsView: View {
    let usageCounter: JevUsageCounter

    @State private var snapshot = JevUsageSnapshot(
        sendCount: 0,
        estimatedInputTokens: 0,
        successCount: 0,
        failureCount: 0,
        retryPendingCount: 0
    )

    var body: some View {
        Form {
            Section("Jev 利用状況") {
                LabeledContent("送信回数", value: snapshot.sendCount.formatted())
                LabeledContent(
                    "推定入力 token 数",
                    value: snapshot.estimatedInputTokens.formatted()
                )
                LabeledContent("成功件数", value: snapshot.successCount.formatted())
                LabeledContent("失敗件数", value: snapshot.failureCount.formatted())
                LabeledContent(
                    "再試行待ち件数",
                    value: snapshot.retryPendingCount.formatted()
                )
            }

            Section {
                Button {
                    Task {
                        await refresh()
                    }
                } label: {
                    Label("利用状況を更新", systemImage: "arrow.clockwise")
                }
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
        snapshot = await usageCounter.snapshot()
    }
}
