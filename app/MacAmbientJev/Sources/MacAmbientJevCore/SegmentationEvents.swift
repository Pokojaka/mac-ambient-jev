import Foundation

public struct SegmentationProgressPayload: Codable, Sendable, Equatable {
    public let consumedFrames: Int64
    private enum CodingKeys: String, CodingKey { case consumedFrames = "consumed_frames" }
    public init(consumedFrames: Int64) { self.consumedFrames = consumedFrames }
}

public struct SegmentationInputSealedPayload: Codable, Sendable, Equatable {
    public let frameCount: Int64
    private enum CodingKeys: String, CodingKey { case frameCount = "frame_count" }
    public init(frameCount: Int64) { self.frameCount = frameCount }
}

public struct SegmentationCompletedPayload: Codable, Sendable, Equatable {
    public let consumedFrames: Int64
    public let segmentCount: Int
    private enum CodingKeys: String, CodingKey { case consumedFrames = "consumed_frames", segmentCount = "segment_count" }
    public init(consumedFrames: Int64, segmentCount: Int) {
        self.consumedFrames = consumedFrames
        self.segmentCount = segmentCount
    }
}

public enum SegmentationConsistencyError: Error, LocalizedError, Equatable, Sendable {
    case invalidRecord(eventSeq: UInt64)
    case segmentMismatch(ordinal: Int)
    case incompletePrefix(expected: Int, actual: Int)
    case inputFrameCountMismatch(expected: Int64, actual: Int64)
    case sessionRequiresReopen
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidRecord(let seq): "イベントログの segmentation 記録（event_seq \(seq)）が不正です"
        case .segmentMismatch(let ordinal): "セグメント \(ordinal) が segmentation 記録と一致しません"
        case .incompletePrefix(let expected, let actual): "セグメント接頭辞が不完全です（期待値 \(expected)、実際 \(actual)）"
        case .inputFrameCountMismatch(let expected, let actual): "入力フレーム数が一致しません（期待値 \(expected)、実際 \(actual)）"
        case .sessionRequiresReopen: "セッションを開き直す必要があります"
        case .operationInProgress: "別の segmentation 操作が進行中です"
        }
    }
}
