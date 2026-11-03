import Foundation
import MacAmbientJevCore

/// Streams imported source audio through canonical conversion into durable timeline chunks.
public actor AudioFileTimelineBuilder: ImportedAudioTimelineBuilding {
    public let readFrameCount: UInt32

    public init(readFrameCount: UInt32 = 8_192) {
        precondition((1...8_192).contains(readFrameCount))
        self.readFrameCount = readFrameCount
    }

    public func build(
        from sourceURL: URL,
        into processingDirectory: URL,
        sessionURL: URL
    ) async throws -> AudioCheckpoint {
        let decoder = try AudioImportDecoder(url: sourceURL, sessionURL: sessionURL)
        let converter = try CanonicalAudioResampler(sampleRate: decoder.sampleRate)
        let writer = try ImportedAudioTimelineWriter(
            directory: processingDirectory,
            sessionURL: sessionURL,
            converter: converter
        )

        // The canonical half-open boundary is computed over the frames the decoder returns,
        // which already exclude M4A priming and end padding named by the file's metadata.
        while true {
            let mono = try decoder.readMono(frameCount: Int(readFrameCount))
            guard !mono.isEmpty else { break }
            try await writer.append(mono: mono)
        }

        return try await writer.finish()
    }
}
