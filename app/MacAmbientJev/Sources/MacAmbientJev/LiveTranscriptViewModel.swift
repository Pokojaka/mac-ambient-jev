import Foundation
import Combine
import MacAmbientJevCore
import MacAmbientJevRuntime

@MainActor
final class LiveTranscriptViewModel: ObservableObject {
    @Published private(set) var rows: [LiveTranscriptRow] = []
    @Published private(set) var statusText = "待機中"
    @Published private(set) var autoFollowEnabled = true

    private let projection = LiveTranscriptProjection()
    func update(segments: [MaterializedTranscriptSegment]) {
        rows = projection.rows(for: segments)
    }

    func setStatus(_ text: String) {
        statusText = text
    }

    func pauseAutoFollow() {
        autoFollowEnabled = false
    }

    func resumeAutoFollow() {
        autoFollowEnabled = true
    }
}
