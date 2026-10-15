import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacAmbientJev
import MacAmbientJevCore

@MainActor
@Test("A selected session with a long load error fits the window's minimum height, so the session list keeps its size")
func longUnreadableReasonDoesNotStretchTheSavedSessionsWindow() {
    let sessionURL = URL(fileURLWithPath: "/tmp/sessions/broken")
    let reason = String(repeating: "セッションフォルダのメタデータを読み取れませんでした。", count: 80)
    let sessions = (0..<30).map { index in
        SavedSessionSummary.unreadable(
            sessionURL: index == 0 ? sessionURL : URL(fileURLWithPath: "/tmp/sessions/\(index)"),
            sessionID: nil,
            reason: reason
        )
    }
    let view = SavedSessionsView(
        sessions: sessions,
        selectedSessionURL: sessionURL,
        isUnavailableForReprocess: false,
        isSelectionUnavailable: false,
        queuedSessionIDs: [],
        sessionExports: [:],
        hasExportDestination: false,
        onRefresh: {},
        onSelect: { _ in },
        onReprocess: { _ in },
        onExport: { _ in },
        onRevealExport: { _ in },
        onRevealSessionFolder: { _ in }
    )
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 760, height: 460)
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.height <= 460)
}
