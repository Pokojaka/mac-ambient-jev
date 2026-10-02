import Foundation

extension AudioCheckpoint {
    /// Replacement silence fills the timeline but is not captured input.
    public var hasCapturedAudio: Bool {
        guard committedFrames > 0 else { return false }
        var coveredThrough: Int64 = 0
        for gap in gapEvents {
            if gap.startFrame > coveredThrough { return true }
            guard gap.startFrame >= 0, gap.startFrame < committedFrames,
                  gap.frameCount > 0 else { continue }
            let end = gap.startFrame + min(gap.frameCount, committedFrames - gap.startFrame)
            coveredThrough = max(coveredThrough, end)
            if coveredThrough >= committedFrames { return false }
        }
        return coveredThrough < committedFrames
    }
}
