import Foundation
import Testing
@testable import MacAmbientJevCore

private func saved(_ storage: SessionAudioStorage) throws -> String {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = SessionLayout(sessionURL: root)
    try FileManager.default.createDirectory(at: layout.audioDirectory, withIntermediateDirectories: true)
    try SessionAudioStorageStore(layout: layout).save(storage)
    return try String(contentsOf: layout.audioStorageURL, encoding: .utf8)
}

private let timelineJSON =
    #""timeline":{"channelCount":1,"committedFrames":9600000,"#
    + #""gapEvents":[{"frameCount":8000,"reason":"overflow","startFrame":160000}],"sampleRate":16000}"#

/// docs/storage.md shows exactly these bytes.
@Test
func storageJSONHasTheDocumentedFormForEveryState() throws {
    let info = try TimelineAudioInfo(
        committedFrames: 9_600_000,
        gapEvents: [AudioGapEvent(startFrame: 160_000, frameCount: 8_000, reason: .overflow)]
    )

    #expect(try saved(.recordingPCM) == #"{"state":"recordingPCM"}"#)
    #expect(try saved(.recordingFLAC(info)) == #"{"state":"recordingFLAC","# + timelineJSON + "}")
    #expect(try saved(.importedOriginal(nil)) == #"{"state":"importedOriginal","timeline":null}"#)
    #expect(try saved(.importedOriginal(info)) == #"{"state":"importedOriginal","# + timelineJSON + "}")
}
