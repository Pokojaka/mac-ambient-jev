import Foundation
import Combine
import MacAmbientJevCore
import MacAmbientJevRuntime

/// Whole-screen state of the transcript: provisional live rows, finalization running, or the final result.
enum TranscriptDisplayState: Equatable {
    case empty
    case live
    case finalizing
    case finalized
}

@MainActor
final class LiveTranscriptViewModel: ObservableObject {
    @Published private(set) var rows: [LiveTranscriptRow] = []
    @Published private(set) var displayState: TranscriptDisplayState = .empty
    @Published private(set) var statusText = "待機中"
    @Published private(set) var autoFollowEnabled = true

    private let projection = LiveTranscriptProjection()
    func update(segments: [MaterializedTranscriptSegment]) {
        rows = projection.rows(for: segments)
    }

    func setStatus(_ text: String) {
        statusText = text
    }

    func setDisplayState(_ state: TranscriptDisplayState) {
        displayState = state
    }

    func pauseAutoFollow() {
        autoFollowEnabled = false
    }

    func resumeAutoFollow() {
        autoFollowEnabled = true
    }
}
