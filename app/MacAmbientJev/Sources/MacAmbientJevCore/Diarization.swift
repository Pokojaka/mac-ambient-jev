import Foundation

public struct SpeakerSpanMapper: Sendable, Equatable {
    public let sampleRate: Double

    public init(sampleRate: Double) {
        precondition(sampleRate > 0)
        self.sampleRate = sampleRate
    }

    public func map(
        speakerID: String,
        startSeconds: Double,
        endSeconds: Double,
        confidence: Double?
    ) -> SpeakerSpan {
        SpeakerSpan(
            speakerID: speakerID,
            startFrame: Int64((startSeconds * sampleRate).rounded()),
            endFrame: Int64((endSeconds * sampleRate).rounded()),
            confidence: confidence
        )
    }
}


public protocol DiarizationEngine: Sendable {
    var provenance: RunProvenance { get }
    func prepare() async throws
    func diarize(
        fileURL: URL,
        canonicalSampleRate: Double,
        sessionURL: URL
    ) async throws -> [SpeakerSpan]
    /// Releases the loaded models; `prepare()` loads them again.
    func unload() async
}
