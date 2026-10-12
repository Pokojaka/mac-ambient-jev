import SwiftUI
import MacAmbientJevCore

struct DiagnosticsView: View {
    let usageCounter: DecisionUsageCounter

    @State private var snapshot: DecisionUsageSnapshot?
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                if let snapshot {
                    LabeledContent("リクエスト回数（合計）", value: snapshot.sendCount.formatted())
                    LabeledContent(
                        "入力 token 数（Jev 報告分＋ローカル実入力）",
                        value: snapshot.reportedInputTokens.formatted()
                    )
                    LabeledContent("成功件数", value: snapshot.successCount.formatted())
                    LabeledContent(
                        "token 数不明の件数",
                        value: snapshot.unreportedTokenSuccessCount.formatted()
                    )
                    LabeledContent("失敗件数", value: snapshot.failureCount.formatted())
                } else {
                    ProgressView()
                }
            } header: {
                Text("発話文判定の利用状況（判定リクエスト単位）")
            } footer: {
                Text("ローカル判定は通信せず、1回の判定呼出しを1リクエストとして数えます。")
            }

            if let snapshot {
                requestSection("境界判定リクエスト", snapshot.boundaryRequests)
                requestSection("優先度判定リクエスト", snapshot.priorityRequests)
                Section("保留") {
                    LabeledContent(
                        "境界判定の保留区間",
                        value: snapshot.pendingBoundarySegmentCount.formatted()
                    )
                    LabeledContent(
                        "優先度判定の保留発話文",
                        value: snapshot.pendingPriorityClauseCount.formatted()
                    )
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

    private func requestSection(_ title: String, _ usage: DecisionRequestUsageSnapshot) -> some View {
        Section(title) {
            LabeledContent("リクエスト回数", value: usage.sendCount.formatted())
            LabeledContent(
                "入力 token 数（Jev 報告分＋ローカル実入力）",
                value: usage.reportedInputTokens.formatted()
            )
            LabeledContent("成功件数", value: usage.successCount.formatted())
            LabeledContent("token 数不明の件数", value: usage.unreportedTokenSuccessCount.formatted())
            LabeledContent("失敗件数", value: usage.failureCount.formatted())
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
